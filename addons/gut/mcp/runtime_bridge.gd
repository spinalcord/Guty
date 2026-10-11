extends Node

const MAX_OUTPUT = 262144
var runner
var run_id = ""
var state = "running"
var current_test = {}
var completed = 0
var total_tests = 0
var stopping = false
var heartbeat = 0.0

func _process(delta):
	if state in ["completed", "aborted", "runtime_error"]:
		return
	heartbeat += delta
	if heartbeat >= 1.0:
		heartbeat = 0.0
		publish()

func setup(value, id):
	runner = value
	run_id = id
	if EngineDebugger.is_active():
		EngineDebugger.register_message_capture("gut_mcp", _capture)
	var gut = runner.gut
	gut.start_script.connect(func(script): current_test = {"script": script.path, "inner_class": script.inner_class_name})
	gut.start_test.connect(func(test_name):
		current_test["test_name"] = test_name
		publish())
	gut.end_test.connect(func():
		completed += 1
		publish())
	gut.start_pause_before_teardown.connect(func():
		state = "gut_paused"
		publish())
	gut.end_pause_before_teardown.connect(func():
		state = "running"
		publish())
	gut.start_run.connect(_started)

func _started():
	for script in runner.gut.get_test_collector().scripts:
		if not runner.gut._does_class_name_match(runner.gut.inner_class_name, script.inner_class_name):
			continue
		if runner.gut_config.options.selected != null and runner.gut_config.options.selected != "" and not script.get_filename().contains(runner.gut_config.options.selected):
			continue
		for test in script.tests:
			if runner.gut.unit_test_name == "" or test.name.contains(runner.gut.unit_test_name):
				total_tests += 1
	publish()

func _exit_tree():
	if EngineDebugger.has_capture("gut_mcp"):
		EngineDebugger.unregister_message_capture("gut_mcp")

func _capture(message: String, data: Array) -> bool:
	if data.size() != 1 or data[0] != run_id:
		return false
	if message == "continue":
		if state == "gut_paused":
			runner.gut.end_teardown_pause()
		return true
	if message == "stop":
		_stop.call_deferred()
		return true
	return false

func _stop():
	if stopping:
		return
	stopping = true
	# Snapshot and persist before asking SceneTree to quit. Tests awaiting a
	# signal need not finish; a blocked process is stopped by the editor.
	runner._write_results_for_gut_panel()
	if state != "completed":
		state = "aborted"
	publish()
	runner.quit(0)

func finish(code):
	if stopping:
		return
	state = "completed" if code == 0 else "runtime_error"
	publish()

func publish():
	var exporter = load("res://addons/gut/result_exporter.gd").new()
	var results = exporter.get_results_dictionary(runner.gut)
	var tests = []
	for script in results.test_scripts.scripts:
		for test in results.test_scripts.scripts[script].tests:
			var entry = results.test_scripts.scripts[script].tests[test].duplicate(true)
			entry.merge({"script": script, "test_name": test})
			tests.append(entry)
	var output: String = runner._gui.get_textbox().get_parsed_text()
	var snapshot = {"run_id": run_id, "state": state, "current_test": current_test.duplicate(), "completed_tests": completed, "total_tests": total_tests, "summary": results.test_scripts.props, "tests": tests, "warnings": runner.gut.logger.get_warnings().duplicate(), "errors": runner.gut.logger.get_errors().duplicate(), "output": output.left(MAX_OUTPUT), "output_truncated": output.length() > MAX_OUTPUT, "incomplete": state != "completed"}
	# Persist before quit as well as sending the debugger message. A final
	# message can arrive after the session disconnects; the editor recovers it.
	var base = "user://gut_temp_directory/mcp/"
	DirAccess.make_dir_recursive_absolute(base)
	var file = FileAccess.open(base + run_id + ".snapshot.tmp", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(snapshot))
		file.close()
		DirAccess.rename_absolute(base + run_id + ".snapshot.tmp", base + run_id + ".snapshot.json")
	if EngineDebugger.is_active():
		EngineDebugger.send_message("gut_mcp:snapshot", [snapshot])
