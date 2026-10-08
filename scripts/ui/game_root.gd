extends Node

## Owns the screens and swaps between them.
##
## It exists mostly so [signal PlayScreen.exit_requested] finally has a listener.
## Until now nothing was connected to it and `Esc` fell back to quitting the game,
## which was a stand-in for the menu that did not exist yet.

const MENU_SCENE := preload("res://scenes/menu.tscn")
const PLAY_SCENE := preload("res://scenes/play.tscn")
const BUILD_SCENE := preload("res://scenes/build.tscn")

var _screen: Node = null

## The level being drafted in the build mode.
##
## Held here and not in the build screen, because the build screen is freed while
## its draft is being test-played. The draft is the one thing that has to outlive
## both screens.
var _draft: SimLevel = null

## A won test run waiting to be handed over as the draft's par: `[placements,
## recording]`, or empty.
var _pending_win: Array = []


func _ready() -> void:
	show_menu()


func show_menu() -> void:
	var menu: MenuScreen = MENU_SCENE.instantiate()
	menu.level_chosen.connect(_on_level_chosen)
	menu.build_requested.connect(show_build)
	_swap(menu)


## Opens the build mode on the current draft, or on a fresh one.
func show_build() -> void:
	var build: BuildScreen = BUILD_SCENE.instantiate()
	build.exit_requested.connect(show_menu)
	build.test_requested.connect(_on_test_requested)
	# Set before adding: `_ready` starts a blank draft when it has none.
	if _draft != null:
		build.level = _draft
	_swap(build)


func _on_level_chosen(level: SimLevel) -> void:
	var play: PlayScreen = PLAY_SCENE.instantiate()
	play.exit_requested.connect(show_menu)
	_start(play, level)


## Test-plays the draft, and comes back to the build mode rather than the menu.
func _on_test_requested(draft: SimLevel) -> void:
	_draft = draft
	var play: PlayScreen = PLAY_SCENE.instantiate()
	play.exit_requested.connect(_finish_test.bind(play))
	_start(play, draft)


## Ends a test run and carries a win back into the draft.
##
## The play screen is read here, as it is left, rather than pushing anything from
## inside it: it has no business knowing a build mode exists. What it already
## records — the placements plus one bitmask per tick — is exactly what a par is.
##
## Read *now* and not from `tree_exiting`: the swap adds the next screen before the
## old one actually leaves the tree, so a deferred handler would arrive after the
## build screen had already asked for it.
func _finish_test(play: PlayScreen) -> void:
	if not play.won_recording.is_empty():
		_pending_win = [play.won_placed, play.won_recording]
	show_build()


func _start(play: PlayScreen, level: SimLevel) -> void:
	# Set before adding: the play screen falls back to level 1 in `_ready` when it
	# has none, which is what lets play.tscn still be run on its own.
	play.load_level(level)
	_swap(play)


func _swap(next: Node) -> void:
	if _screen != null:
		_screen.queue_free()
	_screen = next
	add_child(next)
	if next is BuildScreen and not _pending_win.is_empty():
		(next as BuildScreen).absorb_win(_pending_win[0], _pending_win[1])
		_pending_win = []
