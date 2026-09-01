@tool
extends McpTestSuite

## Port of the Dart suite `test/movement_test.dart`.
##
## [Movement] is the single source of truth for the rules, so this suite is the
## contract the game, the [Solver] and the [PuzzleGenerator] all inherit. Cells
## are [Vector2i] with x = row, y = col.

const PLUS := Magnet.Type.PLUS
const MINUS := Magnet.Type.MINUS


func suite_name() -> String:
	return "movement"


## Empty 6x6 board with start/target out of the way (movement tests don't care
## about start/target, only walls + edges).
func _board(walls: Array = []) -> Puzzle:
	return Puzzle.create({
		"start": Vector2i(0, 0),
		"target": Vector2i(5, 5),
		"walls": walls,
		# Board-spanning reach: these tests assume a magnet grabs anywhere in line.
		"magnet_reach": 5,
		"plus_budget": 9,
		"minus_budget": 9,
	})


func _one(cell: Vector2i, type: Magnet.Type, reach: int = Magnet.INHERIT) -> Array:
	return [Magnet.new(cell, type, Magnet.INHERIT, reach)]


# --- plus (attract) --------------------------------------------------------

func test_plus_parks_directly_next_to_the_magnet() -> void:
	var magnets := _one(Vector2i(0, 5), PLUS)
	var result := Movement.activate(Vector2i(0, 0), magnets[0], magnets, _board())
	assert_eq(result, Vector2i(0, 4))


func test_plus_wall_between_ball_and_magnet_blocks_the_field() -> void:
	# With the reach mechanic a wall on the straight line to the magnet blocks its
	# field entirely, so a PLUS can no longer pull the ball up to the wall — it
	# simply has no effect.
	var magnets := _one(Vector2i(0, 5), PLUS)
	var result := Movement.activate(
		Vector2i(0, 0), magnets[0], magnets, _board([Vector2i(0, 3)])
	)
	assert_eq(result, Vector2i(0, 0))


func test_plus_does_not_move_when_already_adjacent() -> void:
	var magnets := _one(Vector2i(0, 5), PLUS)
	var result := Movement.activate(Vector2i(0, 4), magnets[0], magnets, _board())
	assert_eq(result, Vector2i(0, 4))


# --- minus (repel) ---------------------------------------------------------

func test_minus_pushes_the_ball_to_the_far_edge() -> void:
	var magnets := _one(Vector2i(2, 5), MINUS)
	var result := Movement.activate(Vector2i(2, 3), magnets[0], magnets, _board())
	assert_eq(result, Vector2i(2, 0))


func test_minus_stops_at_the_last_free_cell_before_a_wall() -> void:
	var magnets := _one(Vector2i(2, 5), MINUS)
	var result := Movement.activate(
		Vector2i(2, 4), magnets[0], magnets, _board([Vector2i(2, 1)])
	)
	assert_eq(result, Vector2i(2, 2))


# --- no effect -------------------------------------------------------------

func test_magnet_not_in_line_leaves_the_ball_unchanged() -> void:
	var ball := Vector2i(1, 1)
	var magnets := _one(Vector2i(3, 4), PLUS)
	assert_eq(Movement.activate(ball, magnets[0], magnets, _board()), ball)


# --- another magnet acts as a solid blocker --------------------------------

func test_plus_stops_before_a_magnet_sitting_on_the_path() -> void:
	var magnets: Array = [
		Magnet.new(Vector2i(0, 5), PLUS),
		Magnet.new(Vector2i(0, 3), MINUS),
	]
	var result := Movement.activate(Vector2i(0, 0), magnets[0], magnets, _board())
	assert_eq(result, Vector2i(0, 2))


# --- magnet_field (area of effect) -----------------------------------------

## The step recorded for [param cell], or null when the field does not cover it.
func _step_at(field: Array, cell: Vector2i) -> Variant:
	for f: Dictionary in field:
		if f["cell"] == cell:
			return f["step"]
	return null


func test_field_of_a_plus_points_every_covered_cell_towards_the_magnet() -> void:
	var field := Movement.magnet_field(Magnet.new(Vector2i(2, 2), PLUS), _board())
	assert_eq(_step_at(field, Vector2i(2, 0)), Vector2i(0, 1))  # -> right
	assert_eq(_step_at(field, Vector2i(2, 5)), Vector2i(0, -1))  # <- left
	assert_eq(_step_at(field, Vector2i(0, 2)), Vector2i(1, 0))  # down
	assert_eq(_step_at(field, Vector2i(5, 2)), Vector2i(-1, 0))  # up


func test_field_of_a_minus_points_every_covered_cell_away() -> void:
	var field := Movement.magnet_field(Magnet.new(Vector2i(2, 2), MINUS), _board())
	assert_eq(_step_at(field, Vector2i(2, 0)), Vector2i(0, -1))
	assert_eq(_step_at(field, Vector2i(0, 2)), Vector2i(-1, 0))


func test_field_never_covers_the_magnet_cell_or_anything_off_the_board() -> void:
	var puzzle := _board()
	var field := Movement.magnet_field(Magnet.new(Vector2i(0, 0), PLUS), puzzle)
	assert_eq(_step_at(field, Vector2i(0, 0)), null)
	for f: Dictionary in field:
		var cell: Vector2i = f["cell"]
		assert_true(puzzle.in_bounds(cell), "%s is off the board" % cell)
		# Only ever straight lines through the magnet — never diagonal.
		assert_true(cell.x == 0 or cell.y == 0, "%s is diagonal" % cell)


func test_field_is_cut_off_by_a_wall() -> void:
	var puzzle := _board([Vector2i(0, 2)])
	var field := Movement.magnet_field(Magnet.new(Vector2i(0, 4), PLUS), puzzle)
	assert_ne(_step_at(field, Vector2i(0, 3)), null, "cell before the wall")
	assert_eq(_step_at(field, Vector2i(0, 2)), null, "the wall itself")
	assert_eq(_step_at(field, Vector2i(0, 1)), null, "behind the wall")
	assert_eq(_step_at(field, Vector2i(0, 0)), null, "far behind the wall")


func test_a_per_magnet_reach_shrinks_the_field() -> void:
	# Puzzle reach is 5; this magnet overrides it with 2.
	var magnet := Magnet.new(Vector2i(0, 5), PLUS, Magnet.INHERIT, 2)
	var field := Movement.magnet_field(magnet, _board())
	assert_ne(_step_at(field, Vector2i(0, 4)), null)
	assert_ne(_step_at(field, Vector2i(0, 3)), null)
	assert_eq(_step_at(field, Vector2i(0, 2)), null, "3 away -> too far")


func test_field_agrees_with_activate() -> void:
	# Covered <=> the magnet acts: the on-board hint can never promise a move the
	# rules would not make.
	var puzzle := _board([Vector2i(3, 3)])
	var magnet := Magnet.new(Vector2i(2, 2), PLUS, Magnet.INHERIT, 3)
	var covered := {}
	for f: Dictionary in Movement.magnet_field(magnet, puzzle):
		covered[f["cell"]] = true

	for r in 6:
		for c in 6:
			var ball := Vector2i(r, c)
			if ball == magnet.pos or puzzle.is_wall(ball):
				continue
			var moves := Movement.activate(ball, magnet, [magnet], puzzle) != ball
			if moves:
				assert_true(covered.has(ball), "%s moves but is not shown as covered" % ball)


# --- property: stays legal --------------------------------------------------

func test_random_activations_stay_on_the_board_and_terminate() -> void:
	# 1000 random single activations never leave the board or land on a wall, and
	# always terminate. Uses the same deterministic LCG as the Dart suite so both
	# implementations walk the identical case list.
	var lcg := _Lcg.new(12345)

	for _i in 1000:
		var walls: Array = []
		var wall_count := lcg.next(6)
		for _w in wall_count:
			walls.append(Vector2i(lcg.next(6), lcg.next(6)))
		var puzzle := _board(walls)

		var ball := Vector2i(lcg.next(6), lcg.next(6))
		while puzzle.is_wall(ball):
			ball = Vector2i(lcg.next(6), lcg.next(6))

		var mpos := Vector2i(lcg.next(6), lcg.next(6))
		while mpos == ball or puzzle.is_wall(mpos):
			mpos = Vector2i(lcg.next(6), lcg.next(6))

		var magnet := Magnet.new(mpos, PLUS if lcg.next(2) == 0 else MINUS)
		var result := Movement.activate(ball, magnet, [magnet], puzzle)

		assert_true(puzzle.in_bounds(result), "left the board: %s" % result)
		assert_false(puzzle.is_wall(result), "landed on a wall: %s" % result)


## The Dart suite's LCG, reproduced exactly so both ports see the same sequence.
class _Lcg:
	var seed_value: int

	func _init(initial: int) -> void:
		seed_value = initial

	func next(max_value: int) -> int:
		seed_value = (seed_value * 1103515245 + 12345) & 0x7fffffff
		return seed_value % max_value
