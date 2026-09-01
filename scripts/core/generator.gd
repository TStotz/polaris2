@tool
class_name PuzzleGenerator
extends RefCounted

## Random puzzle generator.
##
## Mirrors the content pipeline **construct -> solve -> verify**, then a
## **difficulty filter** that keeps only puzzles whose solution is genuinely hard
## to *find*:
##  1. Construct a config by a wandering *chain* of stepping-stone magnets on a
##     wall-dense board — solvable by construction, and (with finite range +
##     single-use) needing a chain of several magnets.
##  2. Solve to get the true minimal magnet count; keep only the requested
##     [enum Difficulty.Band] band.
##  3. Optionally add *detour waypoints*: gems dropped on visited cells that the
##     bare solution skips, so collecting them strictly raises the magnet count.
##  4. Filter for findability: optionally require a non-monotone solution,
##     tighten the budget to exactly what the solution uses, then keep only
##     candidates with at most `max_solutions` distinct minimal solutions.
##  5. Verify by replay — reach the target collecting every waypoint.
##
## Generation is deliberately expensive (most candidates are rejected). Run it
## off the main thread — see [GenerationWorker] — or bake a level pack ahead of
## time rather than calling this during play.

var _rng := RandomNumberGenerator.new()



func _init(seed_value: int = 0) -> void:
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()


## Returns a hard-to-solve puzzle of the requested [param difficulty] as
## `{"puzzle": Puzzle, "solution": Solution, "solution_count": int}`, or null if
## none was found within [param tries].
##
## [param tries] defaults high because the scarcity + detour filters reject most
## candidates (a deliberately hard puzzle is rare); easier bands still return
## after a handful of tries, so the high cap costs them nothing.
func generate(
	difficulty: Difficulty.Band = Difficulty.Band.MEDIUM,
	size: int = 6,
	max_runs: int = 5,
	plus_budget: int = 3,
	minus_budget: int = 3,
	waypoints: int = 0,
	deflectors: int = 0,
	balls: int = 1,
	tries: int = 15000,
) -> Variant:
	# Multiple balls use a construction path of their own (below); the tuned
	# single-ball pipeline stays untouched.
	if balls > 1:
		return _generate_multi_ball(
			difficulty, size, max_runs, balls, deflectors, waypoints, tries
		)

	var params := Difficulty.params(difficulty)

	for _t in tries:
		var candidate: Variant = _construct(difficulty, size, max_runs, plus_budget, minus_budget)
		if candidate == null:
			continue
		var base: Puzzle = candidate["puzzle"]
		var touched: Array = candidate["touched"]

		# Sprinkle deflectors onto cells the ball crossed, then re-solve the new
		# board from scratch. They are kept only if a solution still exists and
		# actually routes through one (otherwise they'd be inert decoration).
		if deflectors > 0:
			var placed: Variant = _pick_deflectors(touched, deflectors)
			if placed == null:
				continue  # not enough room
			base = base.with_overrides({"deflectors": placed})
			var remaining: Array = []
			for c: Vector2i in touched:
				if not (placed as Dictionary).has(c):
					remaining.append(c)
			touched = remaining

		# Solve the bare board (no waypoints) for the baseline difficulty.
		var base_solution := Solver.new(base).solve()
		if base_solution == null:
			continue
		if deflectors > 0 and not _uses_deflector(base, base_solution):
			continue

		# Add detour waypoints: drop them on visited-but-off-the-base-path cells
		# so collecting them strictly *raises* the magnet count.
		var with_waypoints: Puzzle
		var solution: Solution
		if waypoints > 0:
			var placed: Variant = _pick_detour_waypoints(base, base_solution, touched, waypoints)
			if placed == null:
				continue  # not enough off-path room
			with_waypoints = base.with_overrides({"waypoints": placed})
			var s := Solver.new(with_waypoints).solve()
			if s == null:
				continue
			if s.magnet_count <= base_solution.magnet_count:
				continue  # no detour
			solution = s
		else:
			with_waypoints = base
			solution = base_solution

		if not Difficulty.accepts(difficulty, solution.magnet_count):
			continue  # wrong band

		# Cheap filter first: harder bands demand a non-monotone (retreating)
		# solution before we pay for the expensive solution count.
		if params["require_detour"] and not _is_non_monotone(with_waypoints, solution):
			continue

		# Tighten the budget to exactly what the solution uses — no slack to
		# brute-force with — then demand the solution be scarce on that board.
		var puzzle := _with_tight_budget(with_waypoints, solution)
		var max_solutions: int = params["max_solutions"]
		var count := Solver.new(puzzle).count_minimal_solutions(
			solution.magnet_count, max_solutions + 1
		)
		if count > max_solutions:
			continue

		# Verify by replay: reach the target collecting every waypoint.
		if not _replay_reaches(puzzle, solution):
			continue

		return {"puzzle": puzzle, "solution": solution, "solution_count": count}
	return null


## Replays [param solution] on a single-ball [param puzzle]; true iff the ball
## lands on the target and every waypoint is collected on the way.
func _replay_reaches(puzzle: Puzzle, solution: Solution) -> bool:
	var ball := puzzle.start
	var collected := {}
	for w: Vector2i in puzzle.waypoints:
		if w == puzzle.start:
			collected[w] = true
	for mi: int in solution.sequence:
		var from := ball
		ball = Movement.activate(ball, solution.magnets[mi], solution.magnets, puzzle)
		for w: Vector2i in puzzle.waypoints:
			if Movement.on_ball_path(w, from, ball):
				collected[w] = true
	if not puzzle.is_target(ball):
		return false
	return collected.size() == puzzle.waypoints.size()


## Picks [param count] waypoints from [param touched], preferring cells the base
## solution does *not* pass through (so collecting them forces a detour). Returns
## null if there aren't enough candidates.
func _pick_detour_waypoints(
	base: Puzzle, base_solution: Solution, touched: Array, count: int
) -> Variant:
	if touched.size() < count:
		return null
	var on_path := _solution_path(base, base_solution)
	var off_path: Array = []
	var on_path_rest: Array = []
	for c: Vector2i in touched:
		if on_path.has(c):
			on_path_rest.append(c)
		else:
			off_path.append(c)
	_shuffle(off_path)
	_shuffle(on_path_rest)
	# Off-path cells first (likely detours), then on-path to make up the count.
	var ordered: Array = off_path + on_path_rest
	if ordered.size() < count:
		return null
	return ordered.slice(0, count)


## The set of cells the ball touches while replaying [param solution].
func _solution_path(puzzle: Puzzle, solution: Solution) -> Dictionary:
	var cells := {puzzle.start: true}
	var ball := puzzle.start
	for mi: int in solution.sequence:
		var from := ball
		ball = Movement.activate(ball, solution.magnets[mi], solution.magnets, puzzle)
		for r in puzzle.size:
			for c in puzzle.size:
				var cell := Vector2i(r, c)
				if Movement.on_ball_path(cell, from, ball):
					cells[cell] = true
	return cells


## Picks [param count] cells the ball crossed and gives each a random
## orientation — deflector candidates that sit on the action path, so they are
## likely to matter. Returns null if there aren't enough cells.
func _pick_deflectors(touched: Array, count: int) -> Variant:
	if touched.size() < count:
		return null
	var cells := touched.duplicate()
	_shuffle(cells)
	var out := {}
	for c: Vector2i in cells.slice(0, count):
		out[c] = Deflector.Dir.BACKSLASH if _rng.randi() % 2 == 0 else Deflector.Dir.SLASH
	return out


## Whether replaying [param solution] ever sends the ball through a deflector —
## the guard that the deflectors genuinely route the solution rather than sitting
## inert off the path.
func _uses_deflector(puzzle: Puzzle, solution: Solution) -> bool:
	var ball := puzzle.start
	for mi: int in solution.sequence:
		var path := Movement.slide_path(ball, solution.magnets[mi], solution.magnets, puzzle)
		for cell: Vector2i in path:
			if puzzle.is_deflector(cell):
				return true
		ball = path[path.size() - 1]
	return false


## Whether [param solution] ever moves the ball *away* from the target (Manhattan
## distance grows). A purely monotone solution is the obvious greedy one and
## makes for an easy puzzle.
func _is_non_monotone(puzzle: Puzzle, solution: Solution) -> bool:
	var ball := puzzle.start
	for mi: int in solution.sequence:
		var from := ball
		ball = Movement.activate(ball, solution.magnets[mi], solution.magnets, puzzle)
		if _distance(ball, puzzle.target) > _distance(from, puzzle.target):
			return true
	return false


static func _distance(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


## A copy of [param puzzle] whose per-type budget is exactly the number of plus /
## minus magnets [param solution] uses.
func _with_tight_budget(puzzle: Puzzle, solution: Solution) -> Puzzle:
	var plus := 0
	var minus := 0
	for m: Magnet in solution.magnets:
		if m.is_plus():
			plus += 1
		else:
			minus += 1
	return puzzle.with_overrides({"plus_budget": plus, "minus_budget": minus})


## Builds one candidate as `{"puzzle": Puzzle, "touched": Array}`: the base
## puzzle (no waypoints) plus the cells the ball crossed while it was constructed
## (collectible waypoint candidates). Null on a dud layout.
func _construct(
	difficulty: Difficulty.Band, size: int, max_runs: int, plus_budget: int, minus_budget: int
) -> Variant:
	var params := Difficulty.params(difficulty)
	var strength: int = params["strength"]

	# 1. Walls.
	var walls := {}
	var wall_count := int(params["min_walls"]) + _rng.randi() % int(params["extra_walls"])
	while walls.size() < wall_count:
		walls[Vector2i(_rng.randi() % size, _rng.randi() % size)] = true

	if size * size - walls.size() < 10:
		return null

	var free: Array = []
	for r in size:
		for c in size:
			var cell := Vector2i(r, c)
			if not walls.has(cell):
				free.append(cell)
	var start: Vector2i = free[_rng.randi() % free.size()]

	# The board the construction walk runs on (single-use + finite range so the
	# walk obeys the same rules the player and solver will).
	var board := Puzzle.create({
		"size": size,
		"start": start,
		"target": start,
		"walls": walls,
		"plus_budget": plus_budget,
		"minus_budget": minus_budget,
		"max_runs": max_runs,
		"magnet_strength": strength,
		"magnet_reach": size - 1,
		"single_use": true,
	})

	var magnets: Array = []
	var occupied := {}
	var touched := {}  # cells the ball crosses -> waypoint candidates
	var plus := 0
	var minus := 0
	var ball := start

	# 2. Lay a stepping-stone chain, wandering in any direction (not straight at
	#    a corner) so the path winds and the target can end up needing a detour.
	#    Each magnet moves the ball exactly `strength` cells: a PLUS just beyond
	#    the landing cell (pulls), or a MINUS just behind the ball (pushes).
	#    Every magnet is distinct, so under single-use the solution is a genuine
	#    chain.
	var chain: int = params["chain"]
	var attempts := 0
	while magnets.size() < chain and attempts < chain * 12:
		attempts += 1
		var dirs := Movement.DIRECTIONS.duplicate()
		_shuffle(dirs)
		var moved := false
		for step: Vector2i in dirs:
			# Every cell the ball crosses must be clear.
			var clear := true
			for k in range(1, strength + 1):
				if not _free_cell(ball + step * k, board, walls, occupied, start):
					clear = false
					break
			if not clear:
				continue

			var landing := ball + step * strength
			var ahead_plus := ball + step * (strength + 1)
			var behind_minus := ball - step

			var chosen: Magnet = null
			if plus < plus_budget and _free_cell(ahead_plus, board, walls, occupied, start):
				chosen = Magnet.new(ahead_plus, Magnet.Type.PLUS)
			elif minus < minus_budget and _free_cell(behind_minus, board, walls, occupied, start):
				chosen = Magnet.new(behind_minus, Magnet.Type.MINUS)
			if chosen == null:
				continue

			# Confirm the magnet actually lands the ball where we planned.
			var with_chosen := magnets.duplicate()
			with_chosen.append(chosen)
			if Movement.activate(ball, chosen, with_chosen, board) != landing:
				continue

			magnets.append(chosen)
			occupied[chosen.pos] = true
			if chosen.is_plus():
				plus += 1
			else:
				minus += 1
			for k in range(1, strength + 1):
				touched[ball + step * k] = true
			ball = landing
			moved = true
			break
		if not moved:
			break  # boxed in

	var target := ball
	if magnets.size() < 2 or target == start:
		return null

	var base := Puzzle.create({
		"id": 100 + _rng.randi() % 900,
		"size": size,
		"start": start,
		"target": target,
		"walls": walls,
		"plus_budget": plus_budget,
		"minus_budget": minus_budget,
		"max_runs": max_runs,
		"magnet_strength": strength,
		"magnet_reach": size - 1,
		"single_use": true,
	})

	# Cells the ball actually crossed (minus the target / magnet cells) are the
	# collectible-by-construction candidates for waypoints.
	var candidates: Array = []
	for p: Vector2i in touched.keys():
		if p != target and not occupied.has(p):
			candidates.append(p)
	return {"puzzle": base, "touched": candidates}


func _free_cell(
	p: Vector2i, board: Puzzle, walls: Dictionary, occupied: Dictionary, start: Vector2i
) -> bool:
	return board.in_bounds(p) and not walls.has(p) and not occupied.has(p) and p != start


# --- Multi-ball generation --------------------------------------------------

## Generates a solvable multi-ball puzzle by *construction*: it walks the balls
## with random activations (so a solving sequence exists by design), sets each
## ball's final cell as its target, then keeps that walk as the verified
## solution. Construction keeps things fast (a solution always exists) and lets
## deflectors and waypoints compose cleanly.
func _generate_multi_ball(
	difficulty: Difficulty.Band,
	size: int,
	max_runs: int,
	balls: int,
	deflectors: int,
	waypoints: int,
	tries: int,
) -> Variant:
	# Multi-ball difficulty scales with the ball count, so it uses its own knobs
	# rather than the single-ball magnet bands: [param difficulty] just nudges how
	# far the balls are walked (and thus the minimal magnet count).
	var extra := int(difficulty)  # easy 0, medium 1, hard 2

	for _t in tries:
		var moves := balls + extra + _rng.randi() % 2
		var built: Variant = _construct_multi_ball(size, max_runs, balls, deflectors, moves)
		if built == null:
			continue
		var puzzle: Puzzle = built["puzzle"]
		var touched: Array = built["touched"]
		var walk_magnets: Array = built["magnets"]

		if waypoints > 0:
			var cands: Array = []
			for p: Vector2i in touched:
				if puzzle.is_placeable(p):
					cands.append(p)
			if cands.size() < waypoints:
				continue
			_shuffle(cands)
			puzzle = puzzle.with_overrides({"waypoints": cands.slice(0, waypoints)})

		# The construction *is* a verified solution: each distinct magnet fired
		# once, in order. Use it directly — running the full minimal solver here
		# would be far too slow for 3 balls (huge BFS state).
		var sequence: Array = []
		for i in walk_magnets.size():
			sequence.append(i)
		var solution := Solution.new(walk_magnets, sequence, walk_magnets.size())

		if solution.activation_count() < 2:
			continue  # avoid trivial one-move wins
		if deflectors > 0 and not _uses_deflector_multi(puzzle, solution):
			continue
		if not _replay_multi_reaches(puzzle, solution):
			continue

		# Tighten the budget to exactly what the solution uses (like single-ball).
		return {
			"puzzle": _with_tight_budget(puzzle, solution),
			"solution": solution,
			"solution_count": 0,
		}
	return null


## One construction attempt: light walls + deflectors, [param balls] random
## starts, then random activations until several balls have moved. Returns
## `{"puzzle": Puzzle, "touched": Array, "magnets": Array}` — the base puzzle
## (targets = final positions), the cells the balls crossed (waypoint
## candidates), and the exact magnets+order that solves it, so the caller can use
## that as a verified solution without paying for the (expensive) solver. Null on
## a dud layout.
func _construct_multi_ball(
	size: int, max_runs: int, balls: int, deflectors: int, moves: int
) -> Variant:
	var walls := {}
	var wall_count := _rng.randi() % size  # kept light so balls can be routed
	while walls.size() < wall_count:
		walls[Vector2i(_rng.randi() % size, _rng.randi() % size)] = true

	var free: Array = []
	for r in size:
		for c in size:
			var cell := Vector2i(r, c)
			if not walls.has(cell):
				free.append(cell)
	_shuffle(free)
	if free.size() < balls * 2 + deflectors + 4:
		return null

	var idx := 0
	var starts: Array = []
	for _i in balls:
		starts.append(free[idx])
		idx += 1
	var deflector_map := {}
	for _i in deflectors:
		deflector_map[free[idx]] = (
			Deflector.Dir.BACKSLASH if _rng.randi() % 2 == 0 else Deflector.Dir.SLASH
		)
		idx += 1

	# The board the walk runs on: board-wide reach, unlimited strength.
	var extra_start_balls: Array = []
	for i in range(1, balls):
		extra_start_balls.append({"start": starts[i], "target": starts[i]})
	var board := Puzzle.create({
		"size": size,
		"start": starts[0],
		"target": starts[0],
		"extra_balls": extra_start_balls,
		"walls": walls,
		"deflectors": deflector_map,
		"magnet_reach": size - 1,
		"plus_budget": 9,
		"minus_budget": 9,
	})

	var positions := starts.duplicate()
	var touched := {}
	for s: Vector2i in starts:
		touched[s] = true
	var used_cells := {}  # distinct construction magnet cells
	var walk_magnets: Array = []  # the solving sequence, in order
	var steps := maxi(moves, 2)
	var attempts := 0

	while used_cells.size() < steps and attempts < steps * 12:
		attempts += 1
		var cell: Vector2i = free[_rng.randi() % free.size()]
		# Never place on a ball, a reused cell, a ball's start, or a deflector —
		# the magnet must stay placeable in the finished puzzle.
		if (
			positions.has(cell)
			or used_cells.has(cell)
			or starts.has(cell)
			or deflector_map.has(cell)
		):
			continue
		var magnet := Magnet.new(
			cell, Magnet.Type.PLUS if _rng.randi() % 2 == 0 else Magnet.Type.MINUS
		)
		var paths := Movement.activate_all_paths(positions, magnet, [magnet], board)
		var next: Array = []
		for p: Array in paths:
			next.append(p[p.size() - 1])
		if Movement.same_positions(next, positions):
			continue  # nothing moved
		for p: Array in paths:
			for cellp: Vector2i in p:
				touched[cellp] = true
		used_cells[cell] = true
		walk_magnets.append(magnet)
		positions = next

	if used_cells.size() < 2:
		return null

	var targets := positions
	# Reject degenerate layouts: a ball still on its start, duplicate targets, or
	# a target on a deflector tile.
	var unique := {}
	for t: Vector2i in targets:
		unique[t] = true
	if unique.size() != targets.size():
		return null
	for i in balls:
		if targets[i] == starts[i]:
			return null
		if deflector_map.has(targets[i]):
			return null
	# A construction magnet landing on a final target would be unplaceable, so the
	# constructed solution couldn't be reproduced — drop the layout.
	for c: Vector2i in used_cells.keys():
		if targets.has(c):
			return null

	var extra: Array = []
	for i in range(1, balls):
		extra.append({"start": starts[i], "target": targets[i]})
	var puzzle := Puzzle.create({
		"id": 400 + _rng.randi() % 600,
		"size": size,
		"start": starts[0],
		"target": targets[0],
		"extra_balls": extra,
		"walls": walls,
		"deflectors": deflector_map,
		"magnet_reach": size - 1,
		"plus_budget": balls + 3,
		"minus_budget": balls + 3,
		"max_runs": max_runs,
	})

	var candidates: Array = []
	for p: Vector2i in touched.keys():
		if not starts.has(p) and not targets.has(p):
			candidates.append(p)
	return {"puzzle": puzzle, "touched": candidates, "magnets": walk_magnets}


## Replays [param solution] on a multi-ball [param puzzle]; true iff every ball
## lands on its target and every waypoint is collected on the way.
func _replay_multi_reaches(puzzle: Puzzle, solution: Solution) -> bool:
	var balls := puzzle.ball_starts()
	var collected := {}
	for w: Vector2i in puzzle.waypoints:
		if balls.has(w):
			collected[w] = true
	for mi: int in solution.sequence:
		var paths := Movement.activate_all_paths(
			balls, solution.magnets[mi], solution.magnets, puzzle
		)
		for w: Vector2i in puzzle.waypoints:
			for p: Array in paths:
				if p.has(w):
					collected[w] = true
					break
		balls = []
		for p: Array in paths:
			balls.append(p[p.size() - 1])
	var targets := puzzle.ball_targets()
	for i in balls.size():
		if balls[i] != targets[i]:
			return false
	return collected.size() == puzzle.waypoints.size()


## Whether replaying [param solution] ever routes any ball through a deflector.
func _uses_deflector_multi(puzzle: Puzzle, solution: Solution) -> bool:
	var balls := puzzle.ball_starts()
	for mi: int in solution.sequence:
		var paths := Movement.activate_all_paths(
			balls, solution.magnets[mi], solution.magnets, puzzle
		)
		for p: Array in paths:
			for cell: Vector2i in p:
				if puzzle.is_deflector(cell):
					return true
		balls = []
		for p: Array in paths:
			balls.append(p[p.size() - 1])
	return false


## Fisher-Yates using this generator's seeded RNG, so a seed reproduces a run
## exactly ([method Array.shuffle] would use the global RNG).
func _shuffle(array: Array) -> void:
	for i in range(array.size() - 1, 0, -1):
		var j := _rng.randi() % (i + 1)
		var tmp: Variant = array[i]
		array[i] = array[j]
		array[j] = tmp
