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

## The last attempt that was won: what stood on the board, and every tick's input.
##
## Empty until something wins. Only the build mode reads it — see the note where
## it is filled.
var won_placed: Array = []
var won_recording: Array[int] = []
var running := false

## Every tick's input mask, so a run can be replayed or shown as a ghost.
var recording: Array[int] = []

## Recent ball positions, oldest first, for the drawn trail. Presentation only:
## it is written from the simulation's state and never read back into it.
var _trail: Array[Vector2] = []
const TRAIL_LENGTH := 14

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
var _player_prefix: Array[int] = []
var _player_resume := -1

## The part of the run that is already decided: every input mask from tick 0 up to
## the checkpoint the next attempt resumes from. Empty means "from the start".
##
## A resumed attempt is not a fresh run with the ball dropped in — it is the same
## run, replayed. [method _rewind] steps these masks through [SimWorld] before
## handing control back, so the ball arrives at the checkpoint carrying exactly the
## speed and direction it had the first time. That is what makes the level one
## journey rather than a level select with extra steps.
##
## Replayed rather than snapshotted on purpose. A snapshot would put the ball in a
## state no sequence of inputs produces, and a run that cannot be described as
## inputs cannot be a replay, a ghost or a leaderboard entry. Three hundred ticks
## of re-simulation cost microseconds.
var _prefix: Array[int] = []

## Checkpoint the next attempt starts from, or -1 for the beginning.
var _resume_index := -1

## Simulation ticks left of the slow-motion stretch a point started.
##
## Crossing a gate does not stop the run any more — it *slows* it, and hands the
## player the magnet then and there. Waiting for the attempt to fail before
## spending it meant every checkpoint cost a death first; this keeps the run one
## continuous thing, which is the whole point of carrying the speed across.
##
## [SimWorld] needs nothing for it. A magnet placed here is born at the tick it
## was placed on ([member SimLevel.MagnetSpec.spawn_tick]), which is the same
## mechanism a magnet placed *between* attempts already uses, so a recorded run is
## still placements-with-birthdays plus one bitmask per tick.
var _placement_ticks := 0

## Checkpoint whose window has already been offered this attempt.
var _armed_index := -1

## Slow-motion point whose slowdown has already been spent this attempt.
var _slowed_index := -1

## Physics frames counted off inside one simulated tick, for the slow motion.
var _slow_phase := 0

## Where the ball stood at the end of the previous tick, and how far the wall clock
## has travelled into the current one (0 → 1).
##
## The board is drawn *between* the two. Without this, slow motion looked broken
## rather than slow: the frame rate stayed at 60, but the ball only got a new
## position every fifth frame, so it moved at 12 Hz inside a 60 Hz picture — which
## reads as lag, not as slowed time. It is the classic fixed-timestep answer, and
## it fits the rule this file lives by: interpolation is presentation, the
## simulation never sees it, and every recorded run is untouched.
##
## At 60 fps against the 60 Hz tick the two coincide and nothing changes. On a
## faster display it smooths normal play as well, which it did not before.
var _prev_ball := Vector2.ZERO
var _tick_alpha := 1.0

## Where the ball came apart and how long ago, or -1 for "it did not".
##
## Only a hazard gets this. A ball that fell out of the world is *gone* — it left
## the arena, and an explosion in mid-air below the floor would be a picture of
## something that did not happen. Falling out already has its own language: the red
## band along the open bottom edge.
var _boom_at := Vector2.ZERO
var _boom := -1.0

## Whether the ball is gone for this attempt.
##
## Separate from [member _boom] because the animation ends long before the attempt
## does: with only the timer, the ball reappeared where it had just been destroyed
## and sat there until the next try. It has to stay gone.
var _wrecked := false

## How long the window lasts, in simulated ticks, and how many physics frames one
## of those ticks is stretched over.
##
## 25 ticks is a bit over four tenths of a second of *board* time, stretched over
## five physics frames each into about two seconds of wall clock.
##
## It was 45 (nearly four seconds) and that was too generous — reported from play
## as making Level 13 "a tick too easy". The reason is structural: at a gate the
## board is already held still for the *placement*, so the slowed stretch afterwards
## only has to cover finding the key, not deciding anything. Two seconds is a grace
## period; four was a second chance.
const SLOW_TICKS := 25
const SLOW_FACTOR := 5

## Index of the magnet placed by the press we are still holding, or -1.
##
## Placing and drawing a path are one gesture: press puts the magnet down, release
## decides whether it stands still or shuttles along the line you dragged. A click
## is just a drag of length zero, so the simple case costs nothing.
var _dragging := -1
var _drag_to := Vector2.ZERO

## Shorter than this, a drag counts as a plain click.
const DRAG_MIN := 34.0

## The fixed on-screen window the board is drawn into. Everything right of it is
## the panel. It used to be implicit — the HUD sat at `arena.end.x + 30`, which
## only works while every board is exactly this size.
const VIEW := Rect2(0, 0, 900, 660)

## Where the board currently sits inside [constant VIEW], and how far out.
##
## Presentation only: the camera never reaches the simulation. While planning it
## pulls back far enough to show the whole board, because on a level larger than
## the window you cannot decide where a magnet goes if you cannot see the level.
## During a run it follows the ball at full size.
var _view_offset := Vector2.ZERO
var _view_scale := 1.0
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
	_prefix.clear()
	_resume_index = -1
	_reset()


func _reset() -> void:
	_leave_demo()
	running = false
	_rewind()
	_hint = _plan_hint()
	queue_redraw()


## Puts the world back to the start of the next attempt: tick 0, or the checkpoint
## the run resumes from, reached by replaying [member _prefix].
## Clears the wreck. Called wherever an attempt begins, so the pieces of the last
## one are never on the board during the next.
func _clear_boom() -> void:
	_boom = -1.0
	_wrecked = false


func _rewind() -> void:
	_clear_boom()
	world.setup(level, placed)
	recording.clear()
	_trail.clear()
	_placement_ticks = 0
	_slowed_index = world.slowmo_reached
	_slow_phase = 0
	_prev_ball = Vector2(world.ball_x, world.ball_y)
	_tick_alpha = 1.0
	for mask: int in _prefix:
		recording.append(mask)
		world.step(mask)
		_trail.append(Vector2(world.ball_x, world.ball_y))
		if _trail.size() > TRAIL_LENGTH:
			_trail.remove_at(0)
	# Gates crossed while replaying the prefix are old news — their window was
	# offered the first time through, and re-opening it here would stop the run at a
	# checkpoint the player has already dealt with.
	_armed_index = world.checkpoint_reached


func _plan_hint() -> String:
	if _resume_index >= 0:
		return "Checkpoint %d — Leertaste macht weiter, C fängt von vorn an." % (_resume_index + 1)
	return level.lesson


## Magnets the player may have on the board right now: the level's budget plus what
## every checkpoint reached so far has handed out.
##
## The grants are extra, not required — [method _start] still insists on the base
## budget, because that is what the level's proof assumes, but nothing forces a
## magnet to be spent at a checkpoint that does not need one.
func _budget_now() -> int:
	var total := level.budget
	# Gates crossed *in this run* count too, not just the one it started from —
	# otherwise the magnet a checkpoint just handed out would not fit in the budget
	# until the attempt was over, which is exactly the wait this is meant to remove.
	var reached: int = maxi(_resume_index, world.checkpoint_reached)
	for i in level.checkpoints.size():
		if i <= reached:
			total += (level.checkpoints[i] as SimLevel.Checkpoint).grants
	return total


func _start(playback: Array = []) -> void:
	if playback.is_empty():
		# Starting an attempt of your own — take the board back from the demo first,
		# so the budget check below counts the player's magnets and not its.
		_leave_demo()
		# Same rule as R: the space bar starts the *next* attempt, so it starts where
		# the last one got to. Before this, R and the space bar disagreed about where
		# that was.
		_carry_checkpoint()
	if placed.size() < level.budget:
		_hint = "Noch %d Magnet(e) zu setzen." % (level.budget - placed.size())
		return
	_playback = playback
	_rewind()
	running = true
	# The player's magnets, not every magnet in the world: a board with field
	# furniture would otherwise name a key that does not exist. Furniture answers to
	# no key at all.
	_hint = "Halte 1" if placed.size() == 1 else "Halte 1–%d" % placed.size()


# --- The tick ---------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not running:
		return

	# Slow motion is a *presentation* decision: fewer simulated ticks per second of
	# wall clock, never a smaller tick. The board still advances in whole ticks of
	# TICK_DELTA and still records one mask each, so the run stays reproducible and
	# replays at full speed to the same result.
	if _placement_ticks > 0:
		_slow_phase += 1
		if _slow_phase < SLOW_FACTOR:
			return
		_slow_phase = 0

	var mask := 0
	if _playback.is_empty():
		for i in world.magnets.size():
			if i < SimWorld.HOLD_KEYS and Input.is_key_pressed(KEY_1 + i):
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
	_prev_ball = Vector2(world.ball_x, world.ball_y)
	world.step(mask)
	_tick_alpha = 0.0

	_trail.append(Vector2(world.ball_x, world.ball_y))
	if _trail.size() > TRAIL_LENGTH:
		_trail.remove_at(0)

	# Time slows because the ball went through a place that says so — not because it
	# touched down, and not because a magnet was placed.
	if world.slowmo_reached > _slowed_index:
		_slowed_index = world.slowmo_reached
		_placement_ticks = _slow_ticks()
		_slow_phase = 0

	if _placement_ticks > 0:
		_placement_ticks -= 1
	elif not _demo and _playback.is_empty() and world.checkpoint_reached > _armed_index:
		_armed_index = world.checkpoint_reached
		_hint = "Magnet %d frei — setzen und halten" % _budget_now()


	if world.outcome == SimWorld.Outcome.WON:
		running = false
		# The demo does not play for a score. It won by replaying the level's own
		# answer, so counting it as a best time would hand the player a record they
		# never set — and one they then have to beat.
		if not _demo and (_best_ticks == 0 or world.tick_count < _best_ticks):
			_best_ticks = world.tick_count
		_hint = "Geschafft in %.2f s" % (float(world.tick_count) / SimWorld.TICK_HZ)
		# Kept so the build mode can take a won run as the board's proof. For a level
		# somebody drafted, this *is* the verification — a placement list plus one
		# bitmask per tick is exactly what `par_placements`/`par_holds` are, so a
		# board you beat once ships with a proven replay and no search is needed.
		# The demo is excluded for the same reason it does not set a best time: it
		# replayed an answer rather than finding one.
		if not _demo:
			won_placed = placed.duplicate()
			won_recording = recording.duplicate()
	elif world.outcome == SimWorld.Outcome.LOST:
		if world.hit_hazard:
			_boom_at = Vector2(world.ball_x, world.ball_y)
			_boom = 0.0
			_wrecked = true
			_trail.clear()
			_fall_back("Zerschellt")
		else:
			_fall_back("Danebengegangen")
	elif world.tick_count >= world.run_ticks:
		# The same horizon the offline runs use. Without it an attempt never ended:
		# a ball resting on the floor is neither won nor lost, so the clock just kept
		# counting and the game looked broken. Deliberately *not* a shorter number of
		# its own — a live timeout disagreeing with [member SimWorld.run_ticks]
		# would mean the game and the tests that certify its levels disagreed about
		# what a run is.
		_fall_back("Zeit abgelaufen")


## Ends a failed attempt.
func _fall_back(reason: String) -> void:
	running = false
	_carry_checkpoint()
	if _resume_index < 0:
		_hint = reason + " — R"
	else:
		_hint = "%s — R setzt dich an Checkpoint %d ab." % [reason, _resume_index + 1]


## Decides where the next attempt starts, given how this one ended.
##
## Called when an attempt is over — by defeat, by the clock, or because the player
## asked for the next one with R or the space bar. That last case is the one that
## was missing: banking used to happen only on a loss, so a player who watched the
## ball sail through a gate and then hit R landed back at tick 0 with the gate they
## had just passed forgotten. A checkpoint has to be earned by *reaching* it, not
## by dying after it.
##
## The cut is made on the *recording*, not on the world: everything up to the tick
## the gate was reached at stays exactly what was played, and the ticks after it
## are thrown away. What the player gets back is the run they actually made,
## stopped where it was still going well — not a reconstruction of it.
##
## A won attempt goes the other way. The journey is finished, so the next one
## starts at tick 0: R after a win means "again, for a cleaner time", not "again
## from a second before the goal". The magnets the gates handed out go back with
## it — they belonged to a journey that has ended, and keeping them would leave
## the board over its own budget.
func _carry_checkpoint() -> void:
	if _demo or level.checkpoints.is_empty():
		return
	if world.outcome == SimWorld.Outcome.WON:
		_forget_checkpoints()
		return
	if world.checkpoint_reached <= _resume_index:
		return
	_resume_index = world.checkpoint_reached
	var cut: int = world.checkpoint_ticks[_resume_index]
	_prefix.clear()
	for i in cut:
		_prefix.append(recording[i])


## Back to the start of the level: no prefix, and none of the magnets a gate
## handed out.
func _forget_checkpoints() -> void:
	for i in range(placed.size() - 1, -1, -1):
		if (placed[i] as SimLevel.MagnetSpec).spawn_tick > 0:
			placed.remove_at(i)
	_prefix.clear()
	_resume_index = -1


func _process(delta: float) -> void:
	_advance_alpha(delta)
	# Wall clock, not ticks. The run is over by the time this runs, so there is no
	# simulation left for it to disagree with.
	if _boom >= 0.0:
		_boom += delta
		if _boom > BoardArt.BOOM_SECONDS:
			_boom = -1.0
	_follow(delta)
	queue_redraw()


## Moves the drawn moment forward inside the current tick.
##
## One tick lasts [constant SimWorld.TICK_DELTA] of wall clock normally and
## [constant SLOW_FACTOR] times that in slow motion, which is the whole trick: the
## simulation keeps its fixed step and only the *stretch of real time* it is drawn
## across changes.
func _advance_alpha(delta: float) -> void:
	if not running:
		# Nothing is being simulated, so the drawn moment is simply the current one.
		_tick_alpha = 1.0
		return
	var per_tick := SimWorld.TICK_DELTA
	if _placement_ticks > 0:
		per_tick *= float(SLOW_FACTOR)
	_tick_alpha = minf(1.0, _tick_alpha + delta / per_tick)


## Where the ball is drawn: between the last two simulated positions.
func _drawn_ball() -> Vector2:
	return _prev_ball.lerp(Vector2(world.ball_x, world.ball_y), _tick_alpha)


## Eases the view toward where it should be.
##
## Frame-rate independent on purpose: a fixed lerp factor would make the camera
## snappier on a fast machine, and this is the one place where "looks different on
## another PC" would be a real bug rather than a cosmetic one.
func _follow(delta: float) -> void:
	if level == null:
		return
	var want_scale := 1.0
	var focus := _drawn_ball()
	if not running:
		# Pull back to fit the whole board, but never magnify a small one.
		want_scale = minf(
			1.0,
			minf(VIEW.size.x / level.arena.size.x, VIEW.size.y / level.arena.size.y)
		)
		focus = level.arena.get_center()

	var want_offset := _clamped_offset(focus, want_scale)
	var ease := 1.0 - pow(0.0015, delta)
	_view_scale = lerpf(_view_scale, want_scale, ease)
	_view_offset = _view_offset.lerp(want_offset, ease)


## The offset that puts [param focus] in the middle of the view, held so the board
## never pulls away from an edge and shows blank space behind it.
func _clamped_offset(focus: Vector2, scale: float) -> Vector2:
	var out := VIEW.get_center() - focus * scale
	var span := level.arena.size * scale
	if span.x <= VIEW.size.x:
		out.x = VIEW.get_center().x - (level.arena.position.x + level.arena.size.x * 0.5) * scale
	else:
		out.x = clampf(
			out.x,
			VIEW.end.x - level.arena.end.x * scale,
			VIEW.position.x - level.arena.position.x * scale
		)
	if span.y <= VIEW.size.y:
		out.y = VIEW.get_center().y - (level.arena.position.y + level.arena.size.y * 0.5) * scale
	else:
		out.y = clampf(
			out.y,
			VIEW.end.y - level.arena.end.y * scale,
			VIEW.position.y - level.arena.position.y * scale
		)
	return out


## Screen point (local to this node) to a point on the board.
func _to_board(at: Vector2) -> Vector2:
	return (at - _view_offset) / _view_scale


# --- Input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	# Mid-flight placement. Never a freeze: the board keeps running, and a level that
	# wants the player to have time says so with a slow-motion point.
	if event is InputEventMouseButton and event.pressed and running and _can_place_live():
		var click_live := event as InputEventMouseButton
		if click_live.button_index == MOUSE_BUTTON_LEFT:
			_place_live(_to_board((make_input_local(click_live) as InputEventMouseButton).position))
		return

	if event is InputEventMouseButton and event.pressed and not running:
		var click := (event as InputEventMouseButton)
		# The click's own position, not [method Node2D.get_local_mouse_position].
		# Re-reading the cursor asks a second source where the click happened, and
		# the two can disagree — which also made the placement path impossible to
		# drive from a test, since a synthetic event moves no real cursor.
		var at := _to_board((make_input_local(click) as InputEventMouseButton).position)
		if click.button_index == MOUSE_BUTTON_LEFT:
			_place(at)
			_dragging = placed.size() - 1 if level.paths_enabled else -1
			_drag_to = at
		elif click.button_index == MOUSE_BUTTON_RIGHT:
			_erase(at)
		return

	# Release: turn the drag into the magnet's path.
	if event is InputEventMouseButton and not event.pressed and _dragging >= 0:
		var up := _to_board((make_input_local(event) as InputEventMouseButton).position)
		_finish_path(up)
		return

	if event is InputEventMouseMotion and _dragging >= 0:
		_drag_to = _to_board((make_input_local(event) as InputEventMouseMotion).position)
		queue_redraw()
		return

	if not (event is InputEventKey and event.pressed and not event.is_echo()):
		return
	match (event as InputEventKey).keycode:
		KEY_SPACE:
			if not running:
				_start()
		KEY_R:
			_carry_checkpoint()
			_reset()
		KEY_C:
			# The whole level again, from tick 0, with an empty board — the way out of
			# a checkpoint you have reached but no longer want to start from.
			placed.clear()
			_forget_checkpoints()
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
					_player_prefix.assign(_prefix)
					_player_resume = _resume_index
					_demo = true
				placed = _par_placements()
				# The par is a schedule from tick 0, so the demo always plays the whole
				# level. The player's own checkpoint stands aside with their magnets.
				_prefix.clear()
				_resume_index = -1
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
	_prefix.assign(_player_prefix)
	_resume_index = _player_resume
	_player_placed = []
	_player_prefix.clear()
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


## Whether a magnet at [param at] would sit in a wall or within a ball's width of
## one — a box or a polygon alike.
##
## One question for both placement paths, before a run and during one. They each
## had their own loop over the boxes, and a wall shape added to one and not the
## other is exactly how a magnet ends up buried at a checkpoint and nowhere else.
##
## Presentation-side, so it may lean on [Geometry2D]: a magnet is not a collider,
## and a pixel's disagreement with [SimWorld] about the rim of a wall moves nothing.
func _in_wall(at: Vector2) -> bool:
	for solid: Rect2 in level.solids:
		if solid.grow(SimWorld.BALL_RADIUS).has_point(at):
			return true
	for points: PackedVector2Array in level.polygons:
		if Geometry2D.is_point_in_polygon(at, points):
			return true
		var last := points.size() - 1
		for i in points.size():
			var near := Geometry2D.get_closest_point_to_segment(at, points[last], points[i])
			if near.distance_to(at) < SimWorld.BALL_RADIUS:
				return true
			last = i
	return false


func _place(at: Vector2) -> void:
	_leave_demo()
	if placed.size() >= _budget_now():
		_hint = "Budget voll — Rechtsklick entfernt."
		return
	if not level.arena.has_point(at):
		return
	if _in_wall(at):
		_hint = "Nicht in eine Wand."
		return
	for mover: SimLevel.MoverSpec in level.movers:
		# The whole corridor, not just where the platform stands right now: a magnet
		# placed in its path would be buried for half of every cycle.
		if mover.swept_rect().grow(SimWorld.BALL_RADIUS).has_point(at):
			_hint = "Nicht in den Weg der Plattform."
			return
	# Born at the tick the attempt resumes from, so it takes no part in the ticks
	# that are already played — see [member SimLevel.MagnetSpec.spawn_tick].
	placed.append(SimLevel.MagnetSpec.new(
		at.x, at.y, attract_tool, false, Vector2.ZERO, 1, false, _prefix.size()
	))
	_reset()


## Places a magnet into the run in progress, during a checkpoint's window.
##
## Born at the current tick, so the ticks already played stay exactly what they
## were — the same guarantee a magnet placed between attempts gets, for the same
## reason. The world is told about it directly *and* it goes into [member placed],
## so rebuilding the world from that list later (which is what R does) reproduces
## this run rather than a different one.
func _place_live(at: Vector2) -> void:
	if not _can_place_live() or not level.arena.has_point(at):
		return
	if _in_wall(at):
		return
	for mover: SimLevel.MoverSpec in level.movers:
		if mover.swept_rect().grow(SimWorld.BALL_RADIUS).has_point(at):
			return
	var spec := SimLevel.MagnetSpec.new(
		roundf(at.x), roundf(at.y), attract_tool, false,
		Vector2.ZERO, 1, false, world.tick_count
	)
	placed.append(spec)
	world.add_magnet(spec)
	# Released into slow motion, not straight back to full speed: the *timing* of
	# the new magnet is the second half of this decision, and at full speed the ball
	# would be over the void before a finger could find the key.
	_hint = "Halte %d" % placed.size()


## How long slowed time lasts on this board.
func _slow_ticks() -> int:
	return level.slowmo_ticks if level.slowmo_ticks > 0 else SLOW_TICKS


## The key range this board can reach — its budget plus everything its gates hand
## out, which on a journey board is five or six and used to be hard-coded as four.
func _keys_line() -> String:
	var most := level.budget
	for cp: SimLevel.Checkpoint in level.checkpoints:
		most += cp.grants
	most = mini(most, SimWorld.HOLD_KEYS)
	if most <= 1:
		return "1 halten  Magnet wirkt"
	return "1–%d halten  Magnet wirkt" % most


## Whether a magnet earned at a gate is still waiting to be spent.
func _can_place_live() -> bool:
	return not _demo and _playback.is_empty() and placed.size() < _budget_now()


func _erase(at: Vector2) -> void:
	_leave_demo()
	for i in range(placed.size() - 1, -1, -1):
		var spec: SimLevel.MagnetSpec = placed[i]
		if Vector2(spec.x, spec.y).distance_to(at) < 34.0:
			if spec.spawn_tick < _prefix.size():
				# Removing it would change ticks that have already been played, and the
				# ball would arrive at the checkpoint somewhere else entirely — or not
				# at all. C starts the level over if that is what you want.
				_hint = "Der Magnet gehört zu einem gelaufenen Abschnitt — C fängt von vorn an."
				queue_redraw()
				return
			placed.remove_at(i)
			_reset()
			return


# --- Drawing ----------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(-4000, -4000, 8000, 8000), PolarisTheme.BG, true)
	if level == null:
		return

	# Set here rather than once on load, so it cannot go stale — a level reaches this
	# screen by more than one route, and the build mode changes a draft's world while
	# it is open. It returns immediately when nothing changed.
	PolarisTheme.use(level.theme)

	# Seconds since start, for the animated bits. It reaches the art layer only;
	# [SimWorld] never sees a clock, which is what keeps runs reproducible.
	var t := Time.get_ticks_msec() / 1000.0

	draw_set_transform(_view_offset, 0.0, Vector2(_view_scale, _view_scale))

	# What of the board the view currently covers, in board coordinates.
	var seen := Rect2(_to_board(VIEW.position), VIEW.size / _view_scale)
	BoardArt.draw_background(self, level.arena, seen, t)
	BoardArt.draw_frame(self, level.arena)
	# Behind the walls, in front of the background: the shaft's sides should read as
	# containing the zone, not floating on it.
	for zone: SimLevel.GravitySpec in level.zones:
		BoardArt.draw_gravity_zone(
			self, zone.rect, zone.pulls_up_at(world.tick_count),
			_smooth_progress(zone)
		)
	BoardArt.draw_target(self, level.target, t)
	for i in level.checkpoints.size():
		var cp: SimLevel.Checkpoint = level.checkpoints[i]
		var passed := i < world.checkpoint_ticks.size() and world.checkpoint_ticks[i] >= 0
		BoardArt.draw_checkpoint(self, cp.rect, passed, t, _view_scale)
	for solid: Rect2 in level.solids:
		BoardArt.draw_solid(self, solid, PolarisTheme.world().wall_edge)
	for points: PackedVector2Array in level.polygons:
		BoardArt.draw_polygon_wall(self, points, PolarisTheme.world().wall_edge)
	# After the walls: spikes sit *on* geometry, and drawn under it a strip on a
	# floor would lose its teeth to the floor's own lit cap.
	for hazard: Rect2 in level.hazards:
		BoardArt.draw_hazard(self, hazard, t)
	for spring: SimLevel.BounceSpec in level.springs:
		BoardArt.draw_spring(self, spring.rect, spring.push, t)

	_draw_movers()
	_draw_magnets()
	if _dragging >= 0 and _dragging < placed.size():
		var von: SimLevel.MagnetSpec = placed[_dragging]
		draw_line(Vector2(von.x, von.y), _drag_to, Color(PolarisTheme.ACCENT, 0.6), 2.0)
	# The ball is not drawn while it is coming apart: the pieces *are* the ball, and
	# leaving the sphere sitting among them reads as a bug rather than as an impact.
	if _wrecked:
		if _boom >= 0.0:
			BoardArt.draw_explosion(self, _boom_at, _boom / BoardArt.BOOM_SECONDS)
	else:
		BoardArt.draw_ball(self, _drawn_ball(), SimWorld.BALL_RADIUS, _trail)
	if running and _can_place_live():
		# The cursor is read straight from the mouse here, not from an event. That is
		# fine and only here: this draws a ghost, it never decides where a magnet
		# goes — the click's own position still does that.
		BoardArt.draw_placement_window(
			self, _drawn_ball(),
			_to_board(get_local_mouse_position()), attract_tool,
			float(_placement_ticks) / float(_slow_ticks()),
			SimWorld.MAGNET_RADIUS, world.lift_radius(), t
		)
	BoardArt.draw_vignette(self, level.arena)

	# Back to screen space, then mask everything outside the view. `draw_set_transform`
	# moves geometry but clips nothing, so without this the board would spill across
	# the panel on any level wider than the window.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var far := 4000.0
	draw_rect(Rect2(VIEW.end.x, -far, far, far * 2.0), PolarisTheme.BG, true)
	draw_rect(Rect2(-far, -far, far + VIEW.position.x, far * 2.0), PolarisTheme.BG, true)
	draw_rect(Rect2(-far, -far, far * 2.0, far + VIEW.position.y), PolarisTheme.BG, true)
	draw_rect(Rect2(-far, VIEW.end.y, far * 2.0, far), PolarisTheme.BG, true)
	if _placement_ticks > 0:
		BoardArt.draw_time_state(
			self, VIEW, float(_placement_ticks) / float(_slow_ticks()), false, t
		)
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
		if _tick_alpha < 1.0:
			rect.position = mover.rect_at(world.tick_count - 1).position.lerp(
				rect.position, _tick_alpha
			)
		BoardArt.draw_solid(self, rect, PolarisTheme.OK)


func _draw_magnets() -> void:
	var t := Time.get_ticks_msec() / 1000.0
	var all := level.magnets_for(placed)
	var last_mask: int = recording[recording.size() - 1] if recording.size() > 0 else 0
	var reversed_now := running and (last_mask & SimWorld.INVERT_BIT) != 0
	var ball := _drawn_ball()

	for i in all.size():
		var spec: SimLevel.MagnetSpec = all[i]
		var pos := spec.position_at(world.tick_count)
		if spec.moves() and _tick_alpha < 1.0:
			pos = spec.position_at(world.tick_count - 1).lerp(pos, _tick_alpha)
		if spec.moves():
			# The whole line, not just where the magnet is now. The plan *is* the
			# line; hiding it would leave the player nothing to aim with.
			var ende := Vector2(spec.x + spec.travel.x, spec.y + spec.travel.y)
			draw_line(Vector2(spec.x, spec.y), ende, Color(PolarisTheme.INK_DIM, 0.45), 2.0)
			draw_circle(Vector2(spec.x, spec.y), 4.0, Color(PolarisTheme.INK_DIM, 0.7))
			draw_circle(ende, 4.0, Color(PolarisTheme.INK_DIM, 0.7))

		# The level's own field: always acting, never keyed, and never reversed by the
		# player's Shift — it is not theirs to turn around.
		var furniture := spec.always_on
		var acting_attract := spec.attract if furniture else (spec.attract != reversed_now)
		var charge: float = world.charges[i] if i < world.charges.size() else level.charge_seconds
		var held := furniture or (running and (last_mask & (1 << i)) != 0)
		var spent := (not furniture) and charge <= 0.0

		# The lift ring follows whichever strength this magnet actually runs on. A
		# foreign field drawn with the player's radius would tell the same lie the
		# ring was added to prevent.
		BoardArt.draw_magnet(
			self, pos, acting_attract, held, spent, t, SimWorld.MAGNET_RADIUS,
			world.field_lift_radius() if furniture else world.lift_radius()
		)
		if held and not spent and pos.distance_to(ball) < SimWorld.MAGNET_RADIUS:
			BoardArt.draw_pull(self, pos, ball, acting_attract, t)

		if furniture:
			# No number and no charge meter: neither would mean anything for a field
			# the player cannot switch, and a number would imply a key that does not
			# exist.
			continue
		if charge > 0.0:
			draw_arc(
				pos, 30.0, -PI / 2.0,
				-PI / 2.0 + TAU * (charge / level.charge_seconds),
				32, PolarisTheme.ACCENT, 4.0, true
			)
		_label(
			str(i + 1),
			pos + Vector2(-5, 6),
			PolarisTheme.BG if charge > 0.0 else PolarisTheme.INK_DIM,
			17
		)


func _draw_hud() -> void:
	var x := VIEW.end.x + 30.0
	if _placement_ticks <= 0:
		_label(
			"LEVEL %d · %s" % [level.id, level.title.to_upper()],
			Vector2(x, 46), PolarisTheme.INK_DIM, 13
		)
	if _placement_ticks > 0:
		_label("ZEITLUPE", Vector2(x, 46), PolarisTheme.ACCENT, 13)
	var wrapped := _wrap(_hint, 34)
	for i in wrapped.size():
		_label(wrapped[i], Vector2(x, 82 + i * 20), PolarisTheme.INK, 14)

	if level.budget > 0:
		var tool_name := "Anziehen" if attract_tool else "Abstoßen"
		var tool_color: Color = PolarisTheme.PLUS if attract_tool else PolarisTheme.MINUS
		_label(
			"%s  (Tab) · %d/%d gesetzt" % [tool_name, placed.size(), _budget_now()],
			Vector2(x, 150), tool_color, 14
		)

	if not level.checkpoints.is_empty():
		var where := (
			"Start" if _resume_index < 0
			else "Checkpoint %d/%d" % [_resume_index + 1, level.checkpoints.size()]
		)
		_label(
			"Abschnitt ab %s" % where,
			Vector2(x, 172),
			PolarisTheme.OK if _resume_index >= 0 else PolarisTheme.INK_DIM,
			14
		)

	if level.flip_enabled:
		var flipping := (
			running
			and recording.size() > 0
			and (recording[recording.size() - 1] & SimWorld.INVERT_BIT) != 0
		)
		_label(
			"UMGEPOLT" if flipping else "Shift kehrt um",
			Vector2(x, 172 if level.checkpoints.is_empty() else 192),
			PolarisTheme.ACCENT if flipping else PolarisTheme.INK_DIM,
			14
		)

	var keys := [
		"Leertaste  starten",
		_keys_line(),
		"R  neuer Versuch",
		"P  Musterlauf ansehen",
		"Esc  zurück",
	]
	if not level.checkpoints.is_empty():
		keys[2] = "R  ab dem Checkpoint"
		keys.insert(3, "C  ganz von vorn")
		keys.push_front("Im Lauf  Linksklick setzt den freien Magneten")
	if level.flip_enabled:
		keys.insert(2, "Shift halten  Polarität umkehren")
	if level.paths_enabled:
		keys.push_front("Ziehen  Bahn für den Magneten")
	if level.budget > 0:
		keys.push_front("Rechtsklick  entfernen")
		keys.push_front("Linksklick  Magnet setzen")
	var keys_top := 196.0 if level.checkpoints.is_empty() else 216.0
	for i in keys.size():
		_label(keys[i], Vector2(x, keys_top + i * 22), PolarisTheme.INK_DIM, 13)

	# Below the key list rather than at a fixed 400. That list grows with what the
	# board offers — gates alone add three lines — and on Level 15 the clock landed
	# on top of "P Musterlauf ansehen".
	var clock_y: float = maxf(400.0, keys_top + float(keys.size()) * 22.0 + 26.0)
	_label(
		"%.2f s" % (float(world.tick_count) / SimWorld.TICK_HZ),
		Vector2(x, clock_y), PolarisTheme.ACCENT, 30
	)
	if _best_ticks > 0:
		_label(
			"Bestzeit %.2f s" % (float(_best_ticks) / SimWorld.TICK_HZ),
			Vector2(x, clock_y + 36.0), PolarisTheme.OK, 14
		)


## A gravity zone's phase, carried smoothly across the frames inside one tick.
##
## The ramp restarts at every flip, so interpolating across that boundary would run
## the arrows backwards for a frame. At the restart the current value is used
## as-is — which is exactly where [method BoardArt.zone_offset] has zero slope
## anyway, so nothing jumps.
func _smooth_progress(zone: SimLevel.GravitySpec) -> float:
	var now := zone.progress_at(world.tick_count)
	if _tick_alpha >= 1.0:
		return now
	var before := zone.progress_at(world.tick_count - 1)
	if now < before:
		return now
	return lerpf(before, now, _tick_alpha)


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
