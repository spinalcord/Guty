@tool
extends Node

# Stateless Streamable HTTP. Each connection carries one JSON-RPC message.
const VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26"]
const MAX_BODY = 1048576
const MAX_HEADER = 16384
const MAX_CLIENTS = 16
const CONNECTION_MS = 5000
var listener = TCPServer.new()
var clients: Array = []
var dispatch: Callable
var port = 9081
var error = ""
var requests = 0
var last_request_at = 0.0

func start(value: int) -> bool:
	stop()
	port = value
	var code = listener.listen(port, "127.0.0.1")
	error = "" if code == OK else "Could not open MCP port %s (error %s)." % [port, code]
	return code == OK

func stop():
	listener.stop()
	for client in clients:
		client.peer.disconnect_from_host()
	clients.clear()

func _process(_delta):
	while listener.is_connection_available():
		var peer = listener.take_connection()
		if clients.size() >= MAX_CLIENTS:
			peer.disconnect_from_host()
		else:
			clients.append({"peer": peer, "bytes": PackedByteArray(), "started": Time.get_ticks_msec()})
	for client in clients.duplicate():
		client.peer.poll()
		if Time.get_ticks_msec() - client.started > CONNECTION_MS:
			_close(client)
			continue
		if client.peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			clients.erase(client)
			continue
		if client.has("response"):
			_flush(client)
			continue
		var available = client.peer.get_available_bytes()
		if available > 0:
			if client.bytes.size() + available > MAX_BODY + MAX_HEADER:
				_reply(client, 413, null)
				continue
			var received = client.peer.get_data(available)
			if received[0] != OK:
				_reply(client, 400, null)
				continue
			client.bytes.append_array(received[1])
		_parse(client)

func _parse(client):
	var raw: String = client.bytes.get_string_from_utf8()
	var end = raw.find("\r\n\r\n")
	if end < 0:
		if client.bytes.size() > MAX_HEADER:
			_reply(client, 431, null)
		return
	if end > MAX_HEADER:
		_reply(client, 431, null)
		return
	var lines = raw.left(end).split("\r\n")
	var first = lines[0].split(" ")
	var headers = {}
	for line in lines.slice(1):
		var colon = line.find(":")
		if colon < 1 or headers.has(line.left(colon).to_lower()):
			_reply(client, 400, null)
			return
		headers[line.left(colon).to_lower()] = line.substr(colon + 1).strip_edges()
	var origins = ["http://127.0.0.1:%s" % port, "http://localhost:%s" % port]
	if headers.has("origin") and headers.origin not in origins:
		_reply(client, 403, null)
		return
	if first.size() != 3 or first[1] != "/mcp":
		_reply(client, 404, null)
		return
	if headers.get("mcp-protocol-version", "2025-03-26") not in VERSIONS:
		_reply(client, 400, null)
		return
	if first[0] != "POST":
		_reply(client, 405, null)
		return
	if headers.has("transfer-encoding") or not headers.get("content-length", "").is_valid_int():
		_reply(client, 400, null)
		return
	var length = int(headers["content-length"])
	if length < 0 or length > MAX_BODY:
		_reply(client, 413, null)
		return
	if headers.get("content-type", "").split(";")[0].strip_edges() != "application/json":
		_reply(client, 415, null)
		return
	var accept = headers.get("accept", "")
	if not accept.contains("application/json") or not accept.contains("text/event-stream"):
		_reply(client, 406, null)
		return
	# Count bytes, not Unicode characters.
	var body_start = raw.left(end + 4).to_utf8_buffer().size()
	if client.bytes.size() < body_start + length:
		return
	var parser = JSON.new()
	if parser.parse(client.bytes.slice(body_start, body_start + length).get_string_from_utf8()) != OK:
		_reply(client, 200, _rpc_error(null, -32700, "Invalid JSON"))
		return
	var message = parser.data
	if not message is Dictionary or message.get("jsonrpc") != "2.0":
		_reply(client, 200, _rpc_error(null, -32600, "Invalid request"))
		return
	if not message.has("method"):
		if message.has("id") and (message.has("result") or message.has("error")):
			_reply(client, 202, null)
		else:
			_reply(client, 200, _rpc_error(null, -32600, "Invalid request"))
		return
	if not message.method is String or (message.has("id") and message.id != null and not (message.id is String or message.id is float or message.id is int)):
		_reply(client, 200, _rpc_error(null, -32600, "Invalid request"))
		return
	if not message.has("id"):
		_reply(client, 202, null)
		return
	var params = message.get("params", {})
	if not params is Dictionary:
		_reply(client, 200, _rpc_error(message.id, -32602, "Invalid params"))
		return
	requests += 1
	last_request_at = Time.get_unix_time_from_system()
	var result
	match message.method:
		"initialize":
			if not params.get("protocolVersion") is String or not params.get("capabilities") is Dictionary or not params.get("clientInfo") is Dictionary:
				_reply(client, 200, _rpc_error(message.id, -32602, "Invalid initialize params"))
				return
			var version = params.protocolVersion if params.protocolVersion in VERSIONS else VERSIONS[0]
			result = {"protocolVersion": version, "capabilities": {"tools": {}}, "serverInfo": {"name": "gut", "version": "9.7.1"}}
		"ping": result = {}
		"tools/list": result = {"tools": dispatch.call("__list", {})}
		"tools/call":
			if not params.get("name") is String or not params.get("arguments", {}) is Dictionary:
				_reply(client, 200, _rpc_error(message.id, -32602, "Invalid tool params"))
				return
			result = dispatch.call(params.name, params.get("arguments", {}))
		_:
			_reply(client, 200, _rpc_error(message.id, -32601, "Unknown method"))
			return
	_reply(client, 200, {"jsonrpc": "2.0", "id": _response_id(message.id), "result": result})

func _response_id(id):
	# Godot parses JSON numbers as floats; MCP clients expect integer IDs.
	return int(id) if id is float and id == floor(id) else id

func _rpc_error(id, code, message):
	return {"jsonrpc": "2.0", "id": _response_id(id), "error": {"code": code, "message": message}}

func _reply(client, status, body):
	var payload = "" if body == null else JSON.stringify(body)
	var labels = {200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 413: "Content Too Large", 415: "Unsupported Media Type", 431: "Request Header Fields Too Large"}
	var response = "HTTP/1.1 %s %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n" % [status, labels[status], payload.to_utf8_buffer().size()]
	if status == 405:
		response += "Allow: POST\r\n"
	client.response = (response + "\r\n" + payload).to_utf8_buffer()
	client.sent = 0
	_flush(client)

func _flush(client):
	var result = client.peer.put_partial_data(client.response.slice(client.sent))
	if result[0] != OK:
		_close(client)
		return
	client.sent += result[1]
	if client.sent == client.response.size():
		_close(client)

func _close(client):
	client.peer.disconnect_from_host()
	clients.erase(client)
