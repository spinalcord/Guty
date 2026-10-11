@tool
extends RefCounted

const MAX_MESSAGES = 500
var records: Dictionary = {}
var order: Array = []
var active: Dictionary = {}
var sequence = 0

func start(session_id):
	if active.has(session_id):
		stop(session_id)
	sequence += 1
	var id = "debug-%s-%s-%s" % [Time.get_unix_time_from_system(), Time.get_ticks_usec(), sequence]
	records[id] = {"debug_id": id, "session_id": session_id, "run_id": null, "state": "running", "started_at": Time.get_unix_time_from_system(), "ended_at": null, "paused": false, "can_debug": false, "last_break_reason": "", "last_break_reason_truncated": false, "stacktrace": [], "stacktrace_current": false, "stacktrace_truncated": false, "messages": [], "messages_dropped": 0}
	active[session_id] = id
	order.append(id)
	while order.size() > 10:
		var old = order.pop_front()
		# Active sessions remain addressable even if more than ten are open.
		if old not in active.values():
			records.erase(old)
	return id

func for_session(session_id):
	return records.get(active.get(session_id, ""), {})

func stop(session_id):
	var record = for_session(session_id)
	if record.is_empty():
		return
	record.state = "stopped"
	record.paused = false
	record.can_debug = false
	record.stacktrace_current = false
	record.ended_at = Time.get_unix_time_from_system()
	active.erase(session_id)
	if record.debug_id not in order:
		records.erase(record.debug_id)

func breaked(session_id, paused, can_debug, reason):
	var record = for_session(session_id)
	if record.is_empty():
		return
	record.paused = paused
	record.can_debug = can_debug
	record.state = "paused" if paused else "running"
	record.stacktrace_current = false
	if paused:
		record.last_break_reason = str(reason).left(4096)
		record.last_break_reason_truncated = str(reason).length() > 4096

func stack(session_id, frames):
	var record = for_session(session_id)
	if record.is_empty():
		return
	record.stacktrace = []
	record.stacktrace_truncated = frames.size() > 100
	for frame in frames.slice(0, 100):
		if frame is Dictionary:
			record.stacktrace_truncated = record.stacktrace_truncated or str(frame.get("file", "")).length() > 4096 or str(frame.get("function", "")).length() > 4096
			record.stacktrace.append({"file": str(frame.get("file", "")).left(4096), "line": frame.get("line", 0), "function": str(frame.get("function", "")).left(4096)})
	record.stacktrace_current = record.paused

func output(session_id, entry):
	var record = for_session(session_id)
	if record.is_empty():
		return
	var item = entry.duplicate(true)
	var message = str(item.get("message", ""))
	item.message = message.left(4096)
	item.truncated = message.length() > 4096
	item.timestamp = Time.get_unix_time_from_system()
	record.messages.append(item)
	if record.messages.size() > MAX_MESSAGES:
		record.messages.pop_front()
		record.messages_dropped += 1

func select(args, runs):
	if args.has("debug_id") and args.has("run_id"):
		return {"error": "debug_id and run_id are mutually exclusive."}
	if args.has("debug_id"):
		if records.has(args.debug_id):
			return records[args.debug_id]
		for run in runs.values():
			if run.get("diagnostic", {}).get("debug_id") == args.debug_id:
				return run.diagnostic
		return {"error": "Unknown debug_id: " + args.debug_id}
	if args.has("run_id"):
		if not runs.has(args.run_id):
			return {"error": "Unknown run_id: " + args.run_id}
		return runs[args.run_id].get("diagnostic", {})
	var newest_active = {}
	for id in active.values():
		var record = records[id]
		if newest_active.is_empty() or record.started_at > newest_active.started_at:
			newest_active = record
	if not newest_active.is_empty():
		return newest_active
	var latest = {}
	var candidates = records.values()
	for run in runs.values():
		var saved = run.get("diagnostic", {})
		if not saved.is_empty():
			candidates.append(saved)
	for record in candidates:
		if latest.is_empty() or _closed_at(record) > _closed_at(latest):
			latest = record
	return latest

func _closed_at(record):
	return record.ended_at if record.ended_at != null else record.started_at

func info(record):
	var result = record.duplicate(true)
	result.erase("messages")
	result.output_truncated = record.get("messages_dropped", 0) > 0
	return result
