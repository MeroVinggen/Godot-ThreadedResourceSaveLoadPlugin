@tool
extends EditorPlugin

func _enter_tree():
	add_autoload_singleton("ThreadedLoader", "res://addons/ThreadedResourceSaveLoadPlugin/ThreadedResourceLoader.gd")
	add_autoload_singleton("ThreadedSaver", "res://addons/ThreadedResourceSaveLoadPlugin/ThreadedResourceSaver.gd")

func _exit_tree():
	remove_autoload_singleton("ThreadedLoader")
	remove_autoload_singleton("ThreadedSaver")
