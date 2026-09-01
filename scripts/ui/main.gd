class_name Main
extends Control

## Root scene: owns the level pack and swaps between the three screens.
##
## Screens are created once and shown/hidden rather than instantiated on demand,
## so returning to the level grid keeps its scroll position and the game screen
## keeps nothing stale — [method GameScreen.play] resets everything it owns.

const GAME_SCREEN := preload("res://scenes/game_screen.tscn")

var pack: LevelPack

var _menu: MainMenu
var _select: LevelSelect
var _game: GameScreen


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# One theme on the root; every screen below inherits it.
	theme = PolarisTheme.build()
	pack = LevelPack.load_default()
	if PlayerProgress.adopt_pack(pack):
		print("Level-Pack hat sich geändert — Fortschritt zurückgesetzt.")

	_menu = MainMenu.new()
	_menu.continue_requested.connect(_on_continue)
	_menu.select_requested.connect(_show_select)
	_menu.prototype_requested.connect(_on_prototype)
	_menu.quit_requested.connect(_on_quit)
	add_child(_menu)

	_select = LevelSelect.new()
	_select.level_chosen.connect(_play)
	_select.back_requested.connect(_show_menu)
	add_child(_select)

	_game = GAME_SCREEN.instantiate()
	_game.exit_requested.connect(_show_select)
	_game.next_level_requested.connect(_on_next_level)
	add_child(_game)

	_show_menu()


func _show_menu() -> void:
	_menu.refresh(pack)
	_only_visible(_menu)


func _show_select() -> void:
	_select.refresh(pack)
	_only_visible(_select)


func _play(level: Level) -> void:
	_only_visible(_game)
	_game.play(pack, level)


func _only_visible(screen: Control) -> void:
	for child: Node in [_menu, _select, _game]:
		var control := child as Control
		control.visible = control == screen
		# A hidden screen must not eat keystrokes meant for the visible one.
		# Disabling processing is what actually does that — these are plain
		# containers with no focus mode, so grabbing focus here would only warn.
		control.process_mode = (
			Node.PROCESS_MODE_INHERIT if control == screen else Node.PROCESS_MODE_DISABLED
		)


func _on_continue() -> void:
	var level := PlayerProgress.next_level(pack)
	if level != null:
		_play(level)


func _on_next_level() -> void:
	var next := pack.next_after(_game.level.id)
	if next == null:
		_show_select()
		return
	_play(next)


## The prototype is a whole separate scene rather than another screen here: it
## shares none of the campaign's state, and swapping the scene keeps it that way.
## Esc inside it comes straight back.
func _on_prototype() -> void:
	get_tree().change_scene_to_file("res://scenes/prototype.tscn")


func _on_quit() -> void:
	get_tree().quit()
