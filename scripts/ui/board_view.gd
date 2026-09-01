class_name BoardView
extends Control

## The interactive board: everything is drawn in [method _draw], and the mouse
## talks straight to [GameState].
##
## [b]Coordinates[/b]: cells are [Vector2i] with x = row, y = col (see
## [Movement]). This is the one place that flips them into pixels — every helper
## below goes through [method cell_rect], so the convention is stated once.
##
## [b]Visual hierarchy[/b], loudest last:
##  1. placed magnets show faint field arrows — the reach rule, always readable;
##  2. hovering an empty cell ghosts the magnet the current tool would place;
##  3. hovering a *placed* magnet draws the full path its shot would take.
##
## (3) is the point of the whole screen. Answering "what does this magnet do from
## here?" before the move is spent is what turns silent mental arithmetic into a
## conversation with the board.
##
## Ball motion is interpolated here rather than in [GameState]: the controller
## snaps balls to whole cells and says "this changed", and this view eases each
## ball from where it was drawn to where it now is. Because the controller steps
## corner by corner, a deflected slide reads as "across, then down" instead of a
## diagonal cut across the board.

## Emitted when the pointer moves onto a different cell (or off the board, with
## an out-of-range cell).
signal hovered_cell_changed(cell: Vector2i)

const GAP_RATIO := 0.06
const MAGNET_FRACTION := 0.74
const BALL_FRACTION := 0.6
const WAYPOINT_FRACTION := 0.46

## Seconds a ball takes to travel one leg. Matched to [constant GameState.STEP_MS]
## so the tween lands just as the controller issues the next step.
const BALL_TRAVEL := GameState.STEP_MS / 1000.0

## How long an impact ring lingers, and how long a fired magnet flares.
const IMPACT_SECONDS := 0.32
const PULSE_SECONDS := 0.3
const GATE_SECONDS := 0.28

## Trail samples kept per ball. Short on purpose — a long comet reads as motion
## blur rather than as a path.
const TRAIL_LENGTH := 10

var state: GameState

var _hover_cell := Vector2i(-1, -1)
var _board_rect := Rect2()
var _cell_size := 0.0
var _gap := 0.0

## Per-ball interpolation, all in cell space (x = row, y = col as floats).
var _ball_visual: Array[Vector2] = []
var _ball_from: Array[Vector2] = []
var _ball_elapsed: Array[float] = []
var _ball_trail: Array = []

## Cell -> seconds remaining, for the transient effects.
var _magnet_pulse: Dictionary = {}
var _impacts: Dictionary = {}

## Gate cell -> seconds remaining on its open/close animation.
var _gate_anim: Dictionary = {}

## Seconds the win glow has been running, or -1 when not won.
var _win_glow := -1.0

var _box := StyleBoxFlat.new()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)


## Binds this view to [param game_state] and snaps the balls to their starts.
func bind(game_state: GameState) -> void:
	if state != null:
		state.changed.disconnect(_on_state_changed)
		state.activation_started.disconnect(_on_activation_started)
		state.ball_landed.disconnect(_on_ball_landed)
		state.solved_level.disconnect(_on_solved)
		state.gates_toggled.disconnect(_on_gates_toggled)
	state = game_state
	state.changed.connect(_on_state_changed)
	state.activation_started.connect(_on_activation_started)
	state.ball_landed.connect(_on_ball_landed)
	state.solved_level.connect(_on_solved)
	state.gates_toggled.connect(_on_gates_toggled)
	_magnet_pulse.clear()
	_impacts.clear()
	_gate_anim.clear()
	_win_glow = -1.0
	_snap_balls()
	queue_redraw()


func _on_state_changed() -> void:
	_sync_ball_targets()
	queue_redraw()


func _on_activation_started(cell: Vector2i) -> void:
	_magnet_pulse[cell] = PULSE_SECONDS
	queue_redraw()


## A ball came to rest. Longer slides land harder, so the ring scales with the
## distance travelled — the cheapest way to make a deterministic grid move feel
## like it had weight behind it.
func _on_ball_landed(cell: Vector2i, travelled: int) -> void:
	_impacts[cell] = {"left": IMPACT_SECONDS, "force": clampf(travelled / 4.0, 0.35, 1.0)}


func _on_solved() -> void:
	_win_glow = 0.0


## Gates just flipped. Animating only the affected channel is what makes the
## cause visible: the player sees *these* gates react to the plate they pressed.
func _on_gates_toggled(channels: int) -> void:
	for cell: Vector2i in state.puzzle.gates:
		var gate: Gate = state.puzzle.gates[cell]
		if (channels & (1 << gate.channel)) != 0:
			_gate_anim[cell] = GATE_SECONDS
	queue_redraw()


## Jumps every ball to its logical cell without animating — for a fresh level or
## a rewind, where easing from the previous board would look like a stray move.
func _snap_balls() -> void:
	_ball_visual.clear()
	_ball_from.clear()
	_ball_elapsed.clear()
	_ball_trail.clear()
	if state == null:
		return
	for cell: Vector2i in state.ball_positions:
		var p := Vector2(cell)
		_ball_visual.append(p)
		_ball_from.append(p)
		_ball_elapsed.append(BALL_TRAVEL)
		_ball_trail.append([] as Array)


func _sync_ball_targets() -> void:
	if state == null:
		return
	if _ball_visual.size() != state.ball_positions.size():
		_snap_balls()
		return
	for i in state.ball_positions.size():
		var goal := Vector2(state.ball_positions[i] as Vector2i)
		if _ball_visual[i].is_equal_approx(goal):
			continue
		if _ball_elapsed[i] < BALL_TRAVEL:
			continue  # already heading somewhere; let the leg finish
		_ball_from[i] = _ball_visual[i]
		_ball_elapsed[i] = 0.0


func _process(delta: float) -> void:
	if state == null:
		return
	var dirty := false

	for i in _ball_visual.size():
		if _ball_elapsed[i] >= BALL_TRAVEL:
			# Let a resting ball's trail fade out rather than snapping away.
			var resting: Array = _ball_trail[i]
			if not resting.is_empty():
				resting.pop_front()
				dirty = true
			continue
		_ball_elapsed[i] = minf(_ball_elapsed[i] + delta, BALL_TRAVEL)
		# Slight overshoot on arrival: the ball settles into the cell instead of
		# stopping dead on it. Integer-exact result, physical-looking landing.
		var t := ease(_ball_elapsed[i] / BALL_TRAVEL, -1.6)
		var goal := Vector2(state.ball_positions[i] as Vector2i)
		_ball_visual[i] = _ball_from[i].lerp(goal, t)
		var trail: Array = _ball_trail[i]
		trail.append(_ball_visual[i])
		while trail.size() > TRAIL_LENGTH:
			trail.pop_front()
		dirty = true

	dirty = _tick_timers(_magnet_pulse, delta) or dirty
	dirty = _tick_timers(_gate_anim, delta) or dirty
	dirty = _tick_impacts(delta) or dirty

	if _win_glow >= 0.0:
		_win_glow += delta
		dirty = true

	if dirty:
		queue_redraw()


func _tick_timers(timers: Dictionary, delta: float) -> bool:
	if timers.is_empty():
		return false
	for cell: Vector2i in timers.keys():
		var left: float = timers[cell] - delta
		if left <= 0.0:
			timers.erase(cell)
		else:
			timers[cell] = left
	return true


func _tick_impacts(delta: float) -> bool:
	if _impacts.is_empty():
		return false
	for cell: Vector2i in _impacts.keys():
		var entry: Dictionary = _impacts[cell]
		entry["left"] -= delta
		if entry["left"] <= 0.0:
			_impacts.erase(cell)
	return true


# --- Geometry ---------------------------------------------------------------

## Recomputes the centred square the board occupies inside this Control.
func _update_geometry() -> void:
	var grid: int = state.puzzle.size
	var side := minf(size.x, size.y)
	var origin := (size - Vector2(side, side)) * 0.5
	_board_rect = Rect2(origin, Vector2(side, side))
	_gap = side * GAP_RATIO / grid
	_cell_size = (side - _gap * (grid - 1)) / grid


func _step() -> float:
	return _cell_size + _gap


## Pixel rect of [param cell] — the single row/col -> x/y flip.
func cell_rect(cell: Vector2i) -> Rect2:
	return Rect2(
		_board_rect.position + Vector2(cell.y * _step(), cell.x * _step()),
		Vector2(_cell_size, _cell_size)
	)


## Pixel rect for content centred inside a cell, occupying [param fraction] of it.
func content_rect(cell: Vector2i, fraction: float) -> Rect2:
	var inset := _cell_size * (1.0 - fraction) * 0.5
	return cell_rect(cell).grow(-inset)


func cell_center(cell: Vector2i) -> Vector2:
	return cell_rect(cell).get_center()


## Cell centre for a fractional cell position, used to draw a ball mid-travel.
func _visual_center(p: Vector2) -> Vector2:
	return (
		_board_rect.position
		+ Vector2(p.y * _step(), p.x * _step())
		+ Vector2(_cell_size, _cell_size) * 0.5
	)


## The cell under [param point] (local pixels), or (-1, -1) outside the grid.
func cell_at(point: Vector2) -> Vector2i:
	if not _board_rect.has_point(point):
		return Vector2i(-1, -1)
	var local := point - _board_rect.position
	var cell := Vector2i(int(local.y / _step()), int(local.x / _step()))
	if not state.puzzle.in_bounds(cell):
		return Vector2i(-1, -1)
	return cell


# --- Input ------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if state == null:
		return

	if event is InputEventMouseMotion:
		var cell := cell_at((event as InputEventMouseMotion).position)
		if cell != _hover_cell:
			_hover_cell = cell
			hovered_cell_changed.emit(cell)
			queue_redraw()
		return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if not button.pressed:
			return
		var cell := cell_at(button.position)
		if cell.x < 0:
			return
		if button.button_index == MOUSE_BUTTON_LEFT:
			state.click_cell(cell)
			accept_event()
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			# Right-click removes without switching tools — the desktop shortcut
			# that keeps the plus/minus choice intact while fixing a misplacement.
			state.erase_cell(cell)
			accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover_cell.x >= 0:
		_hover_cell = Vector2i(-1, -1)
		hovered_cell_changed.emit(_hover_cell)
		queue_redraw()


# --- Drawing ----------------------------------------------------------------

func _draw() -> void:
	if state == null or state.puzzle == null:
		return
	_update_geometry()

	_draw_backdrop()
	_draw_cells()
	_draw_magnet_fields()
	_draw_impacts()
	_draw_waypoints()
	_draw_shot_preview()
	_draw_magnets()
	_draw_trails()
	_draw_balls()


## A soft glow behind the board so it sits *in* something instead of floating on
## a flat rectangle. Concentric translucent rounded rects are cheap and read as a
## light source without needing a shader or a texture.
func _draw_backdrop() -> void:
	var steps := 5
	for i in range(steps, 0, -1):
		var t := float(i) / steps
		var grow := _cell_size * 0.9 * t
		_draw_round_rect(
			_board_rect.grow(grow),
			Color(PolarisTheme.MINUS, 0.030 * (1.0 - t) + 0.012),
			_cell_size * 0.4
		)


func _draw_cells() -> void:
	var puzzle := state.puzzle
	var radius := _cell_size * 0.16
	var multi := puzzle.is_multi_ball()

	for r in puzzle.size:
		for c in puzzle.size:
			var cell := Vector2i(r, c)
			var rect := cell_rect(cell)
			if puzzle.is_wall(cell):
				# Walls read as raised blocks: a lighter top edge and a dark base,
				# so they sit *above* the floor instead of merely being a different
				# shade of it.
				_draw_round_rect(rect.grow(1.0), Color(0, 0, 0, 0.35), radius)
				_draw_round_rect(rect, PolarisTheme.WALL, radius)
				_draw_round_rect(
					Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.42)),
					Color(PolarisTheme.WALL_EDGE, 0.55),
					radius
				)
				_draw_wall_hatch(rect)
			else:
				var fill := (
					PolarisTheme.CELL_HOVER if cell == _hover_cell else PolarisTheme.CELL_FREE
				)
				_draw_round_rect(rect, fill, radius)
				# A one-pixel top highlight and a darker floor give the empty cell
				# just enough relief to stop the grid reading as flat paint.
				draw_line(
					rect.position + Vector2(radius, 0.5),
					Vector2(rect.end.x - radius, rect.position.y + 0.5),
					Color(1, 1, 1, 0.05),
					1.0
				)
			var deflector := puzzle.deflector_at(cell)
			if deflector != Deflector.NONE:
				_draw_deflector(rect, deflector)
			if puzzle.is_plate(cell):
				_draw_plate(rect, int(puzzle.plates[cell]))
			if puzzle.is_gate(cell):
				_draw_gate(cell, rect)
			if puzzle.start_index_at(cell) != -1:
				draw_arc(
					rect.get_center(),
					rect.size.x * 0.15,
					0, TAU, 24,
					Color(PolarisTheme.INK_DIM, 0.4),
					maxf(1.0, _cell_size * 0.03),
					true
				)
			var target_index := puzzle.target_index_at(cell)
			if target_index != -1:
				_draw_target(rect, PolarisTheme.target_color(target_index, multi))


## The target ring. It breathes while the level is unsolved so the eye always
## knows where it is going, and flares once on the win.
func _draw_target(rect: Rect2, color: Color) -> void:
	var center := rect.get_center()
	var base := rect.size.x * 0.31
	var pulse := 1.0 + 0.06 * sin(Time.get_ticks_msec() / 420.0)
	draw_arc(
		center, base * pulse, 0, TAU, 32, Color(color, 0.85), maxf(2.0, _cell_size * 0.05), true
	)
	if _win_glow >= 0.0 and _win_glow < 0.9:
		var t := _win_glow / 0.9
		draw_arc(
			center,
			base * (1.0 + t * 1.6),
			0, TAU, 40,
			Color(color, (1.0 - t) * 0.7),
			maxf(2.0, _cell_size * 0.06 * (1.0 - t)),
			true
		)


func _draw_round_rect(rect: Rect2, color: Color, radius: float) -> void:
	_box.bg_color = color
	_box.set_corner_radius_all(int(radius))
	draw_style_box(_box, rect)


## Walls read as hatched blocks so they stay distinct from an empty cell even for
## a player who cannot rely on the colour difference.
func _draw_wall_hatch(rect: Rect2) -> void:
	var color := Color(0, 0, 0, 0.22)
	var width := maxf(1.0, _cell_size * 0.05)
	var stride := _cell_size * 0.28
	var x := rect.position.x - rect.size.y
	while x < rect.end.x:
		var clipped := _clip_segment_to_rect(
			Vector2(x, rect.end.y), Vector2(x + rect.size.y, rect.position.y), rect
		)
		if not clipped.is_empty():
			draw_line(clipped[0], clipped[1], color, width)
		x += stride


## Liang-Barsky clip of segment [param a]-[param b] against [param rect].
## Returns `[from, to]`, or an empty Array when the segment misses entirely.
func _clip_segment_to_rect(a: Vector2, b: Vector2, rect: Rect2) -> Array:
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	var p := [-d.x, d.x, -d.y, d.y]
	var q := [
		a.x - rect.position.x,
		rect.end.x - a.x,
		a.y - rect.position.y,
		rect.end.y - a.y,
	]
	for i in 4:
		if is_zero_approx(p[i]):
			if q[i] < 0.0:
				return []
			continue
		var t: float = q[i] / p[i]
		if p[i] < 0.0:
			t0 = maxf(t0, t)
		else:
			t1 = minf(t1, t)
	if t0 > t1:
		return []
	return [a + d * t0, a + d * t1]


## A pressure plate: a flat ring set into the floor, in its channel's colour.
func _draw_plate(rect: Rect2, channel: int) -> void:
	var center := rect.get_center()
	var color := PolarisTheme.channel_color(channel)
	var radius := rect.size.x * 0.30
	draw_circle(center, radius, Color(color, 0.14))
	draw_arc(center, radius, 0, TAU, 28, Color(color, 0.75), maxf(1.5, _cell_size * 0.04), true)
	# A short inward tick on each side reads as "press me" without a label.
	for step: Vector2i in Movement.DIRECTIONS:
		var dir := Vector2(step.y, step.x)
		draw_line(
			center + dir * radius * 0.45,
			center + dir * radius * 0.8,
			Color(color, 0.75),
			maxf(1.0, _cell_size * 0.03),
			true
		)


## A gate: a barred block when shut, an empty frame when open. The bars slide
## apart as it opens, so the change is legible even at a glance.
func _draw_gate(cell: Vector2i, rect: Rect2) -> void:
	var gate: Gate = state.puzzle.gates[cell]
	var color := PolarisTheme.channel_color(gate.channel)
	var open := gate.is_open(state.gate_mask)

	# 0 = fully shut, 1 = fully open, easing through any running animation.
	var progress := 1.0 if open else 0.0
	var anim: float = _gate_anim.get(cell, 0.0)
	if anim > 0.0:
		var t: float = 1.0 - anim / GATE_SECONDS
		progress = t if open else 1.0 - t

	var radius := _cell_size * 0.16
	# The doorway itself: a recess that stays put whether the gate is open or not,
	# so the cell always reads as "a way through", never as decoration.
	_draw_round_rect(rect, Color(PolarisTheme.BG_DEEP, 0.55), radius)
	_draw_round_rect(rect, Color(color, 0.06 + 0.10 * (1.0 - progress)), radius)

	# Two shutters sliding in from the sides. Loud enough to read at a glance,
	# quiet enough not to dominate a board it shares with magnets and a target.
	var closed := 1.0 - progress
	var half_width := rect.size.x * 0.5 * closed
	if half_width > 0.5:
		var inset := _cell_size * 0.08
		for side: float in [-1.0, 1.0]:
			var edge: float = rect.get_center().x + side * rect.size.x * 0.5
			var shutter := Rect2(
				Vector2(minf(edge, edge - side * half_width), rect.position.y + inset),
				Vector2(half_width, rect.size.y - inset * 2.0)
			)
			_draw_round_rect(shutter, Color(color, 0.72), radius * 0.5)
		# A seam down the middle while shut, so the two halves read as a pair.
		if closed > 0.9:
			draw_line(
				Vector2(rect.get_center().x, rect.position.y + _cell_size * 0.12),
				Vector2(rect.get_center().x, rect.end.y - _cell_size * 0.12),
				Color(PolarisTheme.BG_DEEP, 0.5),
				maxf(1.0, _cell_size * 0.03)
			)
	# Frame last, so it outlines whatever state the shutters are in.
	draw_rect(rect.grow(-1.0), Color(color, 0.5), false, maxf(1.5, _cell_size * 0.03))


## A deflector reads as a diagonal mirror bar: '\' top-left to bottom-right,
## '/' bottom-left to top-right.
func _draw_deflector(rect: Rect2, dir: int) -> void:
	var r := rect.grow(-rect.size.x * 0.22)
	var width := rect.size.x * 0.16
	if dir == Deflector.Dir.BACKSLASH:
		draw_line(r.position, r.end, PolarisTheme.MINUS_LIGHT, width, true)
	else:
		draw_line(
			Vector2(r.position.x, r.end.y),
			Vector2(r.end.x, r.position.y),
			PolarisTheme.MINUS_LIGHT,
			width,
			true
		)


## Each placed magnet's area of effect: a small arrow in every cell it can grab a
## ball from. Kept faint — this is background information about reach, and the
## hovered magnet's shot preview is what should carry the eye.
func _draw_magnet_fields() -> void:
	var placed := state.magnet_list()
	var occupied := {}
	for m: Magnet in placed:
		occupied[m.pos] = true

	for magnet: Magnet in placed:
		var alpha := 0.10 if state.is_spent(magnet.pos) else 0.20
		if magnet.pos == _hover_cell:
			alpha = 0.4
		_draw_field_of(magnet, occupied, alpha)

	var ghost := _hover_ghost()
	if ghost != null:
		_draw_field_of(ghost, occupied, 0.3)


## The magnet the player would place by clicking the hovered cell, or null when
## hovering nothing placeable (or when the board is not accepting input).
func _hover_ghost() -> Magnet:
	if state.animating or state.solved:
		return null
	if _hover_cell.x < 0 or state.selected_tool == GameState.Tool.ERASE:
		return null
	if state.magnets.has(_hover_cell) or not state.puzzle.is_placeable(_hover_cell):
		return null
	var type := (
		Magnet.Type.PLUS if state.selected_tool == GameState.Tool.PLUS else Magnet.Type.MINUS
	)
	if state.remaining_of(type) <= 0:
		return null
	return Magnet.new(_hover_cell, type)


## Draws a magnet's reach as four tapering beams rather than a scatter of
## arrowheads.
##
## Same information — which cells it grabs, and which way they go — but a
## continuous lane that fades with distance reads as a *field*, which is the one
## thing a game about magnets ought to look like. The arrowheads stay, smaller,
## riding the beam so the direction is still unambiguous.
func _draw_field_of(magnet: Magnet, occupied: Dictionary, alpha: float) -> void:
	var tint := PolarisTheme.magnet_color(magnet.type)
	var origin := cell_center(magnet.pos)

	# Group the covered cells by direction so each arm can be drawn as one beam.
	var arms := {}
	for entry: Dictionary in Movement.magnet_field(magnet, state.puzzle, state.gate_mask):
		var cell: Vector2i = entry["cell"]
		if occupied.has(cell):
			continue
		var outward: Vector2i = cell - magnet.pos
		var dir := Vector2i(signi(outward.x), signi(outward.y))
		var reach: int = absi(outward.x) + absi(outward.y)
		if not arms.has(dir):
			arms[dir] = {"reach": 0, "step": entry["step"], "cells": [] as Array}
		var arm: Dictionary = arms[dir]
		# Extend the arm rather than replacing it — overwriting the entry here
		# threw away every cell found so far, leaving one arrowhead per direction.
		arm["reach"] = maxi(int(arm["reach"]), reach)
		(arm["cells"] as Array).append(cell)

	for dir: Vector2i in arms:
		var arm: Dictionary = arms[dir]
		var away := Vector2(dir.y, dir.x)  # (dr, dc) -> (x, y)
		var length: float = _step() * float(arm["reach"])
		# Three stacked strokes, each shorter and narrower, fake a soft gradient
		# that fades with distance from the magnet.
		for i in 3:
			draw_line(
				origin,
				origin + away * length * (1.0 - 0.16 * i),
				Color(tint, alpha * 0.5),
				_cell_size * (0.60 - 0.17 * i),
				true
			)
		for cell: Vector2i in arm["cells"]:
			_draw_arrow(cell_center(cell), arm["step"], Color(tint, minf(alpha * 2.2, 0.75)))


## A small triangular arrowhead at [param center] pointing along [param step]
## (a (dr, dc) cell step, so it flips to (x, y) here).
func _draw_arrow(center: Vector2, step: Vector2i, color: Color) -> void:
	var dir := Vector2(step.y, step.x)
	var perp := Vector2(-dir.y, dir.x)
	var tip := center + dir * (_cell_size * 0.16)
	var back := center - dir * (_cell_size * 0.02)
	draw_colored_polygon(
		PackedVector2Array([
			tip,
			back + perp * (_cell_size * 0.09),
			back - perp * (_cell_size * 0.09),
		]),
		color
	)


## The headline feedback: hovering a magnet that can fire draws exactly where
## every ball would end up, corner bends included.
func _draw_shot_preview() -> void:
	if _hover_cell.x < 0:
		return
	var paths := state.preview_paths(_hover_cell)
	if paths.is_empty():
		return
	var multi := paths.size() > 1

	for i in paths.size():
		var path: Array = paths[i]
		if path.size() < 2:
			continue
		var color := PolarisTheme.ball_color(i, multi) if multi else PolarisTheme.ACCENT
		for j in range(path.size() - 1):
			_draw_dashed_line(cell_center(path[j]), cell_center(path[j + 1]), color)
		# A ghost ball on the landing cell answers "where does it stop?" directly.
		var landing := cell_center(path[path.size() - 1])
		var radius := _cell_size * BALL_FRACTION * 0.5
		draw_circle(landing, radius, Color(color, 0.18))
		draw_arc(landing, radius, 0, TAU, 32, Color(color, 0.85), _cell_size * 0.045, true)


func _draw_dashed_line(from: Vector2, to: Vector2, color: Color) -> void:
	var dash := _cell_size * 0.16
	var gap := _cell_size * 0.12
	var total := from.distance_to(to)
	if is_zero_approx(total):
		return
	var dir := (to - from) / total
	var width := _cell_size * 0.07
	# Creep the dashes along the line so the preview reads as a direction of
	# travel rather than a static dotted rule.
	var offset := fmod(Time.get_ticks_msec() / 1000.0 * _cell_size * 0.9, dash + gap)
	var travelled := -offset
	while travelled < total:
		var start := maxf(travelled, 0.0)
		var end := minf(travelled + dash, total)
		if end > start:
			draw_line(from + dir * start, from + dir * end, Color(color, 0.7), width, true)
		travelled += dash + gap


## A collectible waypoint, drawn as a diamond gem. Dims once a ball has touched it.
func _draw_waypoints() -> void:
	for cell: Vector2i in state.puzzle.waypoints:
		var collected := state.collected_waypoints.has(cell)
		var center := cell_center(cell)
		var radius := _cell_size * WAYPOINT_FRACTION * 0.5
		if not collected:
			radius *= 1.0 + 0.05 * sin(Time.get_ticks_msec() / 380.0)
		var diamond := PackedVector2Array([
			center + Vector2(0, -radius),
			center + Vector2(radius, 0),
			center + Vector2(0, radius),
			center + Vector2(-radius, 0),
		])
		draw_colored_polygon(diamond, Color(PolarisTheme.OK, 0.5 if collected else 0.22))
		var outline := diamond.duplicate()
		outline.append(diamond[0])
		draw_polyline(
			outline,
			Color(PolarisTheme.OK, 0.45 if collected else 1.0),
			maxf(1.5, _cell_size * 0.045),
			true
		)


## Expanding rings where balls came to rest — the weight behind a move.
func _draw_impacts() -> void:
	for cell: Vector2i in _impacts:
		var entry: Dictionary = _impacts[cell]
		var t: float = 1.0 - entry["left"] / IMPACT_SECONDS
		var force: float = entry["force"]
		draw_arc(
			cell_center(cell),
			_cell_size * (0.2 + t * 0.55 * force),
			0, TAU, 28,
			Color(PolarisTheme.INK, (1.0 - t) * 0.35 * force),
			maxf(1.5, _cell_size * 0.05 * (1.0 - t)),
			true
		)


func _draw_magnets() -> void:
	# Firing order, so a run reads back as "1, 2, 3" on the board itself.
	var order := {}
	for i in state.fired.size():
		var cell: Vector2i = state.fired[i]
		var existing: String = order.get(cell, "")
		order[cell] = ("%s,%d" % [existing, i + 1]) if existing else str(i + 1)

	var ghost := _hover_ghost()
	if ghost != null:
		_draw_magnet_chip(ghost.pos, ghost.type, "", 0.35, false)

	for cell: Vector2i in state.magnets:
		_draw_magnet_chip(
			cell, state.magnets[cell], order.get(cell, ""), 1.0, state.is_spent(cell)
		)


func _draw_magnet_chip(
	cell: Vector2i, type: Magnet.Type, order_label: String, alpha: float, spent: bool
) -> void:
	var rect := content_rect(cell, MAGNET_FRACTION)
	var center := rect.get_center()
	var radius := rect.size.x * 0.5
	var body_alpha := alpha * (0.4 if spent else 1.0)

	var pulse: float = _magnet_pulse.get(cell, 0.0)
	if pulse > 0.0:
		var t := pulse / PULSE_SECONDS
		draw_circle(center, radius * (1.0 + (1.0 - t) * 0.9), Color(PolarisTheme.ACCENT, t * 0.45))

	# A hoverable, ready magnet lifts slightly so it reads as clickable.
	var armed := cell == _hover_cell and state.can_fire(cell)
	if armed:
		draw_circle(center, radius * 1.22, Color(PolarisTheme.ACCENT, 0.22))

	# A magnet is the loudest thing on the board, so give it an actual halo:
	# stacked translucent discs fake an additive glow without a shader.
	var tint := PolarisTheme.magnet_color(type)
	if not spent:
		for i in 3:
			var t := (i + 1) / 3.0
			draw_circle(center, radius * (1.0 + t * 0.75), Color(tint, 0.10 * (1.0 - t) * alpha))
	draw_circle(center, radius, Color(tint, body_alpha))
	draw_circle(
		center - Vector2(radius, radius) * 0.28,
		radius * 0.55,
		Color(PolarisTheme.magnet_light(type), body_alpha * 0.6)
	)
	draw_arc(center, radius, 0, TAU, 32, Color(Color.WHITE, body_alpha * 0.22), radius * 0.09, true)

	var symbol := "+" if type == Magnet.Type.PLUS else "−"
	_draw_centered_text(symbol, center, radius * 1.1, Color(Color.WHITE, body_alpha))

	if spent:
		# A spent single-use magnet is dead weight; say so plainly.
		var bar := radius * 0.5
		draw_line(
			center + Vector2(-bar, bar),
			center + Vector2(bar, -bar),
			Color(PolarisTheme.INK, 0.55),
			maxf(2.0, radius * 0.13),
			true
		)

	if order_label.is_empty():
		return
	var badge_center := center + Vector2(radius, -radius) * 0.78
	var badge_radius := maxf(9.0, radius * 0.42)
	draw_circle(badge_center, badge_radius, PolarisTheme.ACCENT)
	_draw_centered_text(order_label, badge_center, badge_radius * 1.5, PolarisTheme.BG)


## Fading streaks behind moving balls, so a fast slide leaves evidence of the
## route it took instead of just teleporting.
func _draw_trails() -> void:
	var multi := state.puzzle.is_multi_ball()
	for i in _ball_trail.size():
		var trail: Array = _ball_trail[i]
		if trail.size() < 2:
			continue
		var color := PolarisTheme.ball_color(i, multi)
		var radius := _cell_size * BALL_FRACTION * 0.5
		for j in trail.size():
			var t := float(j + 1) / trail.size()
			draw_circle(_visual_center(trail[j]), radius * t * 0.7, Color(color, t * 0.16))


func _draw_balls() -> void:
	var multi := state.puzzle.is_multi_ball()
	for i in _ball_visual.size():
		var center := _visual_center(_ball_visual[i])
		var radius := _cell_size * BALL_FRACTION * 0.5
		var tint := PolarisTheme.ball_color(i, multi)
		# Drop shadow, body, dark rim, then a bright highlight: four cheap circles
		# that turn a flat disc into something with a surface.
		draw_circle(center + Vector2(0, radius * 0.18), radius, Color(0, 0, 0, 0.35))
		draw_circle(center, radius, tint)
		draw_arc(center, radius, 0, TAU, 32, Color(PolarisTheme.BALL_EDGE, 0.9), radius * 0.14, true)
		draw_circle(center - Vector2(radius, radius) * 0.3, radius * 0.4, Color(1, 1, 1, 0.55))
		draw_circle(center - Vector2(radius, radius) * 0.38, radius * 0.18, Color(1, 1, 1, 0.85))


func _draw_centered_text(text: String, center: Vector2, box: float, color: Color) -> void:
	var font := get_theme_default_font()
	var font_size := int(maxf(8.0, box * 0.62))
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var ascent := font.get_ascent(font_size)
	var descent := font.get_descent(font_size)
	draw_string(
		font,
		center + Vector2(-width * 0.5, (ascent - descent) * 0.5),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		color
	)
