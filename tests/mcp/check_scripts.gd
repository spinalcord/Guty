extends SceneTree

func _initialize():
	var failed = false
	for path in ["res://addons/gut/mcp/http_server.gd", "res://addons/gut/mcp/debugger_bridge.gd", "res://addons/gut/mcp/run_manager.gd", "res://addons/gut/mcp/runtime_bridge.gd", "res://addons/gut/gut_plugin.gd", "res://addons/gut/gui/GutRunner.gd", "res://addons/gut/gui/GutBottomPanel.gd"]:
		var script = load(path)
		if script == null or not script.can_instantiate():
			printerr("FAILED: ", path)
			failed = true
	quit(1 if failed else 0)
