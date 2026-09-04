class_name PlayScreen
extends Node2D

## The game view. Owns a [SimWorld], feeds it one input mask per tick, and draws
## the result.
##
## The split is strict on purpose: this file decides *when* to step and what the
## run looks like; [SimWorld] decides what happens. Nothing here may influence the
## outcome — no forces, no positions, no `delta`. That is what keeps a recorded
## run reproducible.
##
## `physics/common/physics_ticks_per_second` is pinned to
## [constant SimWorld.TICK_HZ] in `project.godot`, so exactly one simulation step
## happens per `_physics_process`. A dropped frame therefore slows the run down
## rather than changing it. It is written out explicitly rather than left to
## Godot's default, which happens to be the same 60 — this file depends on it, so
## the project has to state it.

signal exit_requested

const PLACE_RADIUS := 22.0

var world := SimWorld.new()
var level: SimLevel

## Magnets the player has added this attempt. [Array] of [SimLevel.MagnetSpec].
var placed: Array = []
var attract_tool := true
var running := false

## Every tick's input mask, so a run can be replayed or shown as a ghost.
var recording: Array[int] = []

## Optional schedule that drives the run instead of the keyboard, used to watch
## the level's proven replay.
var _playback: Array = []

## True while the par demo has borrowed the board.
##
## The demo needs the level's own magnets on the board to run, but they are not
## the player's: without this the demo silently overwrote whatever they had placed
## and left its magnets behind on the next attempt — on the lift level as a repel
## magnet the player never chose, while the tool indicator still read "Anziehen".
var _demo := false

## The player's own magnets, set aside for the duration of the demo.
var _player_placed: Array = []

## Index of the magnet placed by the press we are still holding, or -1.
##
## Placing and drawing a path are one gesture: press puts the magnet down, release
## decides whether it stands still or shuttles along the line you dragged. A click
## is just a drag of length zero, so the simple case costs nothing.
var _dragging := -1
var _drag_to := Vector2.ZERO

## Shorter than this, a drag counts as a plain click.
const DRAG_MIN := 34.0
var _hint := ""
var _best_ticks := 0


func _ready() -> void:
	set_process(true)
	set_physics_process(true)
	if level == null:
		load_level(Levels.by_id(1))


func load_level(sim_level: SimLevel) -> void:
	level = sim_level
	placed.clear()
	_playback.clear()
	_demo = false
	_player_placed.clear()
	_reset()


func _reset() -> void:
	_leave_demo()
	running = false
	recording.clear()
	world.setup(level, placed)
	_hint = level.lesson
	queue_redraw()


func _start(playback: Array = []) -> void:
	if playback.is_empty():
		# Starting an attempt of your own — take the board back from the demo first,
		# so the budget check below counts the player's magnets and not its.
		_leave_demo()
	if placed.size() < level.budget:
		_hint = "Noch %d Magnet(e) zu setzen." % (level.budget - placed.size())
		return
	_playback = playback
	world.setup(level, placed)
	recording.clear()
	running = true
	_hint = "Halte 1–%d" % world.magnets.size()


# --- The tick ---------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not running:
		return

	var mask := 0
	if _playback.is_empty():
		for i in world.magnets.size():
			if i < 4 and Input.is_key_pressed(KEY_1 + i):
				mask |= 1 << i
		# Held, not toggled — see SimWorld.INVERT_INPUT. Sampled here, once per tick,
		# for the same reason the hold keys are: one value per tick, never mid-frame.
		if level.flip_enabled and Input.is_key_pressed(KEY_SHIFT):
			mask |= SimWorld.INVERT_BIT
	else:
		var t := world.tick_count
		for entry: Array in _playback:
			if t >= int(entry[1]) and t < int(entry[2]):
				mask |= 1 << int(entry[0])

	recording.append(mask)
	world.step(mask)

	if world.outcome == SimWorld.Outcome.WON:
		running = false
		# The demo does not play for a score. It won by replaying the level's own
		# answer, so counting it as a best time would hand the player a record they
		# never set — and one they then have to beat.
		if not _demo and (_best_ticks == 0 or world.tick_count < _best_ticks):
			_best_ticks = world.tick_count
		_hint = "Geschafft in %.2f s" % (float(world.tick_count) / SimWorld.TICK_HZ)
	elif world.outcome == SimWorld.Outcome.LOST:
		running = false
		_hint = "Danebengegangen — R"
	elif world.tick_count >= SimWorld.MAX_RUN_TICKS:
		# The same horizon the offline runs use. Without it an attempt never ended:
		# a ball resting on the floor is neither won nor lost, so the clock just kept
		# counting and the game looked broken. Deliberately *not* a shorter number of
		# its own — a live timeout disagreeing with [constant SimWorld.MAX_RUN_TICKS]
		# would mean the game and the tests that certify its levels disagreed about
		# what a run is.
		running = false
		_hint = "Zeit abgelaufen — R"


func _process(_delta: float) -> void:
	queue_redraw()


# --- Input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and not running:
		var click := (event as InputEventMouseButton)
		# The click's own position, not [method Node2D.get_local_mouse_position].
		# Re-reading the cursor asks a second source where the click happened, and
		# the two can disagree — which also made the placement path impossible to
		# drive from a test, since a synthetic event moves no real cursor.
		var at := (make_input_local(click) as InputEventMouseButton).position
		if click.button_index == MOUSE_BUTTON_LEFT:
			_place(at)
			_dragging = placed.size() - 1 if level.paths_enabled else -1
			_drag_to = at
		elif click.button_index == MOUSE_BUTTON_RIGHT:
			_erase(at)
		return

	# Release: turn the drag into the magnet's path.
	if event is InputEventMouseButton and not event.pressed and _dragging >= 0:
		var up := (make_input_local(event) as InputEventMouseButton).position
		_finish_path(up)
		return

	if event is InputEventMouseMotion and _dragging >= 0:
		_drag_to = (make_input_local(event) as InputEventMouseMotion).position
		queue_redraw()
		return

	if not (event is InputEventKey and event.pressed and not event.is_echo()):
		return
	match (event as InputEventKey).keycode:
		KEY_SPACE:
			if not running:
				_start()
		KEY_R:
			_reset()
		KEY_C:
			placed.clear()
			_reset()
		KEY_TAB:
			attract_tool = not attract_tool
			queue_redraw()
		KEY_P:
			# Watch the schedule this level shipped with — the proof that it can
			# be beaten, doubling as a demo when a board looks impossible.
			if not level.par_holds.is_empty():
				if not _demo:
					_player_placed = placed
					_demo = true
				placed = _par_placements()
				_start(level.par_holds)
				# _start() left "Halte 1–n" behind, which is a lie during a demo: the
				# player is holding nothing and the magnets on screen are not theirs.
				if running:
					_hint = "Musterlauf — R nimmt das Brett zurück"
		KEY_LEFT:
			_step_level(-1)
		KEY_RIGHT:
			_step_level(1)
		KEY_ESCAPE:
			exit_requested.emit()
			# Under `game.tscn` the root listens and swaps the menu back in. Running
			# `play.tscn` on its own there is nobody, and the key would silently do
			# nothing while the HUD advertised it — so fall back to leaving.
			if exit_requested.get_connections().is_empty():
				get_tree().quit()


## Turns the drag that just ended into a path, or leaves the magnet standing.
##
## The endpoint is rounded to whole pixels before it becomes level data. The path
## has to be reproducible from a recording, and a coordinate carrying whatever the
## mouse happened to report is not something a replay can promise to hit again.
func _finish_path(up: Vector2) -> void:
	var index := _dragging
	_dragging = -1
	if index < 0 or index >= placed.size():
		return
	var spec: SimLevel.MagnetSpec = placed[index]
	var travel := Vector2(roundf(up.x - spec.x), roundf(up.y - spec.y))
	if travel.length() < DRAG_MIN:
		return
	spec.travel = travel
	spec.period = SimWorld.sweep_ticks(travel)
	_reset()


## Hands the board back to the player after the demo. Idempotent, because nearly
## every way out of the demo — R, Space, placing, erasing — goes through it.
func _leave_demo() -> void:
	if not _demo:
		return
	_demo = false
	placed = _player_placed
	_player_placed = []
	_playback.clear()


## Level switching lives on the arrow keys while there is no level-select screen.
func _step_level(direction: int) -> void:
	var levels := Levels.all()
	var index := 0
	for i in levels.size():
		if (levels[i] as SimLevel).id == level.id:
			index = i
	index = wrapi(index + direction, 0, levels.size())
	_best_ticks = 0
	load_level(levels[index])


func _par_placements() -> Array:
	var copy: Array = []
	for spec: SimLevel.MagnetSpec in level.par_placements:
		copy.append(spec.duplicate_spec())
	return copy


func _place(at: Vector2) -> void:
	_leave_demo()
	if placed.size() >= level.budget:
		_hint = "Budget voll — Rechtsklick entfernt."
		return
	if not level.arena.has_point(at):
		return
	for solid: Rect2 in level.solids:
		if solid.grow(SimWorld.BALL_RADIUS).has_point(at):
			_hint = "Nicht in eine Wand."
			return
	for mover: SimLevel.MoverSpec in level.movers:
		# The whole corridor, not just where the platform stands right now: a magnet
		# placed in its path would be buried for half of every cycle.
		if mover.swept_rect().grow(SimWorld.BALL_RADIUS).has_point(at):
			_hint = "Nicht in den Weg der Plattform."
			return
	placed.append(SimLevel.MagnetSpec.new(at.x, at.y, attract_tool, false))
	_reset()


func _erase(at: Vector2) -> void:
	_leave_demo()
	for i in range(placed.size() - 1, -1, -1):
		var spec: SimLevel.MagnetSpec = placed[i]
		if Vector2(spec.x, spec.y).distance_to(at) < 34.0:
			placed.remove_at(i)
			_reset()
			return


# --- Drawing ----------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(-4000, -4000, 8000, 8000), PolarisTheme.BG, true)
	if level == null:
		return

	draw_rect(level.arena.grow(6.0), Color(PolarisTheme.MINUS, 0.05), true)
	draw_rect(level.arena, PolarisTheme.BG_DEEP, true)

	var pulse := 1.0 + 0.05 * sin(Time.get_ticks_msec() / 400.0)
	draw_rect(level.target, Color(PolarisTheme.TARGET, 0.12), true)
	draw_rect(level.target.grow(2.0 * pulse), Color(PolarisTheme.TARGET, 0.85), false, 3.0)

	for solid: Rect2 in level.solids:
		draw_rect(solid, PolarisTheme.WALL, true)
		draw_rect(
			Rect2(solid.position, Vector2(solid.size.x, 3)),
			Color(PolarisTheme.WALL_EDGE, 0.85),
			true
		)

	_draw_movers()
	_draw_magnets()
	if _dragging >= 0 and _dragging < placed.size():
		var von: SimLevel.MagnetSpec = placed[_dragging]
		draw_line(Vector2(von.x, von.y), _drag_to, Color(PolarisTheme.ACCENT, 0.6), 2.0)
	_draw_ball()
	_draw_hud()


## Moving platforms, and the corridor each one sweeps.
##
## The track is drawn as well as the platform. The whole decision on these boards
## is *where the platform will be*, so showing only where it is right now would
## ask the player to guess at the level's geometry.
func _draw_movers() -> void:
	for mover: SimLevel.MoverSpec in level.movers:
		var swept := mover.swept_rect()
		# Mint, not amber. Amber means "goal" everywhere else on the board, and on
		# this level the lift's corridor runs straight into the target — in the same
		# colour the two read as one shape.
		draw_rect(swept, Color(PolarisTheme.OK, 0.05), true)
		draw_rect(swept, Color(PolarisTheme.OK, 0.18), false, 1.0)
		# tick_count is already past the last resolved tick, which is exactly the
		# rect the contact solver used — so what is drawn is what the ball hit.
		var rect := mover.rect_at(world.tick_count)
		draw_rect(rect, PolarisTheme.WALL, true)
		draw_rect(Rect2(rect.position, Vector2(rect.size.x, 3)), PolarisTheme.OK, true)


func _draw_magnets() -> void:
	var all := level.magnets_for(placed)
	for i in all.size():
		var spec: SimLevel.MagnetSpec = all[i]
		var pos := spec.position_at(world.tick_count)
		if spec.moves():
			# The whole line, not just where the magnet is now. The plan *is* the line;
			# hiding it would leave the player nothing to aim with.
			var ende := Vector2(spec.x + spec.travel.x, spec.y + spec.travel.y)
			draw_line(Vector2(spec.x, spec.y), ende, Color(PolarisTheme.INK_DIM, 0.45), 2.0)
			draw_circle(Vector2(spec.x, spec.y), 4.0, Color(PolarisTheme.INK_DIM, 0.7))
			draw_circle(ende, 4.0, Color(PolarisTheme.INK_DIM, 0.7))
		var last_mask: int = recording[recording.size() - 1] if recording.size() > 0 else 0
		var reversed_now := running and (last_mask & SimWorld.INVERT_BIT) != 0
		# Show the polarity that is actually acting, not the one it was placed with —
		# otherwise the reverse key has no visible effect at all.
		var acting_attract := spec.attract != reversed_now
		var tint: Color = PolarisTheme.PLUS if acting_attract else PolarisTheme.MINUS
		var charge: float = world.charges[i] if i < world.charges.size() else level.charge_seconds
		var held := running and (last_mask & (1 << i)) != 0

		draw_arc(pos, SimWorld.MAGNET_RADIUS, 0, TAU, 64, Color(tint, 0.10 if held else 0.045), 2.0)
		# The inner ring is where the field actually beats gravity. Without it the
		# outer circle reads as "this is what I can do", and a player placing a magnet
		# that has to lift the ball gets no warning that 300px is far too far.
		draw_arc(pos, SimWorld.LIFT_RADIUS, 0, TAU, 48, Color(tint, 0.22 if held else 0.13), 1.0)
		if held:
			for ring in 3:
				var t := (ring + 1) / 3.0
				draw_circle(pos, SimWorld.MAGNET_RADIUS * t, Color(tint, 0.045 * (1.0 - t)))

		draw_circle(pos, PLACE_RADIUS, Color(tint, 0.35 if charge <= 0.0 else 1.0))
		draw_circle(pos - Vector2(6, 7), 9.0, Color(Color.WHITE, 0.25))
		if charge > 0.0:
			draw_arc(
				pos, PLACE_RADIUS + 7.0, -PI / 2.0,
				-PI / 2.0 + TAU * (charge / level.charge_seconds),
				32, PolarisTheme.ACCENT, 4.0, true
			)
		# Always numbered: the number is the key you press, so hiding it on fixed
		# magnets only hid the control.
		_label(
			str(i + 1),
			pos + Vector2(-5, 6),
			PolarisTheme.BG if charge > 0.0 else PolarisTheme.INK_DIM,
			17
		)


func _draw_ball() -> void:
	var pos := Vector2(world.ball_x, world.ball_y)
	draw_circle(pos + Vector2(0, 3), SimWorld.BALL_RADIUS, Color(0, 0, 0, 0.35))
	draw_circle(pos, SimWorld.BALL_RADIUS, PolarisTheme.BALL)
	draw_arc(pos, SimWorld.BALL_RADIUS, 0, TAU, 24, Color(PolarisTheme.BALL_EDGE, 0.9), 2.0, true)
	draw_circle(pos - Vector2(5, 6), SimWorld.BALL_RADIUS * 0.34, Color(1, 1, 1, 0.8))


func _draw_hud() -> void:
	var x := level.arena.end.x + 30.0
	_label("LEVEL %d · %s" % [level.id, level.title.to_upper()], Vector2(x, 46), PolarisTheme.INK_DIM, 13)
	var wrapped := _wrap(_hint, 34)
	for i in wrapped.size():
		_label(wrapped[i], Vector2(x, 82 + i * 20), PolarisTheme.INK, 14)

	if level.budget > 0:
		var tool_name := "Anziehen" if attract_tool else "Abstoßen"
		var tool_color: Color = PolarisTheme.PLUS if attract_tool else PolarisTheme.MINUS
		_label(
			"%s  (Tab) · %d/%d gesetzt" % [tool_name, placed.size(), level.budget],
			Vector2(x, 150), tool_color, 14
		)

	if level.flip_enabled:
		var flipping := (
			running
			and recording.size() > 0
			and (recording[recording.size() - 1] & SimWorld.INVERT_BIT) != 0
		)
		_label(
			"UMGEPOLT" if flipping else "Shift kehrt um",
			Vector2(x, 172),
			PolarisTheme.ACCENT if flipping else PolarisTheme.INK_DIM,
			14
		)

	var keys := [
		"Leertaste  starten",
		"1–4 halten  Magnet wirkt",
		"R  neuer Versuch",
		"P  Musterlauf ansehen",
		"Esc  zurück",
	]
	if level.flip_enabled:
		keys.insert(2, "Shift halten  Polarität umkehren")
	if level.paths_enabled:
		keys.push_front("Ziehen  Bahn für den Magneten")
	if level.budget > 0:
		keys.push_front("Rechtsklick  entfernen")
		keys.push_front("Linksklick  Magnet setzen")
	for i in keys.size():
		_label(keys[i], Vector2(x, 196 + i * 22), PolarisTheme.INK_DIM, 13)

	_label("%.2f s" % (float(world.tick_count) / SimWorld.TICK_HZ), Vector2(x, 400), PolarisTheme.ACCENT, 30)
	if _best_ticks > 0:
		_label(
			"Bestzeit %.2f s" % (float(_best_ticks) / SimWorld.TICK_HZ),
			Vector2(x, 436), PolarisTheme.OK, 14
		)


## Greedy word wrap. `draw_string` has no wrapping and the HUD column is narrow.
func _wrap(text: String, width: int) -> Array[String]:
	var lines: Array[String] = []
	var line := ""
	for word: String in text.split(" "):
		if line.is_empty():
			line = word
		elif line.length() + 1 + word.length() <= width:
			line += " " + word
		else:
			lines.append(line)
			line = word
	if not line.is_empty():
		lines.append(line)
	return lines


func _label(text: String, at: Vector2, color: Color, size: int) -> void:
	draw_string(PolarisTheme.font(), at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
