@tool
extends EditorDebuggerPlugin

var manager

func _has_capture(prefix: String) -> bool:
	return prefix == "gut_mcp"

func _capture(message: String, data: Array, session_id: int) -> bool:
	if message == "gut_mcp:snapshot" and data.size() == 1 and data[0] is Dictionary:
		manager.receive(data[0], session_id)
		return true
	return false

func _setup_session(session_id: int):
	var session = get_session(session_id)
	session.breaked.connect(func(can_debug): manager.debug_break(session_id, true, can_debug))
	session.continued.connect(func(): manager.debug_break(session_id, false, true))
	session.stopped.connect(func(): manager.session_stopped(session_id))
