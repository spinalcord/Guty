extends SceneTree

class FakeEditor:
	extends RefCounted
	var playing = false
	var scene = ""
	var stopped = 0
	func is_playing_scene(): return playing
	func get_playing_scene(): return scene
	func play_custom_scene(path):
		playing = true
		scene = path
	func stop_playing_scene():
		playing = false
		stopped += 1

class FakePlugin:
	extends RefCounted
	var editor = FakeEditor.new()
	func get_editor_interface(): return editor

class ConfigGui:
	extends RefCounted
	func get_options(options): return options

class FakePanel:
	extends RefCounted
	var _gut_config = load("res://addons/gut/gut_config.gd").new()
	var _gut_config_gui = ConfigGui.new()
	var _is_running = false
	var result_loads = 0
	func clear_results(): pass
	func load_result_output(): result_loads += 1

class Session:
	extends RefCounted
	var sent = []
	func send_message(message, data): sent.append([message, data])

class Bridge:
	extends RefCounted
	var session = Session.new()
	func get_session(_id): return session

var manager
var failures = 0
func check(value, label):
	if not value:
		failures += 1
		printerr("FAIL: ", label)
func call_tool(name, args = {}):
	return manager.call_tool(name, args).structuredContent

func _initialize():
	manager = load("res://addons/gut/mcp/run_manager.gd").new()
	manager.plugin = FakePlugin.new()
	manager.panel = FakePanel.new()
	manager.server = load("res://addons/gut/mcp/http_server.gd").new()
	manager.bridge = Bridge.new()
	DirAccess.make_dir_recursive_absolute(manager.BASE)
	check(manager.tool_list().size() == 7, "seven tools")
	check(call_tool("gut_get_config").gut_version == "9.7.1", "config version")
	check(call_tool("gut_run_tests", {"script": "missing.gd"}).has("error"), "invalid script")
	check(call_tool("gut_run_tests", {"ignore_pause": "false"}).has("error"), "boolean validation")
	check(call_tool("gut_list_tests", {"limit": 101}).has("error"), "page size validation")
	check(call_tool("gut_list_tests", {"offset": -1}).has("error"), "offset validation")
	check(call_tool("gut_list_tests", {"limit": 1.5}).has("error"), "integer validation")
	check(call_tool("gut_get_results", {"section": "bad"}).has("error"), "enum validation")
	check(call_tool("gut_get_config", {"extra": true}).has("error"), "unknown argument")
	check(call_tool("unknown").has("error"), "unknown tool")
	for tool in ["gut_get_run_status", "gut_get_results", "gut_continue", "gut_stop"]:
		check(call_tool(tool, {"run_id": "missing"}).has("error"), "unknown run: " + tool)
	var fixture = "res://tests/mcp/test_fixture.gd"
	var listed = call_tool("gut_list_tests", {"script": fixture, "limit": 2})
	check(listed.total == 7 and listed.items.size() == 2 and listed.next_offset == 2, "GUT discovery and pagination")
	var inner = call_tool("gut_list_tests", {"script": fixture, "inner_class": "inner", "test_name": "success"})
	check(inner.total == 1 and inner.items[0].inner_class == "TestInner", "inner filter uses GUT case insensitive semantics")
	check(call_tool("gut_run_tests", {"script": fixture, "test_name": "no_match"}).has("error"), "empty selection")
	var saved = manager.panel._gut_config.options.duplicate(true)
	var start = call_tool("gut_run_tests", {"script": fixture, "test_name": "success"})
	check(start.has("run_id"), "start returns id")
	var id = start.run_id
	var config = JSON.parse_string(FileAccess.get_file_as_string(manager.BASE + id + ".config.json"))
	check(config.should_exit and config.ignore_pause and config.tests == [fixture], "MCP defaults and exact script selection")
	check(saved == manager.panel._gut_config.options, "settings unchanged")
	check(call_tool("gut_run_tests", {"script": fixture}).has("error"), "one run at a time")
	manager.receive({"run_id": id, "state": "gut_paused", "summary": {"passing": 1}, "tests": [{"test_name": "test_success"}], "output": "hello"}, 0)
	check(call_tool("gut_get_run_status").state == "gut_paused", "pause status")
	check(call_tool("gut_continue").continue_requested, "continue")
	manager.debug_break(0, true, true)
	check(call_tool("gut_get_run_status").state == "debugger_paused", "debugger status separate")
	check(call_tool("gut_continue").has("error"), "no debugger continue")
	manager.debug_break(0, false, true)
	check(call_tool("gut_get_results").incomplete, "partial results")
	check(call_tool("gut_stop").stop_requested, "stop requested")
	manager.stop_at = Time.get_ticks_msec() - 1
	manager._process(0)
	check(manager.plugin.editor.stopped == 1, "forced stop fallback")
	check(call_tool("gut_get_run_status").state == "aborted", "aborted status")
	check(call_tool("gut_get_results").summary.passing == 1, "partial results survive forced stop")
	manager.plugin.editor.play_custom_scene("res://normal_game.tscn")
	check(call_tool("gut_stop", {"run_id": id}).already_stopped and manager.plugin.editor.stopped == 1, "repeated stop protects game")
	check(call_tool("gut_run_tests", {"script": fixture}).has("error"), "game blocks tests")
	manager.plugin.editor.playing = false
	var second = call_tool("gut_run_tests", {"script": fixture, "inner_class": "TestInner", "close_on_finish": false, "ignore_pause": false})
	check(second.has("run_id"), "restart after force stop")
	manager.receive({"run_id": second.run_id, "state": "completed", "incomplete": false, "summary": {"passing": 1}}, 1)
	check(call_tool("gut_get_run_status").window_open and not call_tool("gut_get_results").incomplete, "completed window independent")
	call_tool("gut_stop")
	manager.stop_at = Time.get_ticks_msec() - 1
	manager._process(0)
	check(call_tool("gut_get_run_status").state == "completed", "closing window keeps result")
	check(call_tool("gut_get_results", {"run_id": id, "section": "output"}).items == ["hello"], "output paging")
	var bounded = manager._page(["x".repeat(10000)], {})
	check(bounded.page_truncated and bounded.items[0].length() == 4096, "bounded output")
	var recover = manager.register_panel_run(saved)
	manager._write(manager.BASE + recover.run_id + ".snapshot.json", {"run_id": recover.run_id, "state": "completed", "incomplete": false, "summary": {"passing": 77}})
	manager._finish_closed(recover.run_id)
	check(call_tool("gut_get_run_status").state == "completed" and call_tool("gut_get_results").summary.passing == 77, "final snapshot recovered after disconnect")
	for index in range(11):
		var manual = manager.register_panel_run(saved)
		check(manual.has("run_id"), "panel registration")
		manager._finish_closed(manual.run_id)
	check(manager.order.size() == 10, "ten runs retained")
	manager._load_runs()
	check(manager.order.size() == 10 and not manager.runs[manager.current].window_open, "history restored closed")
	# Unit harness data stays inside a dedicated XDG_DATA_HOME.
	for file in DirAccess.get_files_at(manager.BASE):
		DirAccess.remove_absolute(manager.BASE + file)
	manager.server.free()
	manager.free()
	print("Manager checks: ", failures, " failures")
	quit(1 if failures else 0)
