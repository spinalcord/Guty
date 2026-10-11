extends SceneTree

var failures = 0
func check(value, label):
	if not value:
		failures += 1
		printerr("FAIL: ", label)

func _initialize():
	_run.call_deferred()

func make_runner(filter, close_on_finish = true, ignore_pause = true):
	var runner = load("res://addons/gut/gui/GutRunner.tscn").instantiate()
	runner.set_script(load("res://tests/mcp/recording_runner.gd"))
	root.add_child(runner)
	runner.gut_config = load("res://addons/gut/gut_config.gd").new()
	runner.gut_config.options.tests = ["res://tests/mcp/test_fixture.gd"]
	runner.gut_config.options.unit_test_name = filter
	runner.gut_config.options.should_exit = close_on_finish
	runner.gut_config.options.ignore_pause = ignore_pause
	runner.result_bbcode_path = "user://runtime-output.txt"
	runner.result_json_path = "user://runtime-results.json"
	runner._ran_from_editor = true
	var bridge = load("res://addons/gut/mcp/runtime_bridge.gd").new()
	runner.add_child(bridge)
	bridge.setup(runner, "runtime-test")
	runner._mcp_bridge = bridge
	return runner

func _run():
	# Test harness deadline; production test runs have no automatic limit.
	create_timer(15).timeout.connect(func(): printerr("Runtime harness timed out"); quit(1))
	for filter in ["success", "failure", "pending"]:
		var runner = make_runner(filter)
		runner.run_tests()
		await runner.quit_requested
		check(runner._mcp_bridge.state == "completed", filter + " completed")
		check(runner._mcp_bridge.completed >= 1, filter + " progress")
		check(runner._wrote_results, filter + " writes results before closing")
		var results = JSON.parse_string(FileAccess.get_file_as_string(runner.result_json_path))
		var props = results.test_scripts.props
		var snapshot = JSON.parse_string(FileAccess.get_file_as_string("user://gut_temp_directory/mcp/runtime-test.snapshot.json"))
		check(snapshot.state == "completed" and not snapshot.incomplete, filter + " final snapshot persisted")
		if filter == "success":
			check(props.passing == 2 and runner.quit_code == 0, "successful outer and inner tests")
			check(snapshot.warnings.size() >= 1 and snapshot.total_tests == 2, "warnings and total progress")
			check(FileAccess.get_file_as_string(runner.result_bbcode_path).contains("MCP fixture output"), "test output saved")
		elif filter == "failure":
			check(props.failures == 1 and runner.quit_code == 1, "failed assertion and exit code")
			check(snapshot.tests[0].failing[0].contains("Deliberate MCP fixture failure"), "assertion failure detail")
		else:
			check(props.pending == 1, "pending results")
		runner.queue_free()
		await process_frame
	var paused = make_runner("pause", false, false)
	paused.run_tests()
	while paused._mcp_bridge.state != "gut_paused":
		await process_frame
	check(paused._mcp_bridge.state == "gut_paused", "actual GUT pause")
	paused._mcp_bridge._capture.call_deferred("continue", ["runtime-test"])
	await paused.gut.end_run
	check(paused._mcp_bridge.state == "completed" and paused.quit_code == -1, "continue and keep window")
	paused._mcp_bridge._capture("stop", ["runtime-test"])
	await paused.quit_requested
	check(paused._mcp_bridge.state == "completed", "close result window preserves completion")
	paused.queue_free()
	await process_frame
	var waiting = make_runner("waiting")
	waiting.run_tests()
	while not waiting._mcp_bridge.current_test.has("test_name"):
		await process_frame
	waiting._mcp_bridge._capture("stop", ["wrong-id"])
	check(not waiting._mcp_bridge.stopping, "runtime rejects wrong id")
	waiting._mcp_bridge._capture("stop", ["runtime-test"])
	await waiting.quit_requested
	check(waiting._mcp_bridge.state == "aborted" and waiting._wrote_results, "stop waiting test persists partials")
	waiting.queue_free()
	await process_frame
	print("Runtime checks: ", failures, " failures")
	quit(1 if failures else 0)
