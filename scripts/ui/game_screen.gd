class_name GameScreen
extends Control

## The play screen: board on the left, everything you can do to it on the right.
##
## The side panel is built in code rather than laid out in the scene because
## almost all of it is data-driven — the move log, the efficiency meter, hints
## that depend on which mechanics this board actually uses. A fixed scene tree
## would only be a place to keep nodes the script would then have to hide again.

signal exit_requested
signal level_completed(finished_level: Level, stars: int)
signal next_level_requested

const ACTION_PLUS := "polaris_tool_plus"
const ACTION_MINUS := "polaris_tool_minus"
const ACTION_ERASE := "polaris_tool_erase"
const ACTION_RESET := "polaris_reset"
const ACTION_UNDO := "polaris_undo"
const ACTION_HINT := "polaris_hint"

@onready var _board: BoardView = $Margin/Columns/BoardPanel/BoardMargin/BoardView
@onready var _side: VBoxContainer = $Margin/Columns/SidePanel/SideMargin/Side

var pack: LevelPack
var level: Level
var state: GameState

var _title_label: Label
var _chapter_label: Label
var _efficiency_label: Label
var _message_label: Label
var _tool_buttons: Dictionary = {}
var _mode_hint: Label
var _move_log: Label
var _undo_button: Button
var _restart_button: Button
var _clear_button: Button
var _hint_button: Button
var _result_layer: Control
var _result_title: Label
var _result_detail: Label
var _result_next: Button


func _ready() -> void:
	state = GameState.new()
	state.name = "GameState"
	add_child(state)
	state.changed.connect(_refresh)
	state.message_changed.connect(_on_message_changed)
	state.solved_level.connect(_on_solved)

	_build_side_panel()
	_build_result_panel()


## Loads [param target] and starts it. Call after the screen is in the tree.
func play(level_pack: LevelPack, target: Level) -> void:
	pack = level_pack
	level = target
	_result_layer.visible = false
	state.setup(target.puzzle, target.par)
	_board.bind(state)
	_refresh()


# --- Side panel -------------------------------------------------------------

func _build_side_panel() -> void:
	var back := Button.new()
	back.text = "‹  Level-Auswahl"
	back.alignment = HORIZONTAL_ALIGNMENT_LEFT
	back.flat = true
	back.pressed.connect(func() -> void: exit_requested.emit())
	_side.add_child(back)

	_title_label = _add_label("", 26, PolarisTheme.INK)
	_chapter_label = _add_label("", 12, PolarisTheme.INK_DIM)

	_side.add_child(_spacer(8))

	_efficiency_label = _add_label("", 14, PolarisTheme.ACCENT)

	_message_label = _add_label("", 13, PolarisTheme.INK_DIM)
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.custom_minimum_size = Vector2(0, 54)

	_build_tool_row()

	_mode_hint = _add_label("", 12, PolarisTheme.ACCENT)
	_mode_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_move_log = _add_label("", 12, PolarisTheme.INK_DIM)
	_move_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	# Push the action buttons to the bottom of the column.
	var filler := Control.new()
	filler.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_side.add_child(filler)

	_undo_button = Button.new()
	_undo_button.text = "↶  Zug zurück   (Z)"
	_undo_button.custom_minimum_size = Vector2(0, 44)
	_undo_button.pressed.connect(func() -> void: state.undo())
	_side.add_child(_undo_button)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_side.add_child(row)

	_restart_button = Button.new()
	_restart_button.text = "Von vorn  (R)"
	_restart_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_restart_button.pressed.connect(func() -> void: state.restart_run())
	row.add_child(_restart_button)

	_clear_button = Button.new()
	_clear_button.text = "Brett leeren"
	_clear_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_clear_button.pressed.connect(func() -> void: state.clear_board())
	row.add_child(_clear_button)

	_hint_button = Button.new()
	_hint_button.text = "Magnete verraten  (H)"
	_hint_button.flat = true
	_hint_button.pressed.connect(_on_hint_pressed)
	_side.add_child(_hint_button)


func _build_tool_row() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_side.add_child(row)

	_tool_buttons.clear()
	_add_tool_button(row, GameState.Tool.PLUS, "1")
	_add_tool_button(row, GameState.Tool.MINUS, "2")
	_add_tool_button(row, GameState.Tool.ERASE, "3")


func _add_tool_button(row: HBoxContainer, tool: GameState.Tool, key: String) -> void:
	var button := Button.new()
	button.toggle_mode = true
	button.custom_minimum_size = Vector2(0, 58)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.set_meta("key", key)
	button.pressed.connect(func() -> void: state.select_tool(tool))
	row.add_child(button)
	_tool_buttons[tool] = button


func _add_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	_side.add_child(label)
	return label


func _spacer(height: int) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	return spacer


# --- Result overlay ---------------------------------------------------------

func _build_result_panel() -> void:
	# The whole overlay lives under one node so it can be shown and hidden as a
	# unit; the scrim both dims the board and swallows clicks, so the result reads
	# as a modal rather than a card floating over a still-live board.
	_result_layer = Control.new()
	_result_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_result_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	_result_layer.visible = false
	add_child(_result_layer)

	var scrim := ColorRect.new()
	scrim.color = Color(PolarisTheme.BG, 0.78)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_result_layer.add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_layer.add_child(center)

	var style := StyleBoxFlat.new()
	style.bg_color = PolarisTheme.PANEL
	style.set_corner_radius_all(20)
	style.set_border_width_all(2)
	style.border_color = PolarisTheme.ACCENT
	style.set_content_margin_all(28)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = Vector2(430, 0)
	center.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	panel.add_child(column)

	_result_title = Label.new()
	_result_title.add_theme_font_size_override("font_size", 30)
	_result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_result_title)

	_result_detail = Label.new()
	_result_detail.add_theme_font_size_override("font_size", 14)
	_result_detail.add_theme_color_override("font_color", PolarisTheme.INK_DIM)
	_result_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_result_detail)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(buttons)

	var retry := Button.new()
	retry.text = "Nochmal"
	retry.custom_minimum_size = Vector2(130, 42)
	retry.pressed.connect(func() -> void: play(pack, level))
	buttons.add_child(retry)

	var to_select := Button.new()
	to_select.text = "Level-Auswahl"
	to_select.custom_minimum_size = Vector2(150, 42)
	to_select.pressed.connect(func() -> void: exit_requested.emit())
	buttons.add_child(to_select)

	_result_next = Button.new()
	_result_next.text = "Weiter  ›"
	_result_next.custom_minimum_size = Vector2(130, 42)
	_result_next.pressed.connect(func() -> void: next_level_requested.emit())
	buttons.add_child(_result_next)


func _on_solved() -> void:
	var stars := state.stars()
	PlayerProgress.record(level.id, stars, state.fired.size())
	level_completed.emit(level, stars)

	_result_title.text = _star_row(stars)
	_result_title.add_theme_color_override("font_color", PolarisTheme.OK)
	_result_detail.text = _result_detail_text(stars)
	_result_next.visible = pack != null and pack.next_after(level.id) != null

	# Let the win flare on the board land before the panel covers it.
	await get_tree().create_timer(0.55).timeout
	_result_layer.visible = true


func _result_detail_text(stars: int) -> String:
	var used := _count("Magnet", "Magnete", state.magnets.size())
	var moves := _count("Zug", "Züge", state.fired.size())
	if stars >= 3:
		return "%s, %s — das ist die Bestlösung." % [used, moves]
	return "%s, %s. Es geht mit %d — probier es nochmal." % [
		used, moves, level.par
	]


func _count(singular: String, plural: String, n: int) -> String:
	return "%d %s" % [n, singular if n == 1 else plural]


func _star_row(stars: int) -> String:
	return "★".repeat(stars) + "☆".repeat(3 - stars)


# --- Refresh ----------------------------------------------------------------

func _refresh() -> void:
	if level == null or state == null or state.puzzle == null:
		return

	_title_label.text = (
		"%d · %s" % [level.id, level.title] if level.title else "Level %d" % level.id
	)
	_chapter_label.text = (
		pack.chapter_title(level.chapter).to_upper() if pack != null else level.chapter.to_upper()
	)
	_efficiency_label.text = _efficiency_text()
	_refresh_tools()

	_mode_hint.text = _mode_hint_text()
	_move_log.text = _move_log_text()

	var busy := state.animating or state.solved
	_undo_button.disabled = busy or state.fired.is_empty()
	_restart_button.disabled = busy or state.fired.is_empty()
	_clear_button.disabled = busy or state.magnets.is_empty()
	_hint_button.disabled = busy or level.solution_magnets.is_empty()


## The live efficiency meter.
##
## The par is withheld until the level has been solved once. Announcing "this
## needs 4 magnets" up front hands over most of the search: it fixes the size of
## the answer before the player has looked at the board. After the first solve it
## becomes the replay target instead, which is when it is motivating rather than
## a hint.
func _efficiency_text() -> String:
	var used := state.magnets.size()
	if level.par <= 0 or PlayerProgress.stars_for(level.id) == 0:
		return "%d %s gesetzt" % [used, "Magnet" if used == 1 else "Magnete"]
	var verdict := "★★★" if used <= level.par else ("★★" if used <= level.par + 1 else "★")
	return "%d von %d Magneten · %s" % [used, level.par, verdict]


func _refresh_tools() -> void:
	for tool: GameState.Tool in _tool_buttons:
		var button: Button = _tool_buttons[tool]
		button.button_pressed = state.selected_tool == tool
		var key: String = button.get_meta("key")
		if tool == GameState.Tool.PLUS:
			button.text = "＋\nAnziehen ×%d  (%s)" % [state.remaining_of(Magnet.Type.PLUS), key]
		elif tool == GameState.Tool.MINUS:
			button.text = "－\nAbstoßen ×%d  (%s)" % [state.remaining_of(Magnet.Type.MINUS), key]
		else:
			button.text = "⌫\nEntfernen  (%s)" % key


## The mechanics this particular board uses, so the player is never surprised by
## a rule that was never on screen.
func _mode_hint_text() -> String:
	var puzzle := state.puzzle
	var notes: Array[String] = []
	if puzzle.is_multi_ball():
		notes.append("%d Kugeln (%d im Ziel)" % [puzzle.ball_count(), state.balls_home()])
	notes.append("Reichweite %d" % puzzle.magnet_reach)
	if puzzle.magnet_strength != Puzzle.UNLIMITED:
		notes.append("Stärke %d" % puzzle.magnet_strength)
	if puzzle.single_use:
		notes.append("jeder Magnet nur 1×")
	if not puzzle.waypoints.is_empty():
		notes.append(
			"Kristalle %d/%d" % [state.collected_waypoints.size(), puzzle.waypoints.size()]
		)
	if not puzzle.gates.is_empty():
		var open_gates := 0
		for cell: Vector2i in puzzle.gates:
			if (puzzle.gates[cell] as Gate).is_open(state.gate_mask):
				open_gates += 1
		notes.append("Tore %d/%d offen" % [open_gates, puzzle.gates.size()])
	return " · ".join(notes)


func _move_log_text() -> String:
	if state.magnets.is_empty():
		return "Linksklick setzt einen Magneten, Rechtsklick entfernt ihn."
	if state.fired.is_empty():
		return "Fahre über einen Magneten — die gestrichelte Linie zeigt seinen Zug."
	var steps: Array[String] = []
	for i in state.fired.size():
		var cell: Vector2i = state.fired[i]
		var type: Magnet.Type = state.magnets[cell]
		steps.append("%d.%s" % [i + 1, "＋" if type == Magnet.Type.PLUS else "－"])
	return "Züge:  " + "   ".join(steps)


func _on_message_changed(text: String, kind: GameState.MessageKind) -> void:
	_message_label.text = text
	var color := PolarisTheme.INK_DIM
	if kind == GameState.MessageKind.WIN:
		color = PolarisTheme.OK
	elif kind == GameState.MessageKind.FAIL:
		color = PolarisTheme.PLUS
	_message_label.add_theme_color_override("font_color", color)


# --- Actions ----------------------------------------------------------------

## Places the level's proven magnets — and stops there. Working out the *order*
## is the other half of the puzzle, and handing that over too would skip the only
## interesting decision left. No search happens: the pipeline already verified
## this exact placement offline.
func _on_hint_pressed() -> void:
	if state.animating or state.solved or level.solution_magnets.is_empty():
		return
	state.apply_placement(level.solution_magnets)
	state.announce("Die Magnete stehen richtig. Die Reihenfolge findest du selbst.")


func _unhandled_input(event: InputEvent) -> void:
	if state == null or not event.is_pressed() or event.is_echo():
		return
	if event.is_action(ACTION_PLUS):
		state.select_tool(GameState.Tool.PLUS)
	elif event.is_action(ACTION_MINUS):
		state.select_tool(GameState.Tool.MINUS)
	elif event.is_action(ACTION_ERASE):
		state.select_tool(GameState.Tool.ERASE)
	elif event.is_action(ACTION_UNDO):
		state.undo()
	elif event.is_action(ACTION_RESET):
		state.restart_run()
	elif event.is_action(ACTION_HINT):
		_on_hint_pressed()
	elif event.is_action("ui_cancel"):
		exit_requested.emit()
	else:
		return
	get_viewport().set_input_as_handled()
