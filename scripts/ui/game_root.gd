extends Node

## Owns the two screens and swaps between them.
##
## It exists mostly so [signal PlayScreen.exit_requested] finally has a listener.
## Until now nothing was connected to it and `Esc` fell back to quitting the game,
## which was a stand-in for the menu that did not exist yet.

const MENU_SCENE := preload("res://scenes/menu.tscn")
const PLAY_SCENE := preload("res://scenes/play.tscn")

var _screen: Node = null


func _ready() -> void:
	show_menu()


func show_menu() -> void:
	var menu: MenuScreen = MENU_SCENE.instantiate()
	menu.level_chosen.connect(_on_level_chosen)
	_swap(menu)


func _on_level_chosen(level: SimLevel) -> void:
	var play: PlayScreen = PLAY_SCENE.instantiate()
	play.exit_requested.connect(show_menu)
	# Set before adding: the play screen falls back to level 1 in `_ready` when it
	# has none, which is what lets play.tscn still be run on its own.
	play.load_level(level)
	_swap(play)


func _swap(next: Node) -> void:
	if _screen != null:
		_screen.queue_free()
	_screen = next
	add_child(next)
