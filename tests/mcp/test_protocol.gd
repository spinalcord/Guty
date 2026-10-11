extends SceneTree

class Peer:
	extends RefCounted
	var response = PackedByteArray()
	func put_partial_data(data):
		var count = mini(data.size(), 16)
		response.append_array(data.slice(0, count))
		return [OK, count]
	func disconnect_from_host():
		pass

class OccupiedPort:
	extends RefCounted
	func listen(_port, _address): return ERR_ALREADY_IN_USE
	func stop(): pass

var server
var failures = 0

func check(condition, label):
	if not condition:
		failures += 1
		printerr("FAIL: ", label)

func request(body, headers = {}, method = "POST", path = "/mcp"):
	var payload = JSON.stringify(body)
	var base = {"Host": "127.0.0.1:9081", "Content-Type": "application/json", "Accept": "application/json, text/event-stream", "Content-Length": str(payload.to_utf8_buffer().size())}
	base.merge(headers, true)
	var raw = "%s %s HTTP/1.1\r\n" % [method, path]
	for key in base:
		raw += "%s: %s\r\n" % [key, base[key]]
	var peer = Peer.new()
	var client = {"peer": peer, "bytes": (raw + "\r\n" + payload).to_utf8_buffer()}
	server.clients.append(client)
	server._parse(client)
	while server.clients.has(client) and client.has("response"):
		server._flush(client)
	return peer.response.get_string_from_utf8()

func rpc(method, params = {}, id = 1):
	return {"jsonrpc": "2.0", "id": id, "method": method, "params": params}

func check_response_id(response, id, label):
	# Check the wire JSON: parsing again would turn integers back into floats.
	var body = response.split("\r\n\r\n", true, 1)[1]
	check(body.contains('"id":' + JSON.stringify(id) + ','), label)

func _initialize():
	server = load("res://addons/gut/mcp/http_server.gd").new()
	server.dispatch = func(name, _args): return [] if name == "__list" else {"content": []}
	var initialize = request(rpc("initialize", {"protocolVersion": "2099-01-01", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}))
	check(initialize.contains('"protocolVersion":"2025-11-25"'), "version negotiation")
	check_response_id(initialize, 1, "initialize integer ID")
	for id in [0, 1, -7, 42, "request-1", "001", null]:
		check_response_id(request(rpc("ping", {}, id)), id, "success ID %s" % str(id))
		check_response_id(request(rpc("missing", {}, id)), id, "method error ID %s" % str(id))
		check_response_id(request(rpc("ping", [], id)), id, "params error ID %s" % str(id))
		check_response_id(request(rpc("initialize", {}, id)), id, "initialize error ID %s" % str(id))
		check_response_id(request(rpc("tools/call", {"name": 3}, id)), id, "tool error ID %s" % str(id))
	check(request(rpc("initialize")).contains('"code":-32602'), "invalid initialize")
	check(request(rpc("ping")).contains('"result":{}'), "ping")
	check(request(rpc("tools/list")).contains('"tools":[]'), "tools list")
	check(request(rpc("tools/call", {"name": "gut_get_config"})).contains('"content":[]'), "tool call")
	check(request(rpc("tools/call", {"name": 3})).contains('"code":-32602'), "invalid tool call")
	check(request(rpc("missing")).contains('"code":-32601'), "unknown method")
	check(request([rpc("ping")]).contains('"code":-32600'), "reject batches")
	check(request({"jsonrpc": "2.0", "method": "notifications/initialized"}).begins_with("HTTP/1.1 202"), "notification")
	check(request(rpc("ping"), {"Origin": "https://evil.example"}).begins_with("HTTP/1.1 403"), "foreign origin")
	check(request(rpc("ping"), {"Origin": "null"}).begins_with("HTTP/1.1 403"), "null origin")
	check(request(rpc("ping"), {"Origin": "http://localhost:9081"}).begins_with("HTTP/1.1 200"), "local origin")
	check(request(rpc("ping"), {"MCP-Protocol-Version": "garbage"}).begins_with("HTTP/1.1 400"), "unsupported protocol")
	check(request(rpc("ping"), {}, "GET").begins_with("HTTP/1.1 405"), "GET without SSE")
	check(request(rpc("ping"), {}, "DELETE").begins_with("HTTP/1.1 405"), "stateless DELETE")
	check(request(rpc("ping"), {}, "POST", "/other").begins_with("HTTP/1.1 404"), "path")
	check(request(rpc("ping"), {"Accept": "application/json"}).begins_with("HTTP/1.1 406"), "Accept types")
	check(request(rpc("ping"), {"Content-Type": "text/plain"}).begins_with("HTTP/1.1 415"), "content type")
	check(request(rpc("ping"), {"Content-Length": "1048577"}).begins_with("HTTP/1.1 413"), "body limit")
	check(request(rpc("ping"), {"Transfer-Encoding": "chunked"}).begins_with("HTTP/1.1 400"), "ambiguous framing")
	check(request(rpc("ping", {"unicode": "hello 🌍"})).contains('"result":{}'), "UTF-8 framing")
	server.listener = OccupiedPort.new()
	check(not server.start(9081) and server.error.contains("9081"), "port conflict visible error")
	server.free()
	print("Protocol checks: ", failures, " failures")
	quit(1 if failures else 0)
