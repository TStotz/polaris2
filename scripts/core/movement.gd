@tool
class_name Movement
extends RefCounted

## THE single source of truth for the movement rules (Modell A).
##
## The live game, the [Solver] and the [PuzzleGenerator] all call these exact
## functions. Keep them pure and integer-only: no float math, no randomness, no
## engine state. That is what makes a run reproducible on every machine.
##
## [b]Coordinates[/b]: a cell is a [Vector2i] with **x = row, y = col**. That
## order matches the original Dart `Position(row, col)`, so this port and the
## reference implementation read line for line the same — and `print(cell)`
## produces the same `(row, col)` text. Only the rendering layer
## ([BoardView]) flips it into x/y pixels.
##
## Rules:
##  - A magnet only acts when the ball shares its row OR column (never diagonal).
##  - [b]Reach[/b] (field radius): the magnet only grabs the ball if it is within
##    `reach` cells along that line *and* no wall blocks the straight line
##    between them ([method Puzzle.blocks_reach]); otherwise no effect. Reach is
##    [member Magnet.reach] or [member Puzzle.magnet_reach] and is always finite.
##  - The ball then slides — towards a PLUS (attract) or away from a MINUS
##    (repel) — and stops at the last free cell before a blocker (wall, board
##    edge, or any magnet — magnets are solid). Stopping before the acting magnet
##    is what "parks directly next to it" means for PLUS.
##  - [b]Strength[/b] (push/pull distance): caps how many cells the ball travels,
##    [member Magnet.strength] or [member Puzzle.magnet_strength]
##    ([constant Puzzle.UNLIMITED] = uncapped). Reach and strength are independent.
##  - A [b]deflector[/b] tile turns the slide 90°; the ball keeps going along the
##    new direction. The path is therefore a polyline, but every turn is
##    integer-exact, so the resting cell is still fully computable.
##  - A [b]closed gate[/b] is a wall: it stops the slide and cuts off the field.
##    Which gates are shut is not part of the board — it is the run's
##    [param gate_mask], a bitmask of the channels toggled so far, passed in by
##    the caller. Keeping it an argument rather than mutable puzzle state is what
##    lets one activation be evaluated against exactly one board.
##  - Ball not in line, out of reach, or field blocked -> no movement.

## The four orthogonal steps, as (dr, dc).
const DIRECTIONS: Array[Vector2i] = [
	Vector2i(-1, 0),
	Vector2i(1, 0),
	Vector2i(0, -1),
	Vector2i(0, 1),
]


## Whether [param cell] lies on the straight slide from [param from] to
## [param to], endpoints included. Each activation moves the ball along a single
## row or column, so the ball touches exactly the cells on this segment — the
## basis for collecting a waypoint by either stopping on it or sliding through it.
static func on_ball_path(cell: Vector2i, from: Vector2i, to: Vector2i) -> bool:
	if from.x == to.x and cell.x == from.x:
		return cell.y >= mini(from.y, to.y) and cell.y <= maxi(from.y, to.y)
	if from.y == to.y and cell.y == from.y:
		return cell.x >= mini(from.x, to.x) and cell.x <= maxi(from.x, to.x)
	return false


## Where the ball comes to rest after one activation.
static func activate(
	ball: Vector2i, magnet: Magnet, magnets: Array, puzzle: Puzzle, gate_mask: int = 0
) -> Vector2i:
	return _slide(ball, magnet, magnets, puzzle, null, {}, gate_mask)


## The full ordered list of cells the ball travels through for this activation,
## from [param ball] (inclusive) to its resting cell (inclusive), turning at
## deflectors. `[ball]` alone when it does not move. This is what waypoint
## collection must use, since a deflected path is not a straight segment.
static func slide_path(
	ball: Vector2i, magnet: Magnet, magnets: Array, puzzle: Puzzle, gate_mask: int = 0
) -> Array:
	var trace: Array = []
	_slide(ball, magnet, magnets, puzzle, trace, {}, gate_mask)
	return trace


## The cells [param magnet]'s field covers, each with the step `(dr, dc)` a ball
## resting there would take when the magnet fires: **towards** a PLUS, **away**
## from a MINUS. Entries are `{"cell": Vector2i, "step": Vector2i}`.
##
## This is the magnet's area of effect, derived from the very same reach rule
## [method activate] applies: at most `reach` cells along each row/column
## direction, and a wall ([method Puzzle.blocks_reach]) cuts the field off beyond
## it. It describes only the *first* step — where the ball ends up also depends
## on strength, deflectors and blockers — so showing it teaches the rule without
## giving the puzzle's answer away.
static func magnet_field(magnet: Magnet, puzzle: Puzzle, gate_mask: int = 0) -> Array:
	var reach := magnet.reach if magnet.reach != Magnet.INHERIT else puzzle.magnet_reach
	var field: Array = []

	for step: Vector2i in DIRECTIONS:
		for k in range(1, reach + 1):
			var cell := magnet.pos + step * k
			if not puzzle.in_bounds(cell):
				break
			# A wall can't hold a ball and blocks the field for everything behind it.
			if puzzle.blocks_reach(cell, magnet.type, gate_mask):
				break
			# Outward from the magnet is `step`; a PLUS pulls the ball back along it.
			field.append({"cell": cell, "step": -step if magnet.is_plus() else step})
	return field


## Applies one activation of [param magnet] to **every** ball, returning the new
## positions index-aligned with [param balls]. This is the multi-ball rule: all
## balls on the magnet's line (within reach) slide at once, and balls are solid —
## so they stack up deterministically. The ball furthest along the slide
## direction settles first; the rest stop behind it. Balls not in line stay put
## but still block, exactly like a wall or magnet.
##
## Reuses the same slide as the single-ball [method activate], so the movement
## rules (reach, strength, deflectors, cycle guard) stay identical — the only
## addition is that other balls count as blockers.
static func activate_all(
	balls: Array, magnet: Magnet, magnets: Array, puzzle: Puzzle, gate_mask: int = 0
) -> Array:
	return _resolve_all(balls, magnet, magnets, puzzle, null, gate_mask)


## Like [method activate_all], but returns the full path each ball travelled
## (start included), index-aligned with [param balls]. Needed for waypoint
## collection and animation, since a ball may cross several cells (and bend at
## deflectors) on its way to rest.
static func activate_all_paths(
	balls: Array, magnet: Magnet, magnets: Array, puzzle: Puzzle, gate_mask: int = 0
) -> Array:
	var paths: Array = []
	paths.resize(balls.size())
	_resolve_all(balls, magnet, magnets, puzzle, paths, gate_mask)
	return paths


## Shared core for [method activate_all] / [method activate_all_paths]. Resolves
## every ball front-to-back along its own travel direction, so the ball nearest
## the stopping edge settles first and the rest stack behind it (other balls are
## solid blockers). When [param out_paths] is non-null, each ball's traced path
## is stored into it.
static func _resolve_all(
	balls: Array,
	magnet: Magnet,
	magnets: Array,
	puzzle: Puzzle,
	out_paths: Variant,
	gate_mask: int = 0,
) -> Array:
	var result := balls.duplicate()
	var occupied := {}
	for b: Vector2i in balls:
		occupied[b] = true

	# Order by how far along its own travel direction each ball already sits, so
	# the leading ball settles first and the others stack up behind it.
	var projections: Array[int] = []
	for i in balls.size():
		var step := _travel_step(balls[i], magnet)
		projections.append(balls[i].x * step.x + balls[i].y * step.y)

	var order: Array[int] = []
	for i in balls.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return projections[a] > projections[b])

	for i: int in order:
		occupied.erase(result[i])
		var trace: Variant = null if out_paths == null else []
		result[i] = _slide(result[i], magnet, magnets, puzzle, trace, occupied, gate_mask)
		if out_paths != null:
			out_paths[i] = trace
		occupied[result[i]] = true
	return result


## The step a ball would take on this activation: toward a PLUS, away from a
## MINUS, or `(0, 0)` when the ball is not in the magnet's line. Used only to
## order simultaneous balls; the actual slide recomputes it in [method _slide].
static func _travel_step(ball: Vector2i, magnet: Magnet) -> Vector2i:
	var dr := 0
	var dc := 0
	if ball.x == magnet.pos.x and ball.y != magnet.pos.y:
		dc = 1 if magnet.pos.y > ball.y else -1
	elif ball.y == magnet.pos.y and ball.x != magnet.pos.x:
		dr = 1 if magnet.pos.x > ball.x else -1
	else:
		return Vector2i.ZERO
	var step := Vector2i(dr, dc)
	return -step if magnet.is_minus() else step


## 90° turn of a step `(dr, dc)` on entering a deflector of [param dir].
static func _deflect(dir: int, step: Vector2i) -> Vector2i:
	if dir == Deflector.Dir.BACKSLASH:
		return Vector2i(step.y, step.x)
	return Vector2i(-step.y, -step.x)


## Compact id for one of the four orthogonal steps, for cycle keys.
static func _dir_index(step: Vector2i) -> int:
	if step.x == -1:
		return 0
	if step.x == 1:
		return 1
	return 2 if step.y == -1 else 3


## Core slide. When [param trace] is a non-null Array, every visited cell is
## appended to it. [param occupied] holds other balls, which are solid blockers
## for the slide (but do not block the magnet's field — only walls do). Empty for
## a single-ball move.
static func _slide(
	ball: Vector2i,
	magnet: Magnet,
	magnets: Array,
	puzzle: Puzzle,
	trace: Variant,
	occupied: Dictionary = {},
	gate_mask: int = 0,
) -> Vector2i:
	if trace != null:
		trace.append(ball)

	var same_row := ball.x == magnet.pos.x
	var same_col := ball.y == magnet.pos.y
	if not same_row and not same_col:
		return ball  # not in line -> no effect
	if ball == magnet.pos:
		return ball  # ball already on the magnet cell

	# Step towards the magnet (used both to measure reach and as the PLUS
	# direction; MINUS reverses it below).
	var toward := Vector2i.ZERO
	if same_row:
		toward.y = 1 if magnet.pos.y > ball.y else -1
	else:
		toward.x = 1 if magnet.pos.x > ball.x else -1

	# REACH gate: the magnet only grabs the ball if it sits within `reach` cells
	# along the straight line, with no wall blocking the field on the way. A
	# per-magnet reach wins; otherwise the puzzle-wide value. Reach is always
	# finite, so this gate always applies.
	var reach := magnet.reach if magnet.reach != Magnet.INHERIT else puzzle.magnet_reach
	var probe := ball
	var within := false
	for _k in reach:
		probe += toward
		if probe == magnet.pos:
			within = true
			break
		if puzzle.blocks_reach(probe, magnet.type, gate_mask):
			break  # field blocked
	if not within:
		return ball  # too far or blocked -> no effect

	# Slide direction: towards a PLUS, away from a MINUS.
	var step := -toward if magnet.is_minus() else toward

	# STRENGTH: how many cells the ball travels. A per-magnet strength wins;
	# otherwise the puzzle-wide cap ([constant Puzzle.UNLIMITED] = uncapped).
	var strength := magnet.strength if magnet.strength != Magnet.INHERIT else puzzle.magnet_strength
	var visited := {}
	var cur := ball
	var moved := 0

	while true:
		var next := cur + step
		if _blocked(next, puzzle, magnets, occupied, gate_mask):
			return cur  # can't advance -> rest here
		cur = next
		if trace != null:
			trace.append(cur)
		moved += 1
		if strength != Puzzle.UNLIMITED and moved >= strength:
			return cur  # strength cap

		var dir := puzzle.deflector_at(cur)
		if dir != Deflector.NONE:
			step = _deflect(dir, step)

		# A repeated (cell, direction) means the ball loops forever between
		# deflectors and never rests -> treat the activation as no movement.
		var key := (cur.x * puzzle.size + cur.y) * 4 + _dir_index(step)
		if visited.has(key):
			if trace != null:
				trace.clear()
				trace.append(ball)
			return ball
		visited[key] = true

	return cur  # unreachable; the loop only exits by returning


## Element-wise comparison of two index-aligned position lists — the "did any
## ball move?" check shared by the game, the solver and the generator.
static func same_positions(a: Array, b: Array) -> bool:
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


## A cell blocks the ball if it is off-board, a wall, holds another ball, or
## holds a magnet (the acting magnet included — that is how PLUS parks directly
## next to it).
static func _blocked(
	cell: Vector2i, puzzle: Puzzle, magnets: Array, occupied: Dictionary, gate_mask: int = 0
) -> bool:
	if not puzzle.in_bounds(cell):
		return true
	# A shut gate is a wall for as long as it is shut.
	if puzzle.blocks_ball(cell, gate_mask):
		return true
	if occupied.has(cell):
		return true  # another ball is solid
	for m: Magnet in magnets:
		if m.pos == cell:
			return true
	return false
