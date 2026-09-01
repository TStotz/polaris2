@tool
extends McpTestSuite

## The rules for plates and gates.
##
## Gates are a Godot-era mechanic — the Flutter original never had them — so
## there is no golden fixture to diff against. This suite *is* the specification,
## and `tools/reference_dart` carries the same rules so the pipeline can generate
## and verify switch levels. Anything asserted here is asserted of both.
##
## The rule worth stating out loud: a plate toggles its channel **after** the
## activation has fully resolved. One slide is therefore always evaluated against
## one board, and pressing a plate costs a move of its own — which is what makes
## the mechanic about ordering rather than about luck.

const PLUS := Magnet.Type.PLUS
const MINUS := Magnet.Type.MINUS


func suite_name() -> String:
	return "gates"


## Open 5x5 board, board-spanning reach, no strength cap.
func _board(config: Dictionary = {}) -> Puzzle:
	var base := {
		"start": Vector2i(2, 0),
		"target": Vector2i(2, 4),
		"walls": [],
		"magnet_reach": 4,
		"plus_budget": 9,
		"minus_budget": 9,
		"size": 5,
	}
	base.merge(config, true)
	return Puzzle.create(base)


# --- a shut gate is a wall --------------------------------------------------

func test_a_closed_gate_stops_the_ball_like_a_wall() -> void:
	# Without the gate a MINUS would push the ball to the far edge; the gate
	# should catch it one cell short.
	var puzzle := _board({"gates": {Vector2i(2, 3): Gate.new(0)}})
	var magnets: Array = [Magnet.new(Vector2i(2, 0), MINUS)]
	var result := Movement.activate(Vector2i(2, 1), magnets[0], magnets, puzzle, 0)
	assert_eq(result, Vector2i(2, 2), "stops on the last free cell before the gate")


func test_an_open_gate_does_not_block() -> void:
	var puzzle := _board({"gates": {Vector2i(2, 3): Gate.new(0)}})
	var magnets: Array = [Magnet.new(Vector2i(2, 0), MINUS)]
	# Channel 0 toggled -> the gate stands open, so the ball runs to the edge.
	var result := Movement.activate(Vector2i(2, 1), magnets[0], magnets, puzzle, 1)
	assert_eq(result, Vector2i(2, 4))


func test_a_gate_that_starts_open_shuts_when_toggled() -> void:
	var puzzle := _board({"gates": {Vector2i(2, 3): Gate.new(0, true)}})
	var magnets: Array = [Magnet.new(Vector2i(2, 0), MINUS)]
	assert_eq(
		Movement.activate(Vector2i(2, 1), magnets[0], magnets, puzzle, 0),
		Vector2i(2, 4),
		"open at start -> the ball passes"
	)
	assert_eq(
		Movement.activate(Vector2i(2, 1), magnets[0], magnets, puzzle, 1),
		Vector2i(2, 2),
		"toggled -> the same gate is now solid"
	)


func test_a_closed_gate_cuts_off_the_magnet_field() -> void:
	# A gate is a wall in *every* respect, so it blocks reach as well as travel —
	# otherwise a magnet could reach through a shut door.
	var puzzle := _board({"gates": {Vector2i(2, 2): Gate.new(0)}})
	var magnets: Array = [Magnet.new(Vector2i(2, 4), PLUS)]
	assert_eq(
		Movement.activate(Vector2i(2, 0), magnets[0], magnets, puzzle, 0),
		Vector2i(2, 0),
		"field blocked by the shut gate -> no effect"
	)
	assert_eq(
		Movement.activate(Vector2i(2, 0), magnets[0], magnets, puzzle, 1),
		Vector2i(2, 3),
		"open -> the magnet grabs the ball as usual"
	)


func test_the_field_overlay_agrees_with_the_gate_state() -> void:
	var puzzle := _board({"gates": {Vector2i(2, 2): Gate.new(0)}})
	var magnet := Magnet.new(Vector2i(2, 4), PLUS)
	assert_eq(
		_field_cells(Movement.magnet_field(magnet, puzzle, 0)).has(Vector2i(2, 0)),
		false,
		"the arrows must not promise a pull through a shut gate"
	)
	assert_eq(
		_field_cells(Movement.magnet_field(magnet, puzzle, 1)).has(Vector2i(2, 0)),
		true
	)


func _field_cells(field: Array) -> Dictionary:
	var cells := {}
	for entry: Dictionary in field:
		cells[entry["cell"]] = true
	return cells


# --- plates -----------------------------------------------------------------

func test_a_plate_is_pressed_by_rolling_over_it() -> void:
	# Touching counts, not stopping — the same rule waypoints use.
	var puzzle := _board({"plates": {Vector2i(2, 2): 0}})
	var magnets: Array = [Magnet.new(Vector2i(2, 0), MINUS)]
	var path := Movement.slide_path(Vector2i(2, 1), magnets[0], magnets, puzzle, 0)
	assert_contains(path, Vector2i(2, 2), "the ball rolls across the plate")
	assert_eq(puzzle.plates_toggled_by([path]), 1, "channel 0 toggles")


func test_a_plate_the_ball_misses_does_nothing() -> void:
	var puzzle := _board({"plates": {Vector2i(0, 0): 0}})
	var magnets: Array = [Magnet.new(Vector2i(2, 0), MINUS)]
	var path := Movement.slide_path(Vector2i(2, 1), magnets[0], magnets, puzzle, 0)
	assert_eq(puzzle.plates_toggled_by([path]), 0)


func test_two_plates_on_one_channel_toggle_it_once() -> void:
	# Deliberately *not* an XOR per plate: rolling over two plates of the same
	# colour and having them cancel out would be a gotcha, not a puzzle.
	var puzzle := _board({"plates": {Vector2i(2, 2): 0, Vector2i(2, 3): 0}})
	var magnets: Array = [Magnet.new(Vector2i(2, 0), MINUS)]
	var path := Movement.slide_path(Vector2i(2, 1), magnets[0], magnets, puzzle, 0)
	assert_eq(puzzle.plates_toggled_by([path]), 1)


func test_channels_are_independent() -> void:
	var puzzle := _board({
		"plates": {Vector2i(2, 2): 0, Vector2i(2, 3): 1},
		"gates": {Vector2i(4, 4): Gate.new(1)},
	})
	assert_eq(puzzle.plates_toggled_by([[Vector2i(2, 2)]]), 1, "channel 0 only")
	assert_eq(puzzle.plates_toggled_by([[Vector2i(2, 3)]]), 2, "channel 1 only")
	assert_true(puzzle.gate_open(Vector2i(4, 4), 2), "channel 1 opens its own gate")
	assert_false(puzzle.gate_open(Vector2i(4, 4), 1), "channel 0 leaves it alone")


func test_no_magnet_may_stand_on_a_plate_or_a_gate() -> void:
	# A magnet on a plate could never be pressed, and a gate cell can turn solid
	# underneath one.
	var puzzle := _board({
		"plates": {Vector2i(1, 1): 0},
		"gates": {Vector2i(3, 3): Gate.new(0)},
	})
	assert_false(puzzle.is_placeable(Vector2i(1, 1)), "plate")
	assert_false(puzzle.is_placeable(Vector2i(3, 3)), "gate")
	assert_true(puzzle.is_placeable(Vector2i(1, 3)), "an ordinary free cell still is")


# --- the ordering rule ------------------------------------------------------

func test_the_toggle_lands_after_the_activation_not_during_it() -> void:
	# The plate sits before the gate on the ball's line. If the toggle applied
	# mid-slide the ball would sail through; the rule is that this move is judged
	# against the board as it was, so the ball stops at the still-shut gate and
	# only the *next* move gets to use the opening.
	var puzzle := _board({
		"plates": {Vector2i(2, 2): 0},
		"gates": {Vector2i(2, 3): Gate.new(0)},
	})
	var magnets: Array = [Magnet.new(Vector2i(2, 0), MINUS)]
	var path := Movement.slide_path(Vector2i(2, 1), magnets[0], magnets, puzzle, 0)

	assert_eq(path[path.size() - 1], Vector2i(2, 2), "stopped at the gate, on the plate")
	var after := puzzle.plates_toggled_by([path])
	assert_eq(after, 1, "and the plate did fire")
	assert_true(puzzle.gate_open(Vector2i(2, 3), after), "the way is open for the next move")


# --- the solver understands all of it ---------------------------------------

## A board whose only route runs through a gate, with the plate off to one side.
##
## The wall at (1,4) is load-bearing: without it the ball can be pushed right
## along row 2 and then up column 4, reaching the target without ever meeting the
## gate. Two magnets, no switch — which is exactly what the "inert plate" test
## below caught on the first draft of this board.
func _switch_puzzle(with_plates: bool) -> Puzzle:
	return Puzzle.create({
		"size": 5,
		"start": Vector2i(2, 2),
		"target": Vector2i(0, 4),
		"walls": [Vector2i(1, 4)],
		"plates": {Vector2i(0, 2): 0} if with_plates else {},
		"gates": {Vector2i(0, 3): Gate.new(0)},
		"magnet_reach": 4,
		"plus_budget": 2,
		"minus_budget": 2,
	})


func test_solver_finds_the_route_that_presses_the_plate_first() -> void:
	var solution := Solver.new(_switch_puzzle(true)).solve()
	assert_ne(solution, null, "the board is solvable once the plate works")
	assert_eq(solution.magnet_count, 2, "one magnet to press, one to pass through")


func test_solver_calls_it_impossible_when_the_plate_is_inert() -> void:
	# The acceptance test the pipeline runs on every shipped switch level: freeze
	# the gates and the board must become unsolvable, or the switch is scenery.
	assert_eq(
		Solver.new(_switch_puzzle(false)).solve(),
		null,
		"with no plate the gate never opens and the target is walled off"
	)


func test_the_solvers_route_actually_wins_when_replayed() -> void:
	var puzzle := _switch_puzzle(true)
	var solution := Solver.new(puzzle).solve()
	assert_ne(solution, null)

	var balls := puzzle.ball_starts()
	var gate_mask := 0
	# Track whether the gate was ever open, not whether it is open at the end: a
	# route that crosses the plate on both moves toggles the channel right back to
	# zero, and the final mask would then hide that the gate was used at all.
	var was_ever_open := false

	for index: int in solution.sequence:
		var paths := Movement.activate_all_paths(
			balls, solution.magnets[index], solution.magnets, puzzle, gate_mask
		)
		gate_mask ^= puzzle.plates_toggled_by(paths)
		if gate_mask != 0:
			was_ever_open = true
		balls = []
		for path: Array in paths:
			balls.append(path[path.size() - 1])

	assert_eq(balls[0], puzzle.target, "replaying the solver's answer reaches the target")
	assert_true(was_ever_open, "and it did so by opening the gate on the way")
