class_name BuildScreen
extends Node2D

## The build mode: draw a board with the mouse, test it, print the GDScript.
##
## **It lives beside the campaign, never inside it.** The draft is a [SimLevel] in
## memory and nothing here writes to `levels.gd`; [LevelSource] turns the draft
## into source text that a person pastes. That is the same shape the par finder
## already has, and it keeps the project's rule intact — levels are code, and code
## gets read before it ships.
##
## It reuses the play screen's two hard-won pieces rather than reinventing them:
## [BoardArt] draws the board, and the view transform plus [method _to_board] put
## a mouse click back onto the board. What is new here is only the editing —
## handles, snapping, undo — and the panel.
##
## Drawn in [method CanvasItem._draw] like the other two screens. A screen built
## from Controls next to two built from draw calls never quite matches.

signal exit_requested

## Hand the draft to the play screen. The run that comes back, if it was won, is
## this level's proof — see [method absorb_win].
signal test_requested(draft: SimLevel)

## What a shape *is*. The order matters in one place only: [method _hit] prefers
## the smallest thing under the cursor, so a slow-motion band lying on a gate can
## still be picked apart.
enum Kind {
	SOLID, HAZARD, CHECKPOINT, SLOWMO, ZONE, MOVER, FURNITURE, SPRING, POLYGON, TARGET, START
}

## The board window, identical to [constant PlayScreen.VIEW] so the two screens
## frame a level the same way and nothing jumps when you press test.
const VIEW := Rect2(0, 0, 900, 660)

## Geometry lands on whole tens unless Alt is held. Every board in the campaign is
## written in round numbers — 343 of its 386 coordinates are multiples of ten — and
## a draft full of 1183.7 would read as output rather than as something someone
## decided.
##
## **It is the board that is on the grid, not the gesture.** The step used to be
## applied only where the mouse was read, which left every other way of moving a
## shape to slide off the lattice on its own: a quarter turn shifted a wall by half
## the difference of its sides, and the start and the built-in fields snapped the
## corner of the box drawn *around* them, so the point itself could only ever land
## on ...6 and ...8. Both are now fixed where the number is made rather than where
## the mouse is.
const SNAP := 10.0

## Corner grab area, in *screen* pixels — so it stays grabbable when the view is
## pulled back to show a 3200px board at a third of its size.
const HANDLE := 10.0

## Smaller than this and a drag counts as a misclick rather than a new shape.
const MIN_SIZE := 20.0

## Half the box that stands in for a *point* — the start, and a built-in field.
##
## Exactly one grid step, and that is the whole reason for the number. A drag snaps
## the box’s corner; the thing being placed is its middle. With a half-size that is
## not a step, the middle lands a half-size off the grid and stays there — the start
## used to be unable to sit anywhere but ...6, and a field anywhere but ...8, no
## matter how carefully it was dropped.
const HALF_POINT := SNAP

const UNDO_DEPTH := 64
const REPORT := "res://tools/entwurf.gd.txt"

var level: SimLevel

## The tool that a drag on empty board creates. Never [constant Kind.TARGET] or
## [constant Kind.START]: those two always exist, so they are selected by clicking
## them like anything else rather than placed.
var _tool := Kind.SOLID

## The primary selection: the shape whose numbers the panel edits, whose corners
## carry the resize handles, and that everything else lines up *with*.
var _sel_kind := -1
var _sel_index := -1

## The other selected shapes, as `[kind, index]` pairs. Shift-click adds one.
##
## The primary is whatever was clicked **last**, and that is what "align" aligns
## to. Every editor works that way, and it is the difference between an operation
## you can aim ("put these two at that one's height") and one you cannot ("put them
## all at the average of wherever they happen to be").
##
## Indices, not references, because that is what the shape lists are addressed by —
## so anything that reorders or removes has to clear this. Deleting and undo both
## do.
var _also: Array = []

## 0 none, 1 drawing a new shape, 2 moving one, 3 resizing one, 4 panning,
## 5 resizing the arena, 6 dragging one corner of a polygon.
var _drag := 0
var _drag_from := Vector2.ZERO
var _drag_rect := Rect2()
var _grab := Vector2.ZERO
var _anchor := Vector2.ZERO
var _pan_from := Vector2.ZERO

## The corners of the polygon being drawn, in board coordinates; empty when none is.
##
## **Clicks, not a drag.** Every other tool is one gesture — press, pull, release —
## because a box is two numbers. An outline is as many corners as it has, and a
## drag can only give you two of them. So the polygon tool is the one place where a
## click on empty board does not select-or-draw but *adds a corner*, and the
## drawing stays open until it is closed: on the first corner, or with Enter.
var _poly := PackedVector2Array()

## Where the pointer is, so the edge still being drawn can follow it.
var _cursor := Vector2.ZERO

## Which corner of the selected polygon a drag of kind 6 is moving.
var _vertex := -1

## Whether that drag currently has the outline crossing itself. Drawn red while it
## does, so the refusal is visible *before* letting go rather than only after.
var _bad_shape := false

const POLYGON_HINT := "Polygon: Ecke ziehen formt um, Kantenmitte ziehen fügt eine Ecke ein, Rechtsklick auf eine Ecke löscht sie."

## A move or resize takes its undo snapshot on the first *motion*, not on the
## press. Otherwise every click that merely selects something fills the history
## with states identical to the one before them, and undo stops meaning anything.
var _pending_undo := false

## Where each selected shape stood when a move began, in the order
## [method _selected] returns them. A group has to move by one delta; following the
## cursor per shape would stack them all on the same spot.
var _drag_origin: Array[Vector2] = []

var _undo: Array = []
var _redo: Array = []

## Index into [method _fields] of the number the arrow keys currently change.
var _field := 0

var _hint := ""

## View: a zoom factor over "fit the whole arena", and the board point held at the
## centre of the window. Deliberately not eased — the play screen glides because a
## camera should, an editor should go exactly where it is put.
var _zoom := 1.0
var _centre := Vector2.ZERO
var _view_offset := Vector2.ZERO
var _view_scale := 1.0


func _ready() -> void:
	set_process(true)
	if level == null:
		load_draft(LevelSource.blank())
		return
	# Handed a draft from outside — which is how coming back from a test run works.
	# Without this the view keeps its defaults and centres on the board's top-left
	# corner instead of the board.
	_frame_board()


## Starts editing [param draft]. Taken as it is, not copied: the caller owns the
## draft across a test run, which is how it survives the round trip to the play
## screen.
func load_draft(draft: SimLevel) -> void:
	level = draft
	_clear_selection()
	_undo.clear()
	_redo.clear()
	_frame_board()
	_poly = PackedVector2Array()
	_hint = "Entwurf geladen. 1–9 wählt ein Werkzeug, Leertaste testet."
	queue_redraw()


## Takes a won test run as this level's proven replay.
##
## The expensive half of a level pipeline is proving the board can be won. For a
## board you built and then beat, that proof already exists — it is the run you
## just made, one placement list plus one bitmask per tick. No search is involved
## and none is needed.
func absorb_win(placed: Array, recording: Array) -> void:
	_push_undo()
	level.par_placements = []
	for magnet: SimLevel.MagnetSpec in placed:
		level.par_placements.append(magnet.duplicate_spec())
	level.par_holds = LevelSource.holds_from(recording)
	_hint = "Gewonnen — der Lauf ist jetzt das Par (%d Magnete, %d Halteeinträge)." % [
		level.par_placements.size(), level.par_holds.size()
	]
	queue_redraw()


# --- The view ---------------------------------------------------------------

## Puts the whole arena in the window.
func _frame_board() -> void:
	_zoom = 1.0
	_centre = level.arena.get_center()
	_apply_view()


func _fit_scale() -> float:
	return minf(VIEW.size.x / level.arena.size.x, VIEW.size.y / level.arena.size.y)


func _apply_view() -> void:
	_view_scale = _fit_scale() * _zoom
	var half := VIEW.size * 0.5 / _view_scale
	# Held inside the arena, so the board never drifts off and leaves you panning
	# through empty space looking for it.
	_centre.x = clampf(_centre.x, level.arena.position.x - half.x, level.arena.end.x + half.x)
	_centre.y = clampf(_centre.y, level.arena.position.y - half.y, level.arena.end.y + half.y)
	_view_offset = VIEW.get_center() - _centre * _view_scale


## Zooms while keeping the board point under [param at_screen] under it. Zooming
## toward the window's middle instead makes precise work impossible: the thing you
## are looking at slides away exactly when you magnify it.
func _zoom_by(factor: float, at_screen: Vector2) -> void:
	var before := _to_board(at_screen)
	_zoom = clampf(_zoom * factor, 1.0, 8.0)
	_apply_view()
	_centre += before - _to_board(at_screen)
	_apply_view()


func _to_board(at: Vector2) -> Vector2:
	return (at - _view_offset) / _view_scale


func _snap(at: Vector2) -> Vector2:
	return LevelSource.on_lattice(at, 0.0 if Input.is_key_pressed(KEY_ALT) else SNAP)


# --- Shapes, one interface over six different lists -------------------------

func _count(kind: int) -> int:
	match kind:
		Kind.SOLID: return level.solids.size()
		Kind.HAZARD: return level.hazards.size()
		Kind.SPRING: return level.springs.size()
		Kind.CHECKPOINT: return level.checkpoints.size()
		Kind.SLOWMO: return level.slowmo_points.size()
		Kind.ZONE: return level.zones.size()
		Kind.MOVER: return level.movers.size()
		Kind.FURNITURE: return level.fixed_magnets.size()
		Kind.POLYGON: return level.polygons.size()
	return 1  # the target and the start always exist, exactly once


## Whether this kind is a position rather than an area. Those get no resize
## handles, and a drag on one moves it.
func _is_point(kind: int) -> bool:
	return kind == Kind.FURNITURE or kind == Kind.START


func _rect_of(kind: int, i: int) -> Rect2:
	match kind:
		Kind.SOLID: return level.solids[i]
		Kind.HAZARD: return level.hazards[i]
		Kind.SPRING: return (level.springs[i] as SimLevel.BounceSpec).rect
		Kind.CHECKPOINT: return (level.checkpoints[i] as SimLevel.Checkpoint).rect
		Kind.SLOWMO: return level.slowmo_points[i]
		Kind.ZONE: return (level.zones[i] as SimLevel.GravitySpec).rect
		Kind.MOVER: return (level.movers[i] as SimLevel.MoverSpec).rect
		Kind.FURNITURE:
			var m: SimLevel.MagnetSpec = level.fixed_magnets[i]
			return Rect2(m.x - HALF_POINT, m.y - HALF_POINT, HALF_POINT * 2.0, HALF_POINT * 2.0)
		Kind.TARGET: return level.target
		# A polygon answers with its bounding box, and that is enough for everything
		# built on rectangles here: a move shifts the box, an alignment lines boxes
		# up, the smallest-first hit test compares their areas.
		Kind.POLYGON: return SimLevel.polygon_bounds(level.polygons[i])
	return Rect2(
		level.start - Vector2(HALF_POINT, HALF_POINT), Vector2(HALF_POINT * 2.0, HALF_POINT * 2.0)
	)


func _set_rect(kind: int, i: int, r: Rect2) -> void:
	match kind:
		Kind.SOLID: level.solids[i] = r
		Kind.HAZARD: level.hazards[i] = r
		Kind.SPRING: (level.springs[i] as SimLevel.BounceSpec).rect = r
		Kind.CHECKPOINT: (level.checkpoints[i] as SimLevel.Checkpoint).rect = r
		Kind.SLOWMO: level.slowmo_points[i] = r
		Kind.ZONE: (level.zones[i] as SimLevel.GravitySpec).rect = r
		Kind.MOVER: (level.movers[i] as SimLevel.MoverSpec).rect = r
		Kind.FURNITURE:
			var m: SimLevel.MagnetSpec = level.fixed_magnets[i]
			m.x = r.get_center().x
			m.y = r.get_center().y
		Kind.TARGET: level.target = r
		Kind.START: level.start = r.get_center()
		Kind.POLYGON:
			# Only the position is taken: a polygon is reshaped by its corners, never by
			# stretching its box — a stretch would put every corner off the grid.
			var outline: PackedVector2Array = level.polygons[i]
			level.polygons[i] = LevelSource.translated(
				outline, r.position - SimLevel.polygon_bounds(outline).position
			)


func _add(kind: int, r: Rect2) -> void:
	match kind:
		Kind.SOLID: level.solids.append(r)
		Kind.HAZARD: level.hazards.append(r)
		Kind.SPRING: level.springs.append(SimLevel.BounceSpec.new(r))
		Kind.CHECKPOINT: level.checkpoints.append(SimLevel.Checkpoint.new(r, 1))
		Kind.SLOWMO: level.slowmo_points.append(r)
		Kind.ZONE: level.zones.append(SimLevel.GravitySpec.new(r, 50))
		Kind.MOVER:
			var path := Vector2(0.0, 100.0)
			level.movers.append(
				SimLevel.MoverSpec.new(r, path, SimWorld.sweep_ticks(path))
			)
		Kind.FURNITURE:
			# The middle of a freshly drawn box is only on the grid if the box is two
			# steps wide, and a drag can make it any number of steps.
			var at := _snap(r.get_center())
			level.fixed_magnets.append(
				SimLevel.MagnetSpec.new(at.x, at.y, true, true, Vector2.ZERO, 1, true)
			)


func _remove(kind: int, i: int) -> void:
	match kind:
		Kind.SOLID: level.solids.remove_at(i)
		Kind.HAZARD: level.hazards.remove_at(i)
		Kind.SPRING: level.springs.remove_at(i)
		Kind.CHECKPOINT: level.checkpoints.remove_at(i)
		Kind.SLOWMO: level.slowmo_points.remove_at(i)
		Kind.ZONE: level.zones.remove_at(i)
		Kind.MOVER: level.movers.remove_at(i)
		Kind.FURNITURE: level.fixed_magnets.remove_at(i)
		Kind.POLYGON: level.polygons.remove_at(i)


func _clear_selection() -> void:
	_sel_kind = -1
	_sel_index = -1
	_also.clear()


## Everything selected, the primary last.
func _selected() -> Array:
	var out: Array = _also.duplicate()
	if _sel_kind >= 0:
		out.append([_sel_kind, _sel_index])
	return out


## Adds [param kind]/[param index] to the selection and makes it the primary.
##
## Shift-clicking the primary again drops it and promotes the previous one, so the
## gesture is its own undo.
func _extend_selection(kind: int, index: int) -> void:
	if kind == _sel_kind and index == _sel_index:
		if _also.is_empty():
			_clear_selection()
		else:
			var back: Array = _also.pop_back()
			_sel_kind = int(back[0])
			_sel_index = int(back[1])
		return
	for i in range(_also.size() - 1, -1, -1):
		var pair: Array = _also[i]
		if int(pair[0]) == kind and int(pair[1]) == index:
			_also.remove_at(i)
	if _sel_kind >= 0:
		_also.append([_sel_kind, _sel_index])
	_sel_kind = kind
	_sel_index = index


## Turns every selected shape a quarter turn anticlockwise about its own middle.
##
## Each about *its own* middle, not about the selection's: turning a row of walls
## should stand each of them up where it is, not sweep them around a common point.
## A shape that is turned about a shared centre has moved as well, and moving is
## what dragging is for.
##
## Always the same direction. Four presses come back round, so turning the other
## way is three presses, and a modifier that silently reverses a key costs more in
## surprise than it saves in presses.
##
## The start is skipped — it is a position, and a position has no orientation.
func _rotate() -> void:
	var picks := _selected()
	if picks.is_empty():
		_hint = "Nichts ausgewählt."
		return
	_push_undo()
	var turned := 0
	for pair: Array in picks:
		var kind := int(pair[0])
		var index := int(pair[1])
		if kind == Kind.START:
			continue
		turned += 1
		if kind == Kind.POLYGON:
			level.polygons[index] = LevelSource.rotated_polygon(level.polygons[index], SNAP)
			continue
		if kind == Kind.FURNITURE:
			# A point: only its path has a direction to turn.
			var magnet: SimLevel.MagnetSpec = level.fixed_magnets[index]
			magnet.travel = LevelSource.turned(magnet.travel)
			continue
		_set_rect(kind, index, LevelSource.rotated(_rect_of(kind, index), SNAP))
		if kind == Kind.MOVER:
			var mover: SimLevel.MoverSpec = level.movers[index]
			mover.travel = LevelSource.turned(mover.travel)
		elif kind == Kind.SPRING:
			# A plate that kept firing upward after being laid on its side would be a
			# plate that lies about its own picture.
			var spring: SimLevel.BounceSpec = level.springs[index]
			spring.push = LevelSource.turned(spring.push)
	_hint = "%d um 90° gegen den Uhrzeiger gedreht." % turned


## Lines every selected shape up with the primary.
##
## [param vertical] means one column — same x. Otherwise one height — same y, which
## is the one a board wants most, because a platform's top edge is where the ball
## lands. [param by_centre] lines up middles instead of edges.
func _align(vertical: bool, by_centre: bool) -> void:
	var picks := _selected()
	if picks.size() < 2:
		_hint = "Ausrichten braucht zwei: mit Shift eine zweite Form dazuwählen."
		return
	_push_undo()
	var anchor := _rect_of(_sel_kind, _sel_index)
	for pair: Array in picks:
		var kind := int(pair[0])
		var index := int(pair[1])
		if kind == _sel_kind and index == _sel_index:
			continue
		_set_rect(kind, index, LevelSource.align_to(
			_rect_of(kind, index), anchor, vertical, by_centre
		))
	_hint = "%d Formen %s ausgerichtet%s." % [
		picks.size(),
		"senkrecht" if vertical else "waagerecht",
		" (Mitte)" if by_centre else "",
	]


## What is under [param at], smallest first.
##
## Smallest rather than topmost, because the overlaps here are deliberate: a board
## almost always puts a slow-motion band on a gate, and with a topmost rule one of
## the two would be unreachable. The smaller shape is the one you were aiming at.
func _hit(at: Vector2) -> Array:
	var best := -1
	var best_i := -1
	var best_area := INF
	for kind: int in [
		Kind.FURNITURE, Kind.START, Kind.MOVER, Kind.SLOWMO,
		Kind.CHECKPOINT, Kind.ZONE, Kind.TARGET, Kind.SPRING, Kind.HAZARD, Kind.SOLID,
		Kind.POLYGON,
	]:
		for i in _count(kind):
			var r := _rect_of(kind, i)
			if not r.has_point(at):
				continue
			# The outline, not its box: a click in the empty bowl of a cup-shaped wall
			# is a click on empty board, where the next shape gets drawn.
			if kind == Kind.POLYGON and not Geometry2D.is_point_in_polygon(at, level.polygons[i]):
				continue
			var area := absf(r.size.x * r.size.y)
			if area < best_area:
				best_area = area
				best = kind
				best_i = i
	return [best, best_i]


## Whether [param at_screen] grabs the arena's bottom-right corner.
##
## The arena is resized by a handle rather than by being selectable, and that is
## not a shortcut. It is the largest rectangle on the board, so hit-testing its
## body would mean every drag on empty space grabbed the arena instead of drawing
## a new shape — and drawing on empty space is the thing you do most.
##
## Only the bottom-right corner, because every board in the campaign starts at
## (0,0). Keeping the origin pinned means the size is one number pair instead of
## two, and nothing already placed shifts under you when the board grows.
func _arena_handle(at_screen: Vector2) -> bool:
	var corner: Vector2 = level.arena.end * _view_scale + _view_offset
	return corner.distance_to(at_screen) <= HANDLE * 1.6


## Which corner of the selection [param at_screen] grabs, or -1.
func _handle_at(at_screen: Vector2) -> int:
	if _sel_kind < 0 or _is_point(_sel_kind) or _sel_kind == Kind.POLYGON:
		return -1
	var r := _rect_of(_sel_kind, _sel_index)
	var corners := [
		r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)
	]
	for c in corners.size():
		var screen: Vector2 = (corners[c] as Vector2) * _view_scale + _view_offset
		if screen.distance_to(at_screen) <= HANDLE:
			return c
	return -1


## Which corner of the selected polygon [param at_screen] grabs, or -1.
func _vertex_at(at_screen: Vector2) -> int:
	if _sel_kind != Kind.POLYGON or _sel_index >= _count(Kind.POLYGON):
		return -1
	var points: PackedVector2Array = level.polygons[_sel_index]
	for i in points.size():
		if (points[i] * _view_scale + _view_offset).distance_to(at_screen) <= HANDLE:
			return i
	return -1


## Which edge of the selected polygon has its middle under [param at_screen], or -1.
##
## Pulling on an edge's middle is how a corner gets *added*: it splits the edge
## there and the drag carries the new corner. The pattern every vector editor has,
## and it needs no mode — a corner handle moves, a middle handle makes.
func _midpoint_at(at_screen: Vector2) -> int:
	if _sel_kind != Kind.POLYGON or _sel_index >= _count(Kind.POLYGON):
		return -1
	var points: PackedVector2Array = level.polygons[_sel_index]
	for i in points.size():
		var middle := (points[i] + points[(i + 1) % points.size()]) * 0.5
		if (middle * _view_scale + _view_offset).distance_to(at_screen) <= HANDLE * 0.8:
			return i
	return -1


# --- Polygons ---------------------------------------------------------------

## A left click while an outline is being drawn: close it, or add a corner.
func _poly_click(at: Vector2, at_screen: Vector2) -> void:
	var first: Vector2 = _poly[0] * _view_scale + _view_offset
	if _poly.size() >= 3 and first.distance_to(at_screen) <= HANDLE * 1.4:
		_close_polygon()
		return
	var corner := _snap(at)
	# A double click, or a click the grid folded onto the corner before it. Adding
	# it would make two corners coincide, which the outline would refuse anyway.
	if corner == _poly[_poly.size() - 1]:
		return
	_poly.append(corner)
	_hint = "%d Ecken. Weiterklicken — die erste Ecke oder Enter schließt." % _poly.size()


## Turns the outline being drawn into a wall, if it can be one.
##
## A bad outline is refused *here*, not discovered in a run. The drawing stays open
## so the fix is one Backspace away, and the hint says what is wrong.
func _close_polygon() -> void:
	var problem := LevelSource.polygon_problem(_poly)
	if not problem.is_empty():
		_hint = problem + " Rücktaste nimmt die letzte Ecke zurück."
		return
	_push_undo()
	level.polygons.append(_poly)
	_hint = "Polygon mit %d Ecken angelegt. Ecken ziehen formt es um." % _poly.size()
	_poly = PackedVector2Array()
	_also.clear()
	_sel_kind = Kind.POLYGON
	_sel_index = level.polygons.size() - 1
	_field = 0


## Takes back the last corner of the outline being drawn; the last of all cancels it.
func _poly_back() -> void:
	_poly.remove_at(_poly.size() - 1)
	_hint = (
		"Polygon abgebrochen." if _poly.is_empty()
		else "%d Ecken. Weiterklicken — die erste Ecke oder Enter schließt." % _poly.size()
	)


## Removes one corner of the selected polygon, unless that would break it.
##
## Three is the floor, and a removal can also make two far edges cross, so the
## result is checked and refused rather than taken back afterwards.
func _remove_corner(index: int) -> void:
	var points: PackedVector2Array = (level.polygons[_sel_index] as PackedVector2Array).duplicate()
	if points.size() <= 3:
		_hint = "Ein Polygon braucht mindestens drei Ecken."
		return
	points.remove_at(index)
	var problem := LevelSource.polygon_problem(points)
	if not problem.is_empty():
		_hint = problem + " Die Ecke bleibt."
		return
	_push_undo()
	level.polygons[_sel_index] = points
	_hint = "Ecke gelöscht."


# --- Undo -------------------------------------------------------------------

func _push_undo() -> void:
	_undo.append(LevelSource.copy(level))
	if _undo.size() > UNDO_DEPTH:
		_undo.remove_at(0)
	_redo.clear()


func _step_history(from: Array, to: Array) -> void:
	if from.is_empty():
		_hint = "Nichts mehr da."
		return
	to.append(LevelSource.copy(level))
	level = from.pop_back() as SimLevel
	_clear_selection()
	_poly = PackedVector2Array()
	# The old message described a state that has just been taken back — "Arena
	# 3600×1800" over a board that is 3200 wide again.
	_hint = "Rückgängig."
	_apply_view()
	queue_redraw()


# --- Input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if level == null:
		return
	if event is InputEventMouseButton:
		_mouse_button(event as InputEventMouseButton)
		return
	if event is InputEventMouseMotion:
		var motion := make_input_local(event) as InputEventMouseMotion
		if not _poly.is_empty():
			_cursor = _to_board(motion.position)
			queue_redraw()
		if _drag != 0:
			_mouse_drag(motion)
		return
	if event is InputEventKey and event.pressed and not event.is_echo():
		_key(event as InputEventKey)


func _mouse_button(raw: InputEventMouseButton) -> void:
	var click := make_input_local(raw) as InputEventMouseButton
	var at := _to_board(click.position)

	if click.button_index == MOUSE_BUTTON_WHEEL_UP and click.pressed:
		_zoom_by(1.15, click.position)
		queue_redraw()
		return
	if click.button_index == MOUSE_BUTTON_WHEEL_DOWN and click.pressed:
		_zoom_by(1.0 / 1.15, click.position)
		queue_redraw()
		return

	if click.button_index == MOUSE_BUTTON_MIDDLE:
		_drag = 4 if click.pressed else 0
		_pan_from = click.position
		return

	if click.button_index == MOUSE_BUTTON_RIGHT and click.pressed:
		if not _poly.is_empty():
			_poly_back()
			queue_redraw()
			return
		var corner_hit := _vertex_at(click.position)
		if corner_hit >= 0:
			_remove_corner(corner_hit)
			queue_redraw()
			return
		var found := _hit(at)
		if found[0] >= 0 and not _fixed_shape(int(found[0])):
			_push_undo()
			_remove(int(found[0]), int(found[1]))
			_sel_kind = -1
			_sel_index = -1
			_hint = "Gelöscht."
			queue_redraw()
		return

	if click.button_index != MOUSE_BUTTON_LEFT:
		return

	if not click.pressed:
		_finish_drag()
		return

	# The arena's own corner comes first: it sits out beyond everything else, so
	# nothing else can want that pixel.
	if _arena_handle(click.position):
		_drag = 5
		_pending_undo = true
		return

	# An outline being drawn takes every click, even one that lands on an existing
	# shape: halfway through a polygon, a click means "corner here", and selecting
	# the wall underneath would throw the drawing away.
	if not _poly.is_empty():
		_poly_click(at, click.position)
		queue_redraw()
		return

	var grip := _vertex_at(click.position)
	if grip >= 0:
		_vertex = grip
		_drag = 6
		_pending_undo = true
		return
	var split := _midpoint_at(click.position)
	if split >= 0:
		# The snapshot is taken now rather than on the first motion: inserting the
		# corner is already a change, whether or not it is then dragged anywhere.
		_push_undo()
		var points: PackedVector2Array = level.polygons[_sel_index]
		var middle := _snap((points[split] + points[(split + 1) % points.size()]) * 0.5)
		points.insert(split + 1, middle)
		level.polygons[_sel_index] = points
		_hint = "Ecke eingefügt — ziehen formt um, Rechtsklick löscht sie wieder."
		_vertex = split + 1
		_drag = 6
		_pending_undo = false
		queue_redraw()
		return

	# A corner of what is already selected wins over the rest: it is a small target
	# deliberately placed on top of the shape's own edge.
	var corner := _handle_at(click.position)
	if corner >= 0:
		var r := _rect_of(_sel_kind, _sel_index)
		var opposite: Array[Vector2] = [
			r.end, Vector2(r.position.x, r.end.y), r.position, Vector2(r.end.x, r.position.y)
		]
		_anchor = opposite[corner]
		_drag = 3
		_pending_undo = true
		return

	var found := _hit(at)
	if found[0] >= 0:
		if click.shift_pressed:
			# A selection gesture, not a move. Shift-dragging would let a sloppy click
			# nudge geometry at the exact moment you are picking things to line up.
			_extend_selection(int(found[0]), int(found[1]))
			_field = 0
			queue_redraw()
			return
		if not _is_selected(int(found[0]), int(found[1])):
			_also.clear()
			_sel_kind = int(found[0])
			_sel_index = int(found[1])
			_field = 0
			if _sel_kind == Kind.POLYGON:
				_hint = POLYGON_HINT
		_drag = 2
		_pending_undo = true
		# Where every selected shape stood when the drag began, so the whole set
		# moves by one delta instead of each following the cursor to the same spot.
		_drag_origin = []
		for pair: Array in _selected():
			_drag_origin.append(_rect_of(int(pair[0]), int(pair[1])).position)
		_grab = at - _rect_of(_sel_kind, _sel_index).position
		queue_redraw()
		return

	# Empty board: draw a new shape of the current tool — or, for the polygon tool,
	# put down its first corner.
	if _tool == Kind.POLYGON:
		_poly = PackedVector2Array([_snap(at)])
		_cursor = at
		_hint = "1 Ecke. Weiterklicken — die erste Ecke oder Enter schließt."
		queue_redraw()
		return
	_drag = 1
	_drag_from = _snap(at)
	_drag_rect = Rect2(_drag_from, Vector2.ZERO)
	queue_redraw()


func _mouse_drag(motion: InputEventMouseMotion) -> void:
	var at := _to_board(motion.position)
	if _pending_undo:
		# The level has not been touched yet this event, so this snapshot is the
		# state from before the drag — which is the one undo has to return to.
		_push_undo()
		_pending_undo = false
	match _drag:
		1:
			_drag_rect = Rect2(_drag_from, _snap(at) - _drag_from).abs()
		2:
			var moved := _snap(at - _grab)
			var delta := moved - _drag_origin[_drag_origin.size() - 1]
			var picks := _selected()
			for i in picks.size():
				var pair: Array = picks[i]
				var kind := int(pair[0])
				var index := int(pair[1])
				var r := _rect_of(kind, index)
				var start: Vector2 = _drag_origin[i]
				_set_rect(kind, index, Rect2(
					moved if kind == _sel_kind and index == _sel_index else start + delta,
					r.size
				))
		3:
			var moved := _snap(at)
			var r := Rect2(_anchor, moved - _anchor).abs()
			r.size.x = maxf(r.size.x, MIN_SIZE)
			r.size.y = maxf(r.size.y, MIN_SIZE)
			_set_rect(_sel_kind, _sel_index, r)
		4:
			_centre -= (motion.position - _pan_from) / _view_scale
			_pan_from = motion.position
			_apply_view()
		6:
			var outline: PackedVector2Array = level.polygons[_sel_index]
			outline[_vertex] = _snap(at)
			level.polygons[_sel_index] = outline
			var problem := LevelSource.polygon_problem(outline)
			_bad_shape = not problem.is_empty()
			_hint = (problem + " Loslassen setzt zurück.") if _bad_shape else POLYGON_HINT
		5:
			var size := _snap(at) - level.arena.position
			level.arena = Rect2(
				level.arena.position,
				Vector2(maxf(400.0, size.x), maxf(400.0, size.y))
			)
			_hint = "Arena %d×%d" % [int(level.arena.size.x), int(level.arena.size.y)]
			_apply_view()
	queue_redraw()


func _finish_drag() -> void:
	if _drag == 6 and not _pending_undo:
		# Checked on release, not per motion: on the way to a valid shape a corner
		# often passes through an invalid one, and refusing each step would make the
		# corner stick. What is refused is where it was let go.
		var problem := LevelSource.polygon_problem(level.polygons[_sel_index])
		if not problem.is_empty() and not _undo.is_empty():
			level = _undo.pop_back() as SimLevel
			_hint = problem + " Zurückgesetzt."
		_vertex = -1
	_bad_shape = false
	if _drag == 5:
		# The view is fitted to the arena, so a board that just grew is half off
		# screen until the frame catches up.
		_frame_board()
	if _drag == 1:
		if _drag_rect.size.x >= MIN_SIZE and _drag_rect.size.y >= MIN_SIZE:
			_push_undo()
			_add(_tool, _drag_rect)
			_sel_kind = _tool
			_sel_index = _count(_tool) - 1
			_field = 0
			_hint = "%s angelegt." % _tool_name(_tool)
		_drag_rect = Rect2()
	_drag = 0
	_pending_undo = false
	queue_redraw()


func _key(key: InputEventKey) -> void:
	if key.ctrl_pressed:
		match key.keycode:
			KEY_Z: _step_history(_undo, _redo)
			KEY_Y: _step_history(_redo, _undo)
		return

	match key.keycode:
		KEY_1: _pick_tool(Kind.SOLID)
		KEY_2: _pick_tool(Kind.HAZARD)
		KEY_3: _pick_tool(Kind.CHECKPOINT)
		KEY_4: _pick_tool(Kind.SLOWMO)
		KEY_5: _pick_tool(Kind.ZONE)
		KEY_6: _pick_tool(Kind.MOVER)
		KEY_7: _pick_tool(Kind.FURNITURE)
		KEY_8: _pick_tool(Kind.SPRING)
		KEY_9: _pick_tool(Kind.POLYGON)
		KEY_ENTER, KEY_KP_ENTER:
			if not _poly.is_empty():
				_close_polygon()
		KEY_BACKSPACE:
			if not _poly.is_empty():
				_poly_back()
			else:
				_delete_selection()
		KEY_DELETE:
			_delete_selection()
		KEY_R:
			_rotate()
		KEY_H:
			_align(false, key.shift_pressed)
		KEY_V:
			_align(true, key.shift_pressed)
		KEY_TAB:
			var count := _fields().size()
			if count > 0:
				_field = (_field + (-1 if key.shift_pressed else 1) + count) % count
		KEY_LEFT: _nudge(-1, key.shift_pressed)
		KEY_RIGHT: _nudge(1, key.shift_pressed)
		KEY_F: _frame_board()
		KEY_E: _export()
		KEY_N:
			_push_undo()
			load_draft(LevelSource.blank())
		KEY_SPACE:
			_poly = PackedVector2Array()
			_hint = "Test läuft — Esc bringt dich zurück."
			test_requested.emit(level)
		KEY_ESCAPE:
			# Out of the drawing first, out of the build mode second: one Escape
			# should never throw away both.
			if not _poly.is_empty():
				_poly = PackedVector2Array()
				_hint = "Polygon abgebrochen."
			else:
				exit_requested.emit()
	queue_redraw()


## Removes everything selected that may be removed.
##
## Highest index first, per kind: [method _remove] shifts every later index of the
## same list down, so deleting front to back would take the wrong shapes with it.
func _delete_selection() -> void:
	var picks: Array = []
	for pair: Array in _selected():
		if not _fixed_shape(int(pair[0])):
			picks.append(pair)
	if picks.is_empty():
		return
	_push_undo()
	picks.sort_custom(func(a: Array, b: Array) -> bool: return int(a[1]) > int(b[1]))
	for pair: Array in picks:
		_remove(int(pair[0]), int(pair[1]))
	_clear_selection()
	_hint = "%d gelöscht." % picks.size()


func _is_selected(kind: int, index: int) -> bool:
	for pair: Array in _selected():
		if int(pair[0]) == kind and int(pair[1]) == index:
			return true
	return false


func _pick_tool(kind: int) -> void:
	_tool = kind
	_poly = PackedVector2Array()
	if kind == Kind.POLYGON:
		_hint = "Werkzeug: Polygon — Ecken nacheinander anklicken, die erste Ecke oder Enter schließt, Rücktaste nimmt eine zurück."
		return
	_hint = "Werkzeug: %s — auf leerer Fläche aufziehen." % _tool_name(kind)


## The target and the start are part of every board, so they can be moved and
## resized but never removed.
func _fixed_shape(kind: int) -> bool:
	return kind == Kind.TARGET or kind == Kind.START


# --- The numbers ------------------------------------------------------------

## Every adjustable number, as `[label, id, step]`.
##
## The level's own settings first, then whatever the selection adds. One list and
## one pair of arrow keys for both, because a second editing idiom for four extra
## fields is not worth the explanation.
func _fields() -> Array:
	var out: Array = [
		["Welt", "theme", 1.0],
		["Arena breit", "arena_w", 50.0],
		["Arena hoch", "arena_h", 50.0],
		["Budget", "budget", 1.0],
		["Ladung (s)", "charge", 0.5],
		["Magnetstärke", "strength", 200.0],
		["Fremdfeld-Stärke", "field_strength", 200.0],
		["Horizont (Ticks)", "horizon", 300.0],
		["Zeitlupe (Ticks)", "slowmo", 5.0],
	]
	match _sel_kind:
		Kind.MOVER:
			out.append(["Plattform Weg X", "mv_x", 20.0])
			out.append(["Plattform Weg Y", "mv_y", 20.0])
			out.append(["Plattform Takt", "mv_period", 5.0])
			out.append(["Plattform Phase", "mv_phase", 5.0])
		Kind.ZONE:
			out.append(["Zone Takt", "zn_period", 5.0])
			out.append(["Zone Phase", "zn_phase", 5.0])
		Kind.CHECKPOINT:
			out.append(["Tor gibt Magnete", "cp_grants", 1.0])
		Kind.SPRING:
			out.append(["Schub X", "sp_x", 100.0])
			out.append(["Schub Y", "sp_y", 100.0])
		Kind.FURNITURE:
			out.append(["Feld zieht an", "fm_pull", 1.0])
			out.append(["Feld Weg X", "fm_x", 20.0])
			out.append(["Feld Weg Y", "fm_y", 20.0])
	return out


func _nudge(direction: int, coarse: bool) -> void:
	var fields := _fields()
	if _field >= fields.size():
		_field = 0
	var field: Array = fields[_field]
	_push_undo()
	var step := float(field[2]) * (5.0 if coarse else 1.0)
	_write(String(field[1]), _read(String(field[1])) + step * float(direction))
	_apply_view()


func _read(id: String) -> float:
	match id:
		"theme": return float(PolarisTheme.world_index(level.theme))
		"arena_w": return level.arena.size.x
		"arena_h": return level.arena.size.y
		"budget": return float(level.budget)
		"charge": return level.charge_seconds
		"strength": return level.magnet_strength
		"field_strength": return level.field_strength
		"horizon": return float(level.max_ticks)
		"slowmo": return float(level.slowmo_ticks)
		"mv_x": return (level.movers[_sel_index] as SimLevel.MoverSpec).travel.x
		"mv_y": return (level.movers[_sel_index] as SimLevel.MoverSpec).travel.y
		"mv_period": return float((level.movers[_sel_index] as SimLevel.MoverSpec).period)
		"mv_phase": return float((level.movers[_sel_index] as SimLevel.MoverSpec).phase)
		"zn_period": return float((level.zones[_sel_index] as SimLevel.GravitySpec).period)
		"zn_phase": return float((level.zones[_sel_index] as SimLevel.GravitySpec).phase)
		"cp_grants": return float((level.checkpoints[_sel_index] as SimLevel.Checkpoint).grants)
		"sp_x": return (level.springs[_sel_index] as SimLevel.BounceSpec).push.x
		"sp_y": return (level.springs[_sel_index] as SimLevel.BounceSpec).push.y
		"fm_pull": return 1.0 if (level.fixed_magnets[_sel_index] as SimLevel.MagnetSpec).attract else 0.0
		"fm_x": return (level.fixed_magnets[_sel_index] as SimLevel.MagnetSpec).travel.x
		"fm_y": return (level.fixed_magnets[_sel_index] as SimLevel.MagnetSpec).travel.y
	return 0.0


## Every write goes through a named local.
##
## `thing().vector.x = value` does not do what it looks like: a [Vector2] is a
## value, so the component is set on a copy that is then thrown away. Read the
## vector out, change it, write it back.
func _write(id: String, value: float) -> void:
	match id:
		"theme":
			# Wraps, because a list of seven with dead ends at both sides is worse to
			# cycle than one that comes round.
			var count := PolarisTheme.WORLDS.size()
			var pick := (int(value) % count + count) % count
			level.theme = "" if pick == 0 else (PolarisTheme.WORLDS[pick] as PolarisTheme.World).name
		"arena_w":
			var wide := level.arena
			wide.size.x = maxf(400.0, value)
			level.arena = wide
		"arena_h":
			var high := level.arena
			high.size.y = maxf(400.0, value)
			level.arena = high
		"budget":
			level.budget = clampi(int(value), 0, SimWorld.HOLD_KEYS)
		"charge":
			level.charge_seconds = maxf(0.5, value)
		"strength":
			level.magnet_strength = maxf(0.0, value)
		"field_strength":
			level.field_strength = maxf(0.0, value)
		"horizon":
			level.max_ticks = maxi(0, int(value))
		"slowmo":
			level.slowmo_ticks = maxi(0, int(value))
		"mv_x":
			var mvx: SimLevel.MoverSpec = level.movers[_sel_index]
			_set_path(mvx, Vector2(value, mvx.travel.y))
		"mv_y":
			var mvy: SimLevel.MoverSpec = level.movers[_sel_index]
			_set_path(mvy, Vector2(mvy.travel.x, value))
		"mv_period":
			var mvp: SimLevel.MoverSpec = level.movers[_sel_index]
			mvp.period = maxi(1, int(value))
		"mv_phase":
			var mvh: SimLevel.MoverSpec = level.movers[_sel_index]
			mvh.phase = maxi(0, int(value))
		"zn_period":
			var znp: SimLevel.GravitySpec = level.zones[_sel_index]
			znp.period = maxi(1, int(value))
		"zn_phase":
			var znh: SimLevel.GravitySpec = level.zones[_sel_index]
			znh.phase = maxi(0, int(value))
		"cp_grants":
			var cp: SimLevel.Checkpoint = level.checkpoints[_sel_index]
			cp.grants = clampi(int(value), 0, SimWorld.HOLD_KEYS)
		"sp_x":
			var spx: SimLevel.BounceSpec = level.springs[_sel_index]
			spx.push = Vector2(value, spx.push.y)
		"sp_y":
			var spy: SimLevel.BounceSpec = level.springs[_sel_index]
			spy.push = Vector2(spy.push.x, value)
		"fm_pull":
			var pol: SimLevel.MagnetSpec = level.fixed_magnets[_sel_index]
			pol.attract = value >= 0.5
		"fm_x":
			var fmx: SimLevel.MagnetSpec = level.fixed_magnets[_sel_index]
			fmx.travel = Vector2(value, fmx.travel.y)
			fmx.period = maxi(1, SimWorld.sweep_ticks(fmx.travel))
		"fm_y":
			var fmy: SimLevel.MagnetSpec = level.fixed_magnets[_sel_index]
			fmy.travel = Vector2(fmy.travel.x, value)
			fmy.period = maxi(1, SimWorld.sweep_ticks(fmy.travel))


## Gives a platform a new path, and derives its period from it.
##
## The period is how many ticks one leg takes, so leaving a stale one when the path
## changes silently changes the platform's *speed*: twice as long over the same
## ticks is twice as fast. The campaign always writes
## `SimWorld.sweep_ticks(travel)` here, which is one constant speed; keeping that
## means the only thing this field decides is distance. Set the period afterwards
## if a board wants a different speed — that is then a decision, not a leftover.
func _set_path(mover: SimLevel.MoverSpec, path: Vector2) -> void:
	mover.travel = path
	mover.period = maxi(1, SimWorld.sweep_ticks(path))


# --- Export -----------------------------------------------------------------

## Writes the draft's source next to the par finder's report.
##
## `res://` is writable while the project runs from the editor, which is where this
## tool is used. From an exported build it is not, so the fallback keeps the button
## honest rather than failing silently.
func _export() -> void:
	var text := LevelSource.to_gdscript(level, "_entwurf")
	var path := REPORT
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		path = "user://entwurf.gd.txt"
		file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_hint = "Konnte nichts schreiben — weder %s noch user://." % REPORT
		return
	file.store_string(text)
	file.close()
	_hint = "Geschrieben: %s — von Hand in levels.gd übernehmen." % path


# --- Drawing ----------------------------------------------------------------

func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(-4000, -4000, 8000, 8000), PolarisTheme.BG, true)
	if level == null:
		return
	PolarisTheme.use(level.theme)
	var t := Time.get_ticks_msec() / 1000.0
	_apply_view()
	draw_set_transform(_view_offset, 0.0, Vector2(_view_scale, _view_scale))

	var seen := Rect2(_to_board(VIEW.position), VIEW.size / _view_scale)
	BoardArt.draw_background(self, level.arena, seen, t)
	BoardArt.draw_frame(self, level.arena)
	for zone: SimLevel.GravitySpec in level.zones:
		BoardArt.draw_gravity_zone(self, zone.rect, true, fmod(t * 0.5, 1.0))
	BoardArt.draw_target(self, level.target, t)
	for cp: SimLevel.Checkpoint in level.checkpoints:
		BoardArt.draw_checkpoint(self, cp.rect, false, t, _view_scale)
	# Slow-motion points have no look of their own in play — they are a trigger, and
	# the board says nothing when one fires. Here they must be visible or they
	# cannot be edited, so the build mode gives them one.
	for rect: Rect2 in level.slowmo_points:
		draw_rect(rect, Color(PolarisTheme.ACCENT, 0.07), true)
		draw_rect(rect, Color(PolarisTheme.ACCENT, 0.34), false, 1.5 / _view_scale)
	for solid: Rect2 in level.solids:
		BoardArt.draw_solid(self, solid, PolarisTheme.world().wall_edge)
	for points: PackedVector2Array in level.polygons:
		BoardArt.draw_polygon_wall(self, points, PolarisTheme.world().wall_edge)
	for hazard: Rect2 in level.hazards:
		BoardArt.draw_hazard(self, hazard, t)
	for spring: SimLevel.BounceSpec in level.springs:
		BoardArt.draw_spring(self, spring.rect, spring.push, t)
	_draw_movers()
	_draw_furniture(t)
	BoardArt.draw_ball(self, level.start, SimWorld.BALL_RADIUS, [])
	_draw_selection()
	_draw_arena_handle()

	if _drag == 1 and _drag_rect.size.length() > 0.0:
		draw_rect(_drag_rect, Color(PolarisTheme.OK, 0.18), true)
		draw_rect(_drag_rect, PolarisTheme.OK, false, 1.5 / _view_scale)
	_draw_poly_in_progress()

	# Back to screen space, then mask, exactly as the play screen does:
	# `draw_set_transform` moves geometry but clips nothing.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var far := 4000.0
	draw_rect(Rect2(VIEW.end.x, -far, far, far * 2.0), PolarisTheme.BG, true)
	draw_rect(Rect2(-far, -far, far + VIEW.position.x, far * 2.0), PolarisTheme.BG, true)
	draw_rect(Rect2(-far, -far, far * 2.0, far + VIEW.position.y), PolarisTheme.BG, true)
	draw_rect(Rect2(-far, VIEW.end.y, far * 2.0, far), PolarisTheme.BG, true)
	_draw_panel()


## The outline being drawn: its edges, the one still following the pointer, and a
## faint closing edge back to the start so the shape is visible before it is shut.
##
## The first corner is drawn larger and in the selection colour once there are
## three — it is the button that closes the outline, and a button has to look like
## one.
func _draw_poly_in_progress() -> void:
	if _poly.is_empty():
		return
	var width := 2.0 / _view_scale
	var next := _snap(_cursor)
	var trail := _poly.duplicate()
	trail.append(next)
	draw_polyline(trail, PolarisTheme.OK, width)
	if _poly.size() >= 2:
		draw_line(next, _poly[0], Color(PolarisTheme.OK, 0.3), width)
	var size := HANDLE / _view_scale
	for i in _poly.size():
		var closer := i == 0 and _poly.size() >= 3
		var grip := size * (1.5 if closer else 0.8)
		draw_rect(
			Rect2(_poly[i] - Vector2(grip, grip) * 0.5, Vector2(grip, grip)),
			PolarisTheme.ACCENT if closer else PolarisTheme.OK, true
		)


func _draw_movers() -> void:
	for mover: SimLevel.MoverSpec in level.movers:
		var swept := mover.swept_rect()
		draw_rect(swept, Color(PolarisTheme.OK, 0.05), true)
		draw_rect(swept, Color(PolarisTheme.OK, 0.18), false, 1.0 / _view_scale)
		BoardArt.draw_solid(self, mover.rect, PolarisTheme.OK)
		var far_end := mover.rect.position + mover.travel
		draw_line(
			mover.rect.get_center(), far_end + mover.rect.size * 0.5,
			Color(PolarisTheme.OK, 0.5), 1.5 / _view_scale
		)


func _draw_furniture(t: float) -> void:
	# The furniture's own strength, which since SimLevel.field_strength need not be
	# the player's. Unset falls through to the player's, then to the campaign's.
	var strength: float = level.field_strength
	if strength <= 0.0:
		strength = level.magnet_strength
	if strength <= 0.0:
		strength = SimWorld.MAGNET_STRENGTH
	var lift := SimWorld.MAGNET_RADIUS * (1.0 - SimWorld.GRAVITY / strength)
	for magnet: SimLevel.MagnetSpec in level.fixed_magnets:
		if magnet.moves():
			var ende := Vector2(magnet.x, magnet.y) + magnet.travel
			draw_line(
				Vector2(magnet.x, magnet.y), ende,
				Color(PolarisTheme.INK_DIM, 0.45), 2.0 / _view_scale
			)
		BoardArt.draw_magnet(
			self, Vector2(magnet.x, magnet.y), magnet.attract, false, false,
			t, SimWorld.MAGNET_RADIUS, lift
		)


func _draw_selection() -> void:
	if _sel_kind < 0 or _sel_index >= _count(_sel_kind):
		return
	var width := 2.0 / _view_scale
	# The others first and dimmer, so the anchor is obvious: it is the one the
	# alignment moves everything *to*, and picking the wrong one is the only way to
	# get a surprising result.
	for pair: Array in _also:
		var kind := int(pair[0])
		var index := int(pair[1])
		if index >= _count(kind):
			continue
		if kind == Kind.POLYGON:
			_draw_outline(level.polygons[index], Color(PolarisTheme.ACCENT, 0.45), width)
			continue
		draw_rect(
			_rect_of(kind, index).grow(3.0 / _view_scale),
			Color(PolarisTheme.ACCENT, 0.45), false, width
		)
	if _sel_kind == Kind.POLYGON:
		var points: PackedVector2Array = level.polygons[_sel_index]
		_draw_outline(points, PolarisTheme.PLUS if _bad_shape else PolarisTheme.ACCENT, width)
		var grip := HANDLE / _view_scale
		for i in points.size():
			draw_rect(
				Rect2(points[i] - Vector2(grip, grip) * 0.5, Vector2(grip, grip)),
				PolarisTheme.ACCENT, true
			)
			# Hollow and smaller: the middle of an edge is where a corner *can* go,
			# not one that is there.
			var middle := (points[i] + points[(i + 1) % points.size()]) * 0.5
			draw_rect(
				Rect2(middle - Vector2(grip, grip) * 0.35, Vector2(grip, grip) * 0.7),
				PolarisTheme.ACCENT, false, width * 0.75
			)
		return
	var r := _rect_of(_sel_kind, _sel_index)
	draw_rect(r.grow(3.0 / _view_scale), PolarisTheme.ACCENT, false, width)
	if _is_point(_sel_kind):
		return
	var size := HANDLE / _view_scale
	for corner: Vector2 in [
		r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)
	]:
		draw_rect(Rect2(corner - Vector2(size, size) * 0.5, Vector2(size, size)),
			PolarisTheme.ACCENT, true)


func _draw_outline(points: PackedVector2Array, tint: Color, width: float) -> void:
	var ring := points.duplicate()
	ring.append(points[0])
	draw_polyline(ring, tint, width)


## The grip that resizes the board, drawn out at the arena's bottom-right corner.
##
## An arrow rather than a plain square: the corner of a rectangle already means
## "resize" here for every shape, and this one has to read as resizing *the whole
## board* from across the window.
func _draw_arena_handle() -> void:
	var at := level.arena.end
	var size := HANDLE * 1.6 / _view_scale
	var tint: Color = PolarisTheme.ACCENT if _drag == 5 else PolarisTheme.INK_DIM
	draw_rect(Rect2(at - Vector2(size, size) * 0.5, Vector2(size, size)), tint, true)
	var reach := size * 1.9
	draw_line(at, at + Vector2(reach, 0.0), Color(tint, 0.7), 2.0 / _view_scale)
	draw_line(at, at + Vector2(0.0, reach), Color(tint, 0.7), 2.0 / _view_scale)


func _draw_panel() -> void:
	var x := VIEW.end.x + 30.0
	_label("BAU-MODUS", Vector2(x, 20), PolarisTheme.ACCENT, 16)
	_label(
		"%s · %d×%d" % [level.title, int(level.arena.size.x), int(level.arena.size.y)],
		Vector2(x, 42), PolarisTheme.INK_DIM, 13
	)
	var y := 74.0
	for line: String in _wrap(_hint, 38):
		_label(line, Vector2(x, y), PolarisTheme.INK, 13)
		y += 18.0

	y += 10.0
	for kind: int in [
		Kind.SOLID, Kind.HAZARD, Kind.CHECKPOINT, Kind.SLOWMO,
		Kind.ZONE, Kind.MOVER, Kind.FURNITURE, Kind.SPRING, Kind.POLYGON,
	]:
		var active := kind == _tool
		_label(
			"%d  %s%s" % [kind + 1, _tool_name(kind), "  ×%d" % _count(kind)],
			Vector2(x, y),
			PolarisTheme.ACCENT if active else PolarisTheme.INK_DIM, 13
		)
		y += 18.0

	y += 12.0
	var fields := _fields()
	for i in fields.size():
		var field: Array = fields[i]
		_label(
			"%s  %s" % [String(field[0]), _shown(String(field[1]))],
			Vector2(x, y),
			PolarisTheme.OK if i == _field else PolarisTheme.INK_DIM, 13
		)
		y += 18.0

	y += 12.0
	for line: String in [
		"Ziehen  anlegen / verschieben",
		"Ecke ziehen  Größe",
		"Shift+Klick  dazuwählen",
		"R  90° gegen den Uhrzeiger",
		"H / V  gleiche Höhe / Spalte (Shift: Mitte)",
		"Rechtsklick  löschen",
		"Tab  Feld ·  ←→  ändern",
		"Alt halten  ohne 10er-Raster",
		"Ecke unten rechts  Arena größer",
		"Rad zoomen · Mitte schieben · F einpassen",
		"Strg+Z / Strg+Y  rückgängig",
		"Leertaste  testen",
		"E  nach tools/entwurf.gd.txt",
		"N  neuer Entwurf · Esc  zurück",
	]:
		_label(line, Vector2(x, y), PolarisTheme.INK_DIM, 12)
		y += 17.0

	if not level.par_holds.is_empty():
		_label(
			"Par vorhanden: %d Magnete" % level.par_placements.size(),
			Vector2(x, y + 8.0), PolarisTheme.OK, 13
		)


## A field's value as text. Zero means "the campaign's default" for three of them,
## and printing a 0 there would claim the board had decided something it has not.
func _shown(id: String) -> String:
	var value := _read(id)
	match id:
		"theme":
			return PolarisTheme.world().name
		"strength":
			return "Vorgabe" if value <= 0.0 else str(int(value))
		"field_strength":
			# Not "Vorgabe": unset here means the player's number, not the campaign's,
			# and saying the wrong one would send you looking for a bug.
			return "wie Magnet" if value <= 0.0 else str(int(value))
		"horizon":
			return "Vorgabe" if value <= 0.0 else str(int(value))
		"slowmo":
			return "Vorgabe" if value <= 0.0 else str(int(value))
		"charge":
			return "%.1f" % value
		"fm_pull":
			return "anziehen" if value >= 0.5 else "abstoßen"
	return str(int(value))


func _tool_name(kind: int) -> String:
	match kind:
		Kind.SOLID: return "Wand"
		Kind.HAZARD: return "Zacken"
		Kind.SPRING: return "Sprungfeld"
		Kind.CHECKPOINT: return "Tor"
		Kind.SLOWMO: return "Zeitlupe"
		Kind.ZONE: return "Zone"
		Kind.MOVER: return "Plattform"
		Kind.FURNITURE: return "Fremdes Feld"
		Kind.POLYGON: return "Polygon"
		Kind.TARGET: return "Ziel"
	return "Start"


func _label(text: String, at: Vector2, color: Color, size: int) -> void:
	draw_string(PolarisTheme.font(), at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


func _wrap(text: String, width: int) -> Array[String]:
	var lines: Array[String] = []
	var line := ""
	for word: String in text.split(" ", false):
		var candidate := word if line.is_empty() else line + " " + word
		if candidate.length() > width and not line.is_empty():
			lines.append(line)
			line = word
		else:
			line = candidate
	if not line.is_empty():
		lines.append(line)
	return lines
