@tool
extends McpTestSuite

## Differential test: the Godot [Solver] against the original Dart solver.
##
## `tests/data/golden_solver.json` was produced by running the **Flutter app's
## own** `logic/solver.dart` over 240 deterministic small boards — a mix of
## walls, deflectors, waypoints, single-use rules, finite strength/reach and
## multi-ball layouts. Each case records whether a solution exists, its minimal
## magnet count, the exact placement and activation sequence, and the minimal
## solution count the generator filters on.
##
## Both implementations walk the identical search order (placeable cells
## row-major, PLUS before MINUS, BFS frontier in insertion order), so "a" minimal
## solution is in fact "the" minimal solution for both — the placement and
## sequence must match, not merely the magnet count.
##
## The sweep is split into slices because the runner only services the editor
## transport *between* tests: one multi-minute test method would starve it.

const GOLDEN_PATH := "res://tests/data/golden_solver.json"
const SLICE_COUNT := 8
const MAX_DEPTH := 5  # must match the depth the fixture was generated with

var _cases: Array = []
var _load_error := ""


func suite_name() -> String:
	return "solver_differential"


func suite_setup(_ctx: Dictionary) -> void:
	var file := FileAccess.open(GOLDEN_PATH, FileAccess.READ)
	if file == null:
		_load_error = "cannot open %s (error %d)" % [GOLDEN_PATH, FileAccess.get_open_error()]
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		_load_error = "%s is not valid JSON" % GOLDEN_PATH
		return
	_cases = (parsed as Dictionary).get("cases", [])


func test_00_fixture_loads() -> void:
	assert_eq(_load_error, "", "golden fixture must load")
	assert_gt(_cases.size(), 50, "fixture should hold the full case list")
	var solved := 0
	var multi_ball := 0
	for c: Dictionary in _cases:
		if c["solved"]:
			solved += 1
		if not (c["puzzle"]["balls"] as Array).is_empty():
			multi_ball += 1
	# A fixture of only-unsolvable boards would pass vacuously, and one without
	# multi-ball boards would leave the whole shared-move BFS unchecked.
	assert_gt(solved, 25, "fixture needs plenty of solved cases to be meaningful")
	assert_gt(multi_ball, 5, "fixture needs multi-ball boards to exercise the shared-move BFS")


func test_01_slice() -> void:
	_check_slice(0)


func test_02_slice() -> void:
	_check_slice(1)


func test_03_slice() -> void:
	_check_slice(2)


func test_04_slice() -> void:
	_check_slice(3)


func test_05_slice() -> void:
	_check_slice(4)


func test_06_slice() -> void:
	_check_slice(5)


func test_07_slice() -> void:
	_check_slice(6)


func test_08_slice() -> void:
	_check_slice(7)


## Compares every case in slice [param index] of [constant SLICE_COUNT].
func _check_slice(index: int) -> void:
	if not _load_error.is_empty():
		fail_setup(_load_error)
		return

	var per_slice := int(ceil(float(_cases.size()) / SLICE_COUNT))
	var from := index * per_slice
	var to := mini(from + per_slice, _cases.size())
	var mismatches: Array[String] = []

	for i in range(from, to):
		var c: Dictionary = _cases[i]
		var puzzle := Puzzle.from_json(c["puzzle"])
		var solution := Solver.new(puzzle, MAX_DEPTH).solve()

		var want_solved: bool = c["solved"]
		if (solution != null) != want_solved:
			mismatches.append(
				"case %d solvable: got %s, dart says %s" % [i, solution != null, want_solved]
			)
			continue
		if solution == null:
			continue

		if solution.magnet_count != int(c["magnet_count"]):
			mismatches.append(
				"case %d magnet_count: got %d, dart says %d"
				% [i, solution.magnet_count, int(c["magnet_count"])]
			)

		var got_magnets := _describe_magnets(solution.magnets)
		var want_magnets := _describe_golden_magnets(c["magnets"])
		if got_magnets != want_magnets:
			mismatches.append(
				"case %d placement: got %s, dart says %s" % [i, got_magnets, want_magnets]
			)

		var want_sequence: Array = []
		for step: float in c["sequence"]:
			want_sequence.append(int(step))
		if solution.sequence != want_sequence:
			mismatches.append(
				"case %d sequence: got %s, dart says %s" % [i, solution.sequence, want_sequence]
			)

		var want_count := int(c["solution_count"])
		var got_count := Solver.new(puzzle, MAX_DEPTH).count_minimal_solutions(
			solution.magnet_count, 4
		)
		if got_count != want_count:
			mismatches.append(
				"case %d solution_count: got %d, dart says %d" % [i, got_count, want_count]
			)

		if mismatches.size() >= 5:
			break

	assert_true(
		mismatches.is_empty(),
		"solver diverges from the Dart reference:\n  %s" % "\n  ".join(mismatches),
	)


func _describe_magnets(magnets: Array) -> String:
	var parts: Array[String] = []
	for m: Magnet in magnets:
		parts.append("%s@(%d,%d)" % ["plus" if m.is_plus() else "minus", m.pos.x, m.pos.y])
	return ", ".join(parts)


func _describe_golden_magnets(magnets: Array) -> String:
	var parts: Array[String] = []
	for m: Dictionary in magnets:
		parts.append("%s@(%d,%d)" % [m["t"], int(m["r"]), int(m["c"])])
	return ", ".join(parts)
