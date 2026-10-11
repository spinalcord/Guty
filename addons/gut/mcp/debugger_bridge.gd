@tool
extends EditorDebuggerPlugin

var manager
var bindings: Dictionary = {}

func _has_capture(prefix: String) -> bool:
	return prefix == "gut_mcp"

func _capture(message: String, data: Array, session_id: int) -> bool:
	if message == "gut_mcp:snapshot" and data.size() == 1 and data[0] is Dictionary:
		manager.receive(data[0], session_id)
		return true
	return false

func _setup_session(session_id: int):
	var session = get_session(session_id)
	var marker = Control.new()
	marker.name = "GUT MCP Diagnostics"
	session.add_session_tab(marker)
	var tabs = marker.get_parent() as TabContainer
	if tabs:
		tabs.set_tab_hidden(tabs.get_tab_idx_from_control(marker), true)
	var debugger = marker.get_parent()
	while debugger != null and debugger.get_class() != "ScriptEditorDebugger":
		debugger = debugger.get_parent()
	var binding = {"session": session, "marker": marker, "debugger": debugger, "connections": []}
	bindings[session_id] = binding
	_connect(binding, session, "started", func(): manager.debug_session_started(session_id))
	_connect(binding, session, "stopped", func():
		poll_session(session_id)
		manager.session_stopped(session_id))
	if debugger != null:
		_connect(binding, debugger, "breaked", func(paused, can_debug, reason, _has_stack): manager.debug_break(session_id, paused, can_debug, reason))
		_connect(binding, debugger, "stack_dump", func(stack): manager.debug_stack(session_id, stack))
		_connect(binding, debugger, "output", func(message, level): manager.debug_output(session_id, {"category": "stderr" if level == 1 else "stdout", "message": message, "source": "debugger_output", "output_type": level}))
	if session.is_active():
		manager.debug_session_started(session_id)

func _connect(binding, object, signal_name, callback):
	if object.has_signal(signal_name):
		object.connect(signal_name, callback)
		binding.connections.append([object, signal_name, callback])

func poll():
	for session_id in bindings:
		if not manager.diagnostics.for_session(session_id).is_empty():
			poll_session(session_id)

func poll_session(session_id):
	var binding = bindings.get(session_id, {})
	var record = manager.diagnostics.for_session(session_id)
	if binding.is_empty() or record.is_empty() or not is_instance_valid(binding.debugger):
		return
	# Only inspect descendants of the debugger owning our session tab.
	var pending = [binding.debugger]
	while not pending.is_empty():
		var node = pending.pop_back()
		if node is Tree and node.get_root() != null:
			for item in node.get_root().get_children():
				if not item.has_meta("_is_error") and not item.has_meta("_is_warning"):
					continue
				if item.get_meta("gut_mcp_debug_id", "") == record.debug_id:
					continue
				item.set_meta("gut_mcp_debug_id", record.debug_id)
				var meta = item.get_metadata(0)
				manager.debug_output(session_id, {"category": "warning" if item.has_meta("_is_warning") else "error", "message": item.get_text(1), "source": "debugger_error_tree", "file": str(meta[0]) if meta is Array and meta.size() >= 2 else "", "line": int(meta[1]) if meta is Array and meta.size() >= 2 else 0})
		pending.append_array(node.get_children())

func shutdown():
	poll()
	for binding in bindings.values():
		for connection in binding.connections:
			if is_instance_valid(connection[0]) and connection[0].is_connected(connection[1], connection[2]):
				connection[0].disconnect(connection[1], connection[2])
		if is_instance_valid(binding.marker):
			binding.session.remove_session_tab(binding.marker)
	bindings.clear()
