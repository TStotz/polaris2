class_name MenuScreen
extends Node2D

## Level selection.
##
## Rows are grouped by [member SimLevel.feature], because the campaign is meant to
## read as one board per mechanic. A new feature level needs no change here: it
## brings its own heading with it, and an unknown feature simply appears as a new
## group in the order [method Levels.all] returns.
##
## Drawn in [method CanvasItem._draw] like the play screen rather than assembled
## from Controls — the two screens sit side by side, and one built from Buttons
## next to one built from draw calls never quite matches.

signal level_chosen(level: SimLevel)

const ROW_HEIGHT := 44.0
const GROUP_GAP := 34.0
const LEFT := 90.0
const TOP := 200.0

## Bottom of the window the list has to fit inside, and how much room the footer
## line needs under it.
const BOTTOM := 700.0
const FOOTER_GAP := 34.0

var _rows: Array = []
var _index := 0

## Row pitch actually used, after fitting the list into the window. Hit-testing
## reads this and not [constant ROW_HEIGHT], or the clickable bands would drift
## away from the drawn rows as the campaign grows.
var _row_h := ROW_HEIGHT
var _footer_y := BOTTOM


func _ready() -> void:
	set_process(true)
	_build_rows()


## One flat list of levels with the y position each is drawn at, so hit-testing a
## mouse click and moving the highlight with the arrow keys use the same numbers
## the drawing does.
func _build_rows() -> void:
	var levels := Levels.all()
	var groups := 0
	var seen := ""
	for level: SimLevel in levels:
		if level.feature != seen:
			seen = level.feature
			groups += 1

	# One level per mechanic means this list only ever gets longer, so the pitch is
	# fitted to the window rather than fixed. Without this the campaign silently
	# grows into the footer — which it did, at seven levels.
	var natural := groups * (GROUP_GAP + ROW_HEIGHT * 0.7) + levels.size() * ROW_HEIGHT
	var room := BOTTOM - FOOTER_GAP - TOP
	var scale := 1.0 if natural <= room else room / natural
	_row_h = ROW_HEIGHT * scale

	_rows.clear()
	var y := TOP
	var feature := ""
	for level: SimLevel in levels:
		if level.feature != feature:
			feature = level.feature
			y += GROUP_GAP * scale
			_rows.append({"level": null, "feature": feature, "y": y})
			y += _row_h * 0.7
		if _rows.is_empty() or _rows[_index]["level"] == null:
			# Row 0 is always a heading, so a fresh menu would open with nothing
			# selected and Enter would do nothing at all.
			_index = _rows.size()
		_rows.append({"level": level, "feature": feature, "y": y})
		y += _row_h
	_footer_y = maxf(y + FOOTER_GAP, BOTTOM)


func _process(_delta: float) -> void:
	queue_redraw()


# --- Input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hovered := _row_at(make_input_local(event).position.y)
		if hovered >= 0 and hovered != _index:
			_index = hovered
		return

	if event is InputEventMouseButton and event.pressed:
		var click := event as InputEventMouseButton
		if click.button_index != MOUSE_BUTTON_LEFT:
			return
		var hit := _row_at(make_input_local(click).position.y)
		if hit >= 0:
			_index = hit
			_choose()
		return

	if not (event is InputEventKey and event.pressed and not event.is_echo()):
		return
	match (event as InputEventKey).keycode:
		KEY_DOWN, KEY_S:
			_move(1)
		KEY_UP, KEY_W:
			_move(-1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_choose()
		KEY_ESCAPE:
			get_tree().quit()


## Steps to the next selectable row, skipping the group headings.
func _move(direction: int) -> void:
	var i := _index
	for _guard in _rows.size():
		i = wrapi(i + direction, 0, _rows.size())
		if _rows[i]["level"] != null:
			_index = i
			return


func _choose() -> void:
	if _index < 0 or _index >= _rows.size():
		return
	var level: SimLevel = _rows[_index]["level"]
	if level != null:
		level_chosen.emit(level)


## The row whose band contains [param y], or -1. Headings return -1 so a click on
## one selects nothing rather than the level that happens to follow it.
func _row_at(y: float) -> int:
	for i in _rows.size():
		if _rows[i]["level"] == null:
			continue
		var top: float = _rows[i]["y"] - _row_h * 0.75
		if y >= top and y < top + _row_h:
			return i
	return -1


# --- Drawing ----------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(-4000, -4000, 8000, 8000), PolarisTheme.BG, true)

	_label("POLARIS", Vector2(LEFT, 96), PolarisTheme.INK, 52)
	_label(
		"Setze Magnete. Halte sie im richtigen Moment.",
		Vector2(LEFT, 132), PolarisTheme.INK_DIM, 15
	)

	for i in _rows.size():
		var row: Dictionary = _rows[i]
		var y: float = row["y"]
		if row["level"] == null:
			_label(String(row["feature"]).to_upper(), Vector2(LEFT, y), PolarisTheme.ACCENT, 12)
			draw_line(
				Vector2(LEFT, y + 9), Vector2(LEFT + 620, y + 9),
				Color(PolarisTheme.ACCENT, 0.2), 1.0
			)
			continue

		var level: SimLevel = row["level"]
		var selected := i == _index
		if selected:
			draw_rect(
				Rect2(LEFT - 20, y - _row_h * 0.75, 660, _row_h - 6),
				Color(PolarisTheme.ACCENT, 0.10), true
			)
			draw_rect(Rect2(LEFT - 20, y - _row_h * 0.75, 3, _row_h - 6), PolarisTheme.ACCENT, true)

		var ink: Color = PolarisTheme.INK if selected else PolarisTheme.INK_DIM
		_label("%d" % level.id, Vector2(LEFT, y), Color(ink, 0.55), 15)
		_label(level.title, Vector2(LEFT + 34, y), ink, 19)
		_label(level.lesson, Vector2(LEFT + 190, y), Color(ink, 0.7), 13)

	_label(
		"↑↓ wählen   Enter starten   Esc beenden",
		Vector2(LEFT, _footer_y), PolarisTheme.INK_DIM, 13
	)


func _label(text: String, at: Vector2, color: Color, size: int) -> void:
	draw_string(PolarisTheme.font(), at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
