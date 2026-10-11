extends "res://addons/gut/gui/GutRunner.gd"

signal quit_requested(code)
var quit_code = -1

func quit(code):
	quit_code = code
	quit_requested.emit(code)
