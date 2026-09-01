@tool
class_name Solver
extends RefCounted

## Searches over magnet *sets* (placement + type) AND activation *sequences*,
## returning the solution with the fewest magnets.
##
## Complete and correct only within its search space (budget + [member max_depth]);
## beyond that it reports "unsolvable". In the content pipeline this must be used
## as a *filter*, never an oracle: only ship a puzzle whose solution was actually
## replayed and verified.
##
## All movement goes through [Movement], the same functions the live game uses,
## so solver and game can never drift apart.

## [member magnet_cap] value meaning "search the full budget".
const NO_CAP := -1

## Bit layout for the BFS visited-state keys. A cell index needs 9 bits (boards
## up to 22x22), the spent-magnet mask 16, the collected-waypoint mask 8 — all
## comfortably inside a 64-bit int, so states hash as plain integers instead of
## strings.
const _CELL_BITS := 9
const _USED_BITS := 16
const _COLLECTED_BITS := 8

var puzzle: Puzzle
var max_depth: int

## Optional cap on the magnet count the search will consider. When set, the
## solver gives up (returns null) instead of looking for solutions that need more
## than [member magnet_cap] magnets — the escape hatch that keeps generation
## fast: a board whose minimal solution exceeds the target band is rejected
## cheaply rather than proven expensive. [constant NO_CAP] = search the full
## budget.
var magnet_cap: int

var _checked: int = 0


func _init(target_puzzle: Puzzle, depth: int = 8, cap: int = NO_CAP) -> void:
	puzzle = target_puzzle
	max_depth = depth
	magnet_cap = cap


## The minimal solution, or null when none exists in the search space.
func solve() -> Solution:
	_checked = 0

	var cells := _placeable_cells()
	var max_magnets := puzzle.plus_budget + puzzle.minus_budget
	if magnet_cap != NO_CAP and magnet_cap < max_magnets:
		max_magnets = magnet_cap

	# Iterative deepening over magnet count -> fewest magnets wins.
	for n in range(1, max_magnets + 1):
		var result: Variant = _choose_n(cells, n, [], 0)
		if result != null:
			var found: Dictionary = result
			return Solution.new(found["magnets"], found["sequence"], n, _checked)
	return null


## Counts distinct [param n]-magnet placements that solve the puzzle, stopping
## once [param cap] is reached. A *difficulty proxy*: the fewer minimal solutions
## a puzzle has, the harder it is to find one (a unique solution is the hardest).
## Call with `n = solution.magnet_count` from a prior [method solve].
func count_minimal_solutions(n: int, cap: int = 8) -> int:
	var cells := _placeable_cells()
	var state := {"count": 0}
	_count_recurse(cells, n, [], 0, cap, state)
	return state["count"]


func _count_recurse(
	cells: Array, n: int, acc: Array, start: int, cap: int, state: Dictionary
) -> bool:
	if acc.size() == n:
		if not _within_budget(acc):
			return false
		if _find_sequence(acc) != null:
			state["count"] += 1
			if state["count"] >= cap:
				return true  # enough; stop early
		return false

	for i in range(start, cells.size()):
		for type: Magnet.Type in [Magnet.Type.PLUS, Magnet.Type.MINUS]:
			acc.append(Magnet.new(cells[i], type))
			if _count_recurse(cells, n, acc, i + 1, cap, state):
				return true
			acc.pop_back()
	return false


func _placeable_cells() -> Array:
	var cells: Array = []
	for r in puzzle.size:
		for c in puzzle.size:
			var cell := Vector2i(r, c)
			if puzzle.is_placeable(cell):
				cells.append(cell)
	return cells


func _within_budget(magnets: Array) -> bool:
	var plus := 0
	var minus := 0
	for m: Magnet in magnets:
		if m.is_plus():
			plus += 1
		else:
			minus += 1
	return plus <= puzzle.plus_budget and minus <= puzzle.minus_budget


## Backtracking choice of [param n] magnets from [param pool]; on a complete set,
## runs a BFS over activation sequences. Returns
## `{"magnets": Array, "sequence": Array}` or null.
func _choose_n(pool: Array, n: int, acc: Array, start: int) -> Variant:
	if acc.size() == n:
		if not _within_budget(acc):
			return null
		_checked += 1
		var seq: Variant = _find_sequence(acc)
		if seq != null:
			return {"magnets": acc.duplicate(), "sequence": seq}
		return null

	for i in range(start, pool.size()):
		for type: Magnet.Type in [Magnet.Type.PLUS, Magnet.Type.MINUS]:
			acc.append(Magnet.new(pool[i], type))
			var found: Variant = _choose_n(pool, n, acc, i + 1)
			if found != null:
				return found
			acc.pop_back()
	return null


## BFS over activation sequences for a fixed magnet set.
## State = ball position, action = activating one magnet.
##
## The state grows with the puzzle's rules:
##  - [member Puzzle.single_use] adds a bitmask of spent magnets (a magnet fires
##    once, so the same cell reached with different magnets left is a new state);
##  - [member Puzzle.waypoints] add a bitmask of collected waypoints (the goal is
##    reached only once every waypoint is collected).
## With neither, the position alone identifies the state.
##
## Returns the activation sequence ([Array] of [int]) or null.
func _find_sequence(magnet_set: Array) -> Variant:
	if puzzle.is_multi_ball():
		return _find_sequence_multi(magnet_set)

	var single_use := puzzle.single_use
	var wps := puzzle.waypoints
	var has_wp := not wps.is_empty()
	var all_wp := (1 << wps.size()) - 1  # 0 when there are no waypoints
	# Plates change which cells are solid, so the board a move is judged against
	# is part of the search state, not a constant.
	var needs_path := has_wp or not puzzle.plates.is_empty()

	# A single-use sequence can be no longer than the number of magnets.
	var max_len := magnet_set.size() if single_use else max_depth

	# A waypoint already on the start cell is collected before the first move.
	var start_collected := 0
	for i in wps.size():
		if wps[i] == puzzle.start:
			start_collected |= 1 << i

	var visited := {_key_of(puzzle.start, 0, start_collected, 0): true}
	# A frontier node is [pos, sequence, used_mask, collected_mask, gate_mask].
	var frontier: Array = [[puzzle.start, [], 0, start_collected, 0]]

	for _depth in max_len:
		var next: Array = []
		for node: Array in frontier:
			var node_pos: Vector2i = node[0]
			var node_seq: Array = node[1]
			var node_used: int = node[2]
			var node_collected: int = node[3]
			var node_gates: int = node[4]

			for mi in magnet_set.size():
				if single_use and (node_used & (1 << mi)) != 0:
					continue  # spent
				# With waypoints or plates, walk the real (possibly deflected)
				# path: a waypoint counts iff the ball actually crosses it, and a
				# plate only fires if it was stepped on.
				var np: Vector2i
				var collected := 0
				var gates := node_gates
				if needs_path:
					var path := Movement.slide_path(
						node_pos, magnet_set[mi], magnet_set, puzzle, node_gates
					)
					np = path[path.size() - 1]
					if np == node_pos:
						continue  # no movement -> useless action
					if has_wp:
						collected = _collect_along_path(path, node_collected, wps)
					# Plates flip only once the slide has fully resolved.
					gates = node_gates ^ puzzle.plates_toggled_by([path])
				else:
					np = Movement.activate(
						node_pos, magnet_set[mi], magnet_set, puzzle, node_gates
					)
					if np == node_pos:
						continue  # no movement -> useless action

				var seq := node_seq.duplicate()
				seq.append(mi)
				if puzzle.is_target(np) and collected == all_wp:
					return seq
				var used := (node_used | (1 << mi)) if single_use else 0
				var key := _key_of(np, used, collected, gates)
				if not visited.has(key):
					visited[key] = true
					next.append([np, seq, used, collected, gates])
		frontier = next
		if frontier.is_empty():
			break
	return null


## BFS over activation sequences for a multi-ball puzzle. State = the tuple of
## all ball positions, plus a spent-magnet mask (single-use) and a collected-
## waypoint mask (when the puzzle has waypoints). The goal is reached only when
## **every** ball rests on its own target *and* every waypoint has been
## collected — a waypoint counts as collected the moment any ball crosses it.
## Uses the same [method Movement.activate_all] the live game uses, so solver and
## game stay in lock-step.
func _find_sequence_multi(magnet_set: Array) -> Variant:
	var single_use := puzzle.single_use
	var targets := puzzle.ball_targets()
	var wps := puzzle.waypoints
	var has_wp := not wps.is_empty()
	var all_wp := (1 << wps.size()) - 1
	var needs_path := has_wp or not puzzle.plates.is_empty()
	var max_len := magnet_set.size() if single_use else max_depth

	# Waypoints already sitting on a ball's start are collected up front.
	var start_pos := puzzle.ball_starts()
	var start_collected := 0
	for i in wps.size():
		if start_pos.has(wps[i]):
			start_collected |= 1 << i
	if _balls_home(start_pos, targets) and start_collected == all_wp:
		return []

	var visited := {_key_of_multi(start_pos, 0, start_collected, 0): true}
	var frontier: Array = [[start_pos, [], 0, start_collected, 0]]

	for _depth in max_len:
		var next: Array = []
		for node: Array in frontier:
			var node_pos: Array = node[0]
			var node_seq: Array = node[1]
			var node_used: int = node[2]
			var node_collected: int = node[3]
			var node_gates: int = node[4]

			for mi in magnet_set.size():
				if single_use and (node_used & (1 << mi)) != 0:
					continue  # spent
				var np: Array
				var collected := 0
				var gates := node_gates
				if needs_path:
					var paths := Movement.activate_all_paths(
						node_pos, magnet_set[mi], magnet_set, puzzle, node_gates
					)
					np = []
					for p: Array in paths:
						np.append(p[p.size() - 1])
					if has_wp:
						collected = _collect_along_paths(paths, node_collected, wps)
					gates = node_gates ^ puzzle.plates_toggled_by(paths)
				else:
					np = Movement.activate_all(
						node_pos, magnet_set[mi], magnet_set, puzzle, node_gates
					)

				if Movement.same_positions(np, node_pos):
					continue  # no movement -> useless
				var seq := node_seq.duplicate()
				seq.append(mi)
				if _balls_home(np, targets) and collected == all_wp:
					return seq
				var used := (node_used | (1 << mi)) if single_use else 0
				var key := _key_of_multi(np, used, collected, gates)
				if not visited.has(key):
					visited[key] = true
					next.append([np, seq, used, collected, gates])
		frontier = next
		if frontier.is_empty():
			break
	return null


## Folds every waypoint on [param path] into [param mask].
func _collect_along_path(path: Array, mask: int, wps: Array) -> int:
	var m := mask
	for i in wps.size():
		if (m & (1 << i)) == 0 and path.has(wps[i]):
			m |= 1 << i
	return m


## Folds every waypoint any ball crossed on [param paths] into [param mask].
func _collect_along_paths(paths: Array, mask: int, wps: Array) -> int:
	var m := mask
	for i in wps.size():
		if (m & (1 << i)) != 0:
			continue
		for path: Array in paths:
			if path.has(wps[i]):
				m |= 1 << i
				break
	return m


func _balls_home(positions: Array, targets: Array) -> bool:
	for i in positions.size():
		if positions[i] != targets[i]:
			return false
	return true


## Packs (cell, spent-magnet mask, collected-waypoint mask) into one int so BFS
## states hash cheaply. See the bit-layout constants.
func _key_of(p: Vector2i, used: int, collected: int, gates: int) -> int:
	var cell := p.x * puzzle.size + p.y
	var shift := _CELL_BITS
	var key := cell | (used << shift)
	shift += _USED_BITS
	key |= collected << shift
	shift += _COLLECTED_BITS
	return key | (gates << shift)


## Multi-ball variant: every ball's cell packed into its own 9-bit slot, then the
## two masks. Supports up to 4 balls before the masks would be pushed past 63
## bits — the game uses 1-3.
func _key_of_multi(positions: Array, used: int, collected: int, gates: int) -> int:
	var key := 0
	var shift := 0
	for p: Vector2i in positions:
		key |= (p.x * puzzle.size + p.y) << shift
		shift += _CELL_BITS
	key |= used << shift
	shift += _USED_BITS
	key |= collected << shift
	shift += _COLLECTED_BITS
	return key | (gates << shift)
