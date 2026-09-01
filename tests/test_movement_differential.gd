@tool
extends McpTestSuite

## Differential test: the Godot port against the original Dart implementation.
##
## `tests/data/golden_movement.json` was produced by running the **Flutter app's
## own** `logic/movement.dart` (copied verbatim, only the Flutter import stripped)
## over 2000 pseudo-random boards. Every case records the exact inputs and what
## the reference implementation returned for [method Movement.activate],
## [method Movement.slide_path], [method Movement.activate_all],
## [method Movement.activate_all_paths] and [method Movement.magnet_field].
##
## This suite replays all of them and demands identical results. Because
## [Movement] is the single source of truth, a green run here means the game, the
## [Solver] and the [PuzzleGenerator] all inherit the reference behaviour —
## deflectors, per-magnet strength/reach overrides, multi-ball stacking and the
## deflector cycle guard included.
##
## Regenerating the fixture (only when the Dart original itself changes) is
## described in `tests/data/README.md`.

const GOLDEN_PATH := "res://tests/data/golden_movement.json"

var _cases: Array = []
var _load_error := ""


func suite_name() -> String:
	return "movement_differential"


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


func _pos(m: Dictionary) -> Vector2i:
	return Vector2i(int(m["r"]), int(m["c"]))


func _positions(list: Array) -> Array:
	var out: Array = []
	for m: Dictionary in list:
		out.append(_pos(m))
	return out


func _magnet(m: Dictionary) -> Magnet:
	var type := Magnet.Type.PLUS if m["t"] == "plus" else Magnet.Type.MINUS
	return Magnet.new(_pos(m), type, int(m["s"]), int(m["reach"]))


func test_fixture_loads() -> void:
	assert_eq(_load_error, "", "golden fixture must load")
	assert_gt(_cases.size(), 1000, "fixture should hold the full case list")


func test_matches_the_dart_reference() -> void:
	if not _load_error.is_empty():
		fail_setup(_load_error)
		return

	# One assertion per case keeps a failure readable; the case index and the
	# offending puzzle are named so the board can be reconstructed by hand.
	var mismatches: Array[String] = []

	for case_index in _cases.size():
		var c: Dictionary = _cases[case_index]
		var puzzle := Puzzle.from_json(c["puzzle"])
		var magnets: Array = []
		for m: Dictionary in c["magnets"]:
			magnets.append(_magnet(m))
		var balls := _positions(c["balls"])
		var acting: Magnet = magnets[0]

		var got_activate := Movement.activate(balls[0], acting, magnets, puzzle)
		var want_activate := _pos(c["activate"])
		if got_activate != want_activate:
			mismatches.append(
				"case %d activate: got %s, dart says %s" % [case_index, got_activate, want_activate]
			)

		var got_path := Movement.slide_path(balls[0], acting, magnets, puzzle)
		var want_path := _positions(c["slide_path"])
		if got_path != want_path:
			mismatches.append(
				"case %d slide_path: got %s, dart says %s" % [case_index, got_path, want_path]
			)

		var got_all := Movement.activate_all(balls, acting, magnets, puzzle)
		var want_all := _positions(c["activate_all"])
		if got_all != want_all:
			mismatches.append(
				"case %d activate_all: got %s, dart says %s" % [case_index, got_all, want_all]
			)

		var got_paths := Movement.activate_all_paths(balls, acting, magnets, puzzle)
		var want_paths: Array = []
		for list: Array in c["activate_all_paths"]:
			want_paths.append(_positions(list))
		if got_paths != want_paths:
			mismatches.append(
				"case %d activate_all_paths: got %s, dart says %s"
				% [case_index, got_paths, want_paths]
			)

		var got_field := Movement.magnet_field(acting, puzzle)
		var want_field: Array = c["field"]
		if got_field.size() != want_field.size():
			mismatches.append(
				"case %d field size: got %d, dart says %d"
				% [case_index, got_field.size(), want_field.size()]
			)
		else:
			for i in got_field.size():
				var g: Dictionary = got_field[i]
				var w: Dictionary = want_field[i]
				var want_cell := _pos(w)
				var want_step := Vector2i(int(w["dr"]), int(w["dc"]))
				if g["cell"] != want_cell or g["step"] != want_step:
					mismatches.append(
						"case %d field[%d]: got %s/%s, dart says %s/%s"
						% [case_index, i, g["cell"], g["step"], want_cell, want_step]
					)
					break

		if mismatches.size() >= 5:
			break  # enough to diagnose; no point listing thousands

	assert_true(
		mismatches.is_empty(),
		"port diverges from the Dart reference:\n  %s" % "\n  ".join(mismatches),
	)
