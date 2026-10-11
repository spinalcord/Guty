@tool
extends Node

const BASE = "user://gut_temp_directory/mcp/"
const LAUNCH = BASE + "launch.json"
const SCENE = "res://addons/gut/gui/run_from_editor.tscn"
const TERMINAL = ["completed", "aborted", "runtime_error"]
var plugin
var panel
var bridge
var server
var runs: Dictionary = {}
var order: Array = []
var current = ""
var owned = ""
var stop_at = 0
var status_label: Label
var enabled_box: CheckBox
var port_box: SpinBox

func setup(p, bottom):
	plugin = p
	panel = bottom
	DirAccess.make_dir_recursive_absolute(BASE)
	if FileAccess.file_exists(LAUNCH):
		DirAccess.remove_absolute(LAUNCH)
	_load_runs()
	bridge = preload("debugger_bridge.gd").new()
	bridge.manager = self
	plugin.add_debugger_plugin(bridge)
	server = preload("http_server.gd").new()
	server.dispatch = call_tool
	add_child(server)
	var row = HBoxContainer.new()
	panel.get_node("layout").add_child(row)
	enabled_box = CheckBox.new()
	enabled_box.text = "GUT MCP"
	row.add_child(enabled_box)
	port_box = SpinBox.new()
	port_box.min_value = 1024
	port_box.max_value = 65535
	port_box.value = plugin.get_editor_interface().get_editor_settings().get_setting("gut/mcp_port") if plugin.get_editor_interface().get_editor_settings().has_setting("gut/mcp_port") else 9081
	row.add_child(port_box)
	status_label = Label.new()
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(status_label)
	enabled_box.toggled.connect(func(value): _configure(value))
	port_box.value_changed.connect(func(_value): _configure(enabled_box.button_pressed))
	var settings = plugin.get_editor_interface().get_editor_settings()
	enabled_box.set_pressed_no_signal(settings.get_setting("gut/mcp_enabled") if settings.has_setting("gut/mcp_enabled") else false)
	_configure(enabled_box.button_pressed)

func _configure(enabled):
	var settings = plugin.get_editor_interface().get_editor_settings()
	settings.set_setting("gut/mcp_enabled", enabled)
	settings.set_setting("gut/mcp_port", int(port_box.value))
	server.stop()
	if enabled:
		server.start(int(port_box.value))
	else:
		server.error = ""
	status_label.text = server.error if not server.error.is_empty() else ("http://127.0.0.1:%s/mcp" % int(port_box.value) if enabled else "MCP deaktiviert")

func shutdown():
	server.stop()
	if not owned.is_empty():
		runs[owned].stop_requested = true
		# This plugin owns only the scene it launched, never arbitrary game sessions.
		if _owns_playing_scene():
			plugin.get_editor_interface().stop_playing_scene()
		_finish_closed(owned)
	plugin.remove_debugger_plugin(bridge)
	if FileAccess.file_exists(LAUNCH):
		DirAccess.remove_absolute(LAUNCH)

func _owns_playing_scene():
	var editor = plugin.get_editor_interface()
	return not owned.is_empty() and editor.is_playing_scene() and editor.get_playing_scene() == SCENE

func _process(_delta):
	if owned.is_empty():
		return
	var run = runs[owned]
	if plugin.get_editor_interface().is_playing_scene() and plugin.get_editor_interface().get_playing_scene() != SCENE:
		_finish_closed(owned)
	elif not plugin.get_editor_interface().is_playing_scene() and Time.get_ticks_msec() - run.started_ticks > 1000:
		_finish_closed(owned)
	elif stop_at > 0 and Time.get_ticks_msec() >= stop_at:
		if _owns_playing_scene():
			plugin.get_editor_interface().stop_playing_scene()
		_finish_closed(owned)

func _recover_snapshot(id):
	if id != owned or not runs.has(id) or runs[id].state in TERMINAL:
		return
	var path = BASE + id + ".snapshot.json"
	if FileAccess.file_exists(path):
		var snapshot = JSON.parse_string(FileAccess.get_file_as_string(path))
		if snapshot is Dictionary:
			receive(snapshot, runs[id].session_id)

func _finish_closed(id):
	if not runs.has(id):
		return
	var run = runs[id]
	_recover_snapshot(id)
	run.window_open = false
	run.debugger_paused = false
	if run.state not in TERMINAL:
		run.state = "aborted" if run.stop_requested else "runtime_error"
		run.incomplete = true
		run.elapsed_seconds = float(Time.get_ticks_msec() - run.started_ticks) / 1000.0
	_save(run)
	if owned == id:
		owned = ""
		stop_at = 0
	if FileAccess.file_exists(LAUNCH):
		DirAccess.remove_absolute(LAUNCH)

func _options():
	return panel._gut_config_gui.get_options(panel._gut_config.options).duplicate(true)

func _discover(options):
	var gut = load("res://addons/gut/gut.gd").new()
	var config = load("res://addons/gut/gut_config.gd").new()
	config.options = options.duplicate(true)
	config.apply_options(gut)
	var tests = []
	for script in gut.get_test_collector().scripts:
		if options.get("selected", "") != "" and options.get("selected") != null and not script.get_filename().contains(options.selected):
			continue
		if not gut._does_class_name_match(options.get("inner_class", ""), script.inner_class_name):
			continue
		for test in script.tests:
			if options.get("unit_test_name", "") != "" and options.get("unit_test_name") != null and not test.name.contains(options.unit_test_name):
				continue
			tests.append({"script": script.path, "inner_class": script.inner_class_name, "test_name": test.name})
	gut.free()
	return tests

func _selection(args, options):
	options.selected = ""
	options.inner_class = args.get("inner_class", "")
	options.unit_test_name = args.get("test_name", "")
	if args.has("script"):
		if not args.script.begins_with("res://") or not args.script.ends_with(".gd") or not FileAccess.file_exists(args.script):
			return "script must point to an existing res:// GDScript."
		options.dirs = []
		options.tests = [args.script]
	return ""

func start_run(options, source = "mcp", total = 0):
	if plugin.get_editor_interface().is_playing_scene() or not owned.is_empty():
		return {"error": "A game or test run is already open. Stop it before starting another run."}
	var id = "%s-%s" % [Time.get_unix_time_from_system(), Time.get_ticks_usec()]
	var run = {"run_id": id, "source": source, "state": "starting", "started_ticks": Time.get_ticks_msec(), "started_at": Time.get_unix_time_from_system(), "elapsed_seconds": 0.0, "current_test": {}, "completed_tests": 0, "total_tests": total, "debugger_paused": false, "window_open": true, "incomplete": true, "stop_requested": false, "summary": {}, "tests": [], "warnings": [], "errors": [], "output": "", "output_truncated": false, "session_id": -1}
	var config = load("res://addons/gut/gut_config.gd").new()
	config.options = options.duplicate(true)
	var config_path = BASE + id + ".config.json"
	if config.write_options(config_path) != OK:
		return {"error": "Could not save the run configuration."}
	if not _write(LAUNCH, {"run_id": id, "config": config_path}):
		return {"error": "Could not save the run handoff."}
	runs[id] = run
	order.append(id)
	current = id
	owned = id
	_save(run)
	_prune()
	return {"run_id": id, "state": "starting"}

func register_panel_run(options):
	return start_run(options, "panel")

func receive(snapshot, session_id):
	var id = snapshot.get("run_id", "")
	if id != owned or not runs.has(id):
		return
	var run = runs[id]
	if run.session_id != -1 and run.session_id != session_id:
		return
	if run.state in TERMINAL and snapshot.get("state", "") not in TERMINAL:
		return
	var was_terminal = run.state in TERMINAL
	run.session_id = session_id
	for key in ["state", "current_test", "completed_tests", "total_tests", "summary", "tests", "warnings", "errors", "output", "output_truncated", "incomplete"]:
		if snapshot.has(key):
			run[key] = snapshot[key]
	if not was_terminal:
		run.elapsed_seconds = float(Time.get_ticks_msec() - run.started_ticks) / 1000.0
	_save(run)
	if run.state in TERMINAL:
		panel.load_result_output()

func debug_break(session_id, paused, can_debug):
	if owned.is_empty() or runs[owned].session_id != session_id:
		return
	runs[owned].debugger_paused = paused
	runs[owned].debugger_can_continue = can_debug
	_save(runs[owned])

func session_stopped(session_id):
	if not owned.is_empty() and runs[owned].session_id == session_id:
		_finish_closed(owned)

func _save(run):
	_write(BASE + run.run_id + ".json", run)

func _write(path, data):
	var file = FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data))
	file.close()
	return DirAccess.rename_absolute(path + ".tmp", path) == OK

func _load_runs():
	for name in DirAccess.get_files_at(BASE):
		if name.ends_with(".json") and name != "launch.json" and not name.ends_with(".config.json") and not name.ends_with(".snapshot.json"):
			var data = JSON.parse_string(FileAccess.get_file_as_string(BASE + name))
			if data is Dictionary and data.has("run_id"):
				var snapshot_path = BASE + data.run_id + ".snapshot.json"
				if FileAccess.file_exists(snapshot_path):
					var snapshot = JSON.parse_string(FileAccess.get_file_as_string(snapshot_path))
					if snapshot is Dictionary and snapshot.get("run_id") == data.run_id:
						for key in ["state", "current_test", "completed_tests", "total_tests", "summary", "tests", "warnings", "errors", "output", "output_truncated", "incomplete"]:
							if snapshot.has(key) and not (data.state in TERMINAL and snapshot.get("state") not in TERMINAL):
								data[key] = snapshot[key]
				data.window_open = false
				data.debugger_paused = false
				if data.state not in TERMINAL:
					data.state = "runtime_error"
					data.incomplete = true
				runs[data.run_id] = data
	order = runs.keys()
	order.sort_custom(func(a, b): return runs[a].started_at < runs[b].started_at)
	_prune()
	if not order.is_empty():
		current = order.back()

func _prune():
	while order.size() > 10:
		var id = order.pop_front()
		runs.erase(id)
		DirAccess.remove_absolute(BASE + id + ".json")
		DirAccess.remove_absolute(BASE + id + ".config.json")
		DirAccess.remove_absolute(BASE + id + ".snapshot.json")
		DirAccess.remove_absolute(BASE + id + ".snapshot.tmp")

func _schema(properties):
	return {"type": "object", "properties": properties, "additionalProperties": false}

func tool_list():
	var str_type = {"type": "string"}
	var page = {"offset": {"type": "integer", "minimum": 0}, "limit": {"type": "integer", "minimum": 1, "maximum": 100}}
	var selection = {"script": str_type, "inner_class": str_type, "test_name": str_type}
	var list_args = selection.duplicate(true)
	list_args.merge(page)
	var run_args = selection.duplicate(true)
	run_args.merge({"close_on_finish": {"type": "boolean", "default": true}, "ignore_pause": {"type": "boolean", "default": true}})
	var results_args = page.duplicate(true)
	results_args.merge({"run_id": str_type, "section": {"type": "string", "enum": ["tests", "warnings", "errors", "output"]}})
	var definitions = [
		["gut_get_config", "Read GUT configuration, versions, and MCP connection status.", {}],
		["gut_list_tests", "Discover and list tests page by page (substring filters).", list_args],
		["gut_run_tests", "Start tests in the editor and return a run_id immediately. Runs have no timeout.", run_args],
		["gut_get_run_status", "Read state, progress, GUT pause, debugger status, and window status.", {"run_id": str_type}],
		["gut_get_results", "Read results or partial results page by page; output uses 4096-character chunks.", results_args],
		["gut_continue", "Resume a GUT pause before teardown.", {"run_id": str_type}],
		["gut_stop", "Stop a GUT run or close its results window. Safe to repeat.", {"run_id": str_type}]
	]
	var result = []
	for definition in definitions:
		result.append({"name": definition[0], "description": definition[1], "inputSchema": _schema(definition[2])})
	return result

func call_tool(name, args):
	if name == "__list":
		return tool_list()
	var definition = null
	for tool in tool_list():
		if tool.name == name:
			definition = tool
	if definition == null:
		return _result({"error": "Unknown tool: " + name}, true)
	for key in args:
		if not definition.inputSchema.properties.has(key):
			return _result({"error": "Unknown argument: " + key}, true)
		var rule = definition.inputSchema.properties[key]
		var value = args[key]
		if (rule.type == "string" and not value is String) or (rule.type == "boolean" and not value is bool) or (rule.type == "integer" and (not (value is int or value is float) or value != int(value))):
			return _result({"error": "Invalid type for argument: " + key}, true)
		if rule.has("minimum") and value < rule.minimum or rule.has("maximum") and value > rule.maximum or rule.has("enum") and value not in rule.enum:
			return _result({"error": "Invalid value for argument: " + key}, true)
	var data = _call(name, args)
	return _result(data, data.has("error"))

func _result(data, failed = false):
	return {"content": [{"type": "text", "text": JSON.stringify(data)}], "structuredContent": data, "isError": failed}

func _bounded(value):
	if value is String:
		return value.left(4096)
	if value is Array:
		var result = []
		for item in value.slice(0, 100):
			result.append(_bounded(item))
		return result
	if value is Dictionary:
		var result = {}
		for key in value:
			result[key] = _bounded(value[key])
		return result
	return value

func _page(items, args):
	var offset = int(args.get("offset", 0))
	var limit = int(args.get("limit", 50))
	var end = mini(offset, items.size())
	var result = []
	var bytes = 0
	var truncated = false
	while end < items.size() and result.size() < limit:
		var item = _bounded(items[end])
		var encoded = JSON.stringify(item)
		var size = encoded.to_utf8_buffer().size()
		if size > 60000:
			item = {"truncated": true, "preview": encoded.left(4096)}
			size = JSON.stringify(item).to_utf8_buffer().size()
			truncated = true
		if bytes + size > 60000:
			break
		truncated = truncated or JSON.stringify(item) != JSON.stringify(items[end])
		result.append(item)
		bytes += size
		end += 1
	return {"items": result, "total": items.size(), "next_offset": end if end < items.size() else null, "page_truncated": truncated}

func _call(name, args):
	if name == "gut_get_config":
		var opts = _options()
		return {"directories": opts.dirs, "tests": opts.tests, "prefix": opts.prefix, "suffix": opts.suffix, "include_subdirs": opts.include_subdirs, "filters": {"selected": opts.selected, "inner_class": opts.inner_class, "test_name": opts.unit_test_name}, "gut_version": "9.7.1", "godot_version": Engine.get_version_info().string, "mcp": {"enabled": server.listener.is_listening(), "url": "http://127.0.0.1:%s/mcp" % server.port, "error": server.error, "requests": server.requests, "active_connections": server.clients.size(), "last_request_at": server.last_request_at, "protocol_versions": server.VERSIONS}, "recent_run_ids": order.duplicate()}
	if name in ["gut_list_tests", "gut_run_tests"]:
		if name == "gut_run_tests" and (plugin.get_editor_interface().is_playing_scene() or not owned.is_empty()):
			return {"error": "A game or test run is already open. Stop it before starting another run."}
		var options = _options()
		var error = _selection(args, options)
		if not error.is_empty():
			return {"error": error}
		var tests = _discover(options)
		if name == "gut_list_tests":
			return _page(tests, args)
		if tests.is_empty():
			return {"error": "No tests match this selection. Check the configured directories and filters."}
		options.should_exit = args.get("close_on_finish", true)
		options.should_exit_on_success = false
		options.ignore_pause = args.get("ignore_pause", true)
		var result = start_run(options, "mcp", tests.size())
		if not result.has("error"):
			panel.clear_results()
			panel._is_running = true
			plugin.get_editor_interface().play_custom_scene(SCENE)
		return result
	var id = args.get("run_id", current)
	if not runs.has(id):
		return {"error": "Unknown run_id: " + id}
	_recover_snapshot(id)
	var run = runs[id]
	if name == "gut_get_run_status":
		var status = {}
		for key in ["run_id", "source", "state", "current_test", "completed_tests", "total_tests", "elapsed_seconds", "debugger_paused", "window_open", "incomplete", "stop_requested"]:
			status[key] = run[key]
		if run.state not in TERMINAL:
			status.elapsed_seconds = float(Time.get_ticks_msec() - run.started_ticks) / 1000.0
		status.gut_paused = run.state == "gut_paused"
		status.debugger_can_continue = run.get("debugger_can_continue", false)
		if run.debugger_paused:
			status.state = "debugger_paused"
		return status
	if name == "gut_get_results":
		var section = args.get("section", "tests")
		var items = run[section]
		if section == "output":
			items = []
			for offset in range(0, run.output.length(), 4096):
				items.append(run.output.substr(offset, 4096))
		var page = _page(items, args)
		page.merge({"run_id": id, "incomplete": run.incomplete, "summary": run.summary, "section": section, "output_truncated": run.output_truncated})
		return page
	if name == "gut_continue":
		if id != owned or run.state != "gut_paused" or run.debugger_paused or run.session_id < 0:
			return {"error": "This run is not paused by GUT before teardown, or its debugger session is not ready."}
		bridge.get_session(run.session_id).send_message("gut_mcp:continue", [id])
		return {"run_id": id, "continue_requested": true}
	if name == "gut_stop":
		if id != owned or not run.window_open:
			return {"run_id": id, "already_stopped": true}
		if not run.stop_requested:
			run.stop_requested = true
			stop_at = Time.get_ticks_msec() + 2000
			if run.session_id >= 0:
				bridge.get_session(run.session_id).send_message("gut_mcp:stop", [id])
			_save(run)
		return {"run_id": id, "stop_requested": true}
	return {"error": "Unknown tool"}
