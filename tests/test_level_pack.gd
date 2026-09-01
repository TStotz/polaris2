@tool
extends McpTestSuite

## Replays every shipped level's stored solution through [Movement] and demands
## it actually wins.
##
## The offline pipeline already verified each level — but it verified it with the
## *Dart* rules. This suite is the receipt that the **Godot** rules agree, level
## by level, on the exact boards that ship. If the port ever drifts on a case the
## random differential fixture happens not to cover, an unwinnable level in the
## campaign is the worst possible way to find out.
##
## It also guards the pack itself: budgets that cannot hold the solution, magnets
## placed on cells the game would refuse, ids that collide.

const PACK_PATH := "res://data/levels.json"

var _pack: LevelPack


func suite_name() -> String:
	return "level_pack"


func suite_setup(_ctx: Dictionary) -> void:
	_pack = LevelPack.load_default()


func test_pack_loads() -> void:
	assert_eq(_pack.load_error, "", "level pack must load")
	assert_gt(_pack.count(), 50, "campaign should hold the full level list")
	assert_gt(_pack.chapters.size(), 3, "campaign should have chapters")


func test_ids_are_unique_and_in_play_order() -> void:
	var seen := {}
	var previous := 0
	for level: Level in _pack.levels:
		assert_false(seen.has(level.id), "duplicate level id %d" % level.id)
		seen[level.id] = true
		assert_gt(level.id, previous, "level ids must ascend in play order")
		previous = level.id


func test_every_level_ships_a_solution() -> void:
	var missing: Array[String] = []
	for level: Level in _pack.levels:
		if level.solution_magnets.is_empty() or level.solution_sequence.is_empty():
			missing.append(str(level.id))
	assert_true(
		missing.is_empty(), "levels without a solution: %s" % ", ".join(missing)
	)


func test_every_solution_fits_the_budget() -> void:
	# The hint applies the stored solution straight to the board, so a solution
	# the budget cannot hold would hand the player an illegal position.
	var problems: Array[String] = []
	for level: Level in _pack.levels:
		var plus := 0
		var minus := 0
		for magnet: Magnet in level.solution_magnets:
			if magnet.is_plus():
				plus += 1
			else:
				minus += 1
		if plus > level.puzzle.plus_budget or minus > level.puzzle.minus_budget:
			problems.append(
				"level %d needs %d+/%d- but budget is %d+/%d-"
				% [level.id, plus, minus, level.puzzle.plus_budget, level.puzzle.minus_budget]
			)
		for magnet: Magnet in level.solution_magnets:
			if not level.puzzle.is_placeable(magnet.pos):
				problems.append(
					"level %d places a magnet on the unplaceable cell %s"
					% [level.id, magnet.pos]
				)
	assert_true(problems.is_empty(), "\n  ".join(problems))


func test_every_solution_actually_wins() -> void:
	var failures: Array[String] = []

	for level: Level in _pack.levels:
		var puzzle := level.puzzle
		var magnets := level.solution_magnets
		var balls := puzzle.ball_starts()
		var gate_mask := 0
		var collected := {}
		for w: Vector2i in puzzle.waypoints:
			if balls.has(w):
				collected[w] = true

		for index: int in level.solution_sequence:
			var paths := Movement.activate_all_paths(
				balls, magnets[index], magnets, puzzle, gate_mask
			)
			for w: Vector2i in puzzle.waypoints:
				for path: Array in paths:
					if path.has(w):
						collected[w] = true
						break
			# Plates fire only once the slide has resolved, so the next move is the
			# first one that sees the new doors.
			gate_mask ^= puzzle.plates_toggled_by(paths)
			balls = []
			for path: Array in paths:
				balls.append(path[path.size() - 1])

		var targets := puzzle.ball_targets()
		if not Movement.same_positions(balls, targets):
			failures.append(
				"level %d ends at %s, target is %s" % [level.id, balls, targets]
			)
		elif collected.size() != puzzle.waypoints.size():
			failures.append(
				"level %d collects only %d of %d waypoints"
				% [level.id, collected.size(), puzzle.waypoints.size()]
			)
		if failures.size() >= 5:
			break

	assert_true(
		failures.is_empty(),
		"shipped levels the Godot rules cannot win:\n  %s" % "\n  ".join(failures),
	)


func test_every_deflector_actually_changes_the_outcome() -> void:
	# A deflector the solution merely *touches* is not doing any work — the
	# generator only checked that the path crosses one, and since it drops them on
	# the construction walk's own cells, that was almost always true and almost
	# never meaningful. This re-runs each solution on a copy of the board with the
	# deflectors removed: if the ball still lands on target, the tile is decoration.
	var inert: Array[String] = []

	for level: Level in _pack.levels:
		if level.puzzle.deflectors.is_empty():
			continue
		var bare := level.puzzle.with_overrides({"deflectors": {}})
		if _solution_wins(level, bare):
			inert.append("level %d (%s)" % [level.id, level.chapter])

	assert_true(
		inert.is_empty(),
		"levels whose deflectors change nothing:\n  %s" % "\n  ".join(inert),
	)


func test_every_deflector_visibly_bends_the_ball() -> void:
	# The stronger, player-facing half of the same rule. A ball that rolls onto a
	# deflector and stops dead on it — because the new direction runs straight into
	# a wall or off the board — looks exactly like a ball that ignored the tile,
	# even when the outcome technically differs. On a board that ships a deflector,
	# the solution has to make it turn a corner and keep going.
	var flat: Array[String] = []

	for level: Level in _pack.levels:
		if level.puzzle.deflectors.is_empty():
			continue
		if not _solution_bends_at_a_deflector(level):
			flat.append("level %d (%s)" % [level.id, level.chapter])

	assert_true(
		flat.is_empty(),
		"levels where the ball never visibly turns on a deflector:\n  %s" % "\n  ".join(flat),
	)


## Whether replaying [param level]'s solution ever changes a ball's direction *on*
## a deflector cell and travels at least one more cell afterwards.
func _solution_bends_at_a_deflector(level: Level) -> bool:
	var puzzle := level.puzzle
	var magnets := level.solution_magnets
	var balls := puzzle.ball_starts()
	var gate_mask := 0

	for index: int in level.solution_sequence:
		var paths := Movement.activate_all_paths(
			balls, magnets[index], magnets, puzzle, gate_mask
		)
		gate_mask ^= puzzle.plates_toggled_by(paths)
		for path: Array in paths:
			# A bend needs a cell before and a cell after, so scan the interior.
			for i in range(1, path.size() - 1):
				if not puzzle.is_deflector(path[i]):
					continue
				if path[i] - path[i - 1] != path[i + 1] - path[i]:
					return true
		balls = []
		for path: Array in paths:
			balls.append(path[path.size() - 1])
	return false


func test_every_switch_level_actually_needs_its_plate() -> void:
	# Freeze the plates and the shipped solution must stop working, or the switch
	# is scenery — the same trap the deflector chapter fell into.
	#
	# This is the cheap half of the property: it proves *this* solution leans on
	# the plate. The pipeline runs the expensive half offline, re-solving the
	# frozen board from scratch to prove no other route exists at all.
	var scenery: Array[String] = []

	for level: Level in _pack.levels:
		if level.puzzle.gates.is_empty():
			continue
		var frozen := level.puzzle.with_overrides({"plates": {}})
		if _solution_wins(level, frozen):
			scenery.append("level %d (%s)" % [level.id, level.chapter])

	assert_true(
		scenery.is_empty(),
		"levels whose gates never had to open:\n  %s" % "\n  ".join(scenery),
	)


func test_no_level_hides_a_plate_or_gate_under_a_magnet() -> void:
	# A magnet on a plate could never be pressed and a gate can turn solid under
	# one, so the pack must never ship a solution that places either there.
	var problems: Array[String] = []
	for level: Level in _pack.levels:
		for magnet: Magnet in level.solution_magnets:
			if level.puzzle.is_plate(magnet.pos) or level.puzzle.is_gate(magnet.pos):
				problems.append("level %d places a magnet on %s" % [level.id, magnet.pos])
	assert_true(problems.is_empty(), "\n  ".join(problems))


## Replays [param level]'s stored solution on [param board] (which may differ from
## the level's own puzzle) and returns whether it still wins.
func _solution_wins(level: Level, board: Puzzle) -> bool:
	var magnets := level.solution_magnets
	var balls := board.ball_starts()
	var gate_mask := 0
	var collected := {}
	for w: Vector2i in board.waypoints:
		if balls.has(w):
			collected[w] = true

	for index: int in level.solution_sequence:
		var paths := Movement.activate_all_paths(
			balls, magnets[index], magnets, board, gate_mask
		)
		for w: Vector2i in board.waypoints:
			for path: Array in paths:
				if path.has(w):
					collected[w] = true
					break
		gate_mask ^= board.plates_toggled_by(paths)
		balls = []
		for path: Array in paths:
			balls.append(path[path.size() - 1])

	return (
		Movement.same_positions(balls, board.ball_targets())
		and collected.size() == board.waypoints.size()
	)
