@tool
class_name Level
extends RefCounted

## One shipped level: the board, plus what the offline solver proved about it.
##
## [member par] is the objective difficulty measure — the fewest magnets any
## solution needs — and it is what the star rating scores against. [member solution]
## is that proven answer, kept for the hint feature: the game never has to search
## at runtime, it just replays what the pipeline already verified.

var id: int = 0
var chapter: String = ""
var puzzle: Puzzle

## Display name, set only on the hand-authored teaching levels ("Anziehen",
## "Wände stoppen", ...). Empty on generated levels, which are known by number.
var title: String = ""

## Minimal magnet count (the pipeline's difficulty measure).
var par: int = 0

## How many distinct minimal solutions the board has. 1 = unique, the hardest to
## find. 0 means "not measured" (multi-ball boards skip the exhaustive count).
var solution_count: int = 0

## The verified minimal solution: `{"magnets": Array[Magnet], "sequence": Array[int]}`.
var solution_magnets: Array = []
var solution_sequence: Array = []


static func from_json(data: Dictionary) -> Level:
	var level := Level.new()
	level.id = int(data["id"])
	level.chapter = str(data["chapter"])
	level.title = str(data.get("title", ""))
	level.puzzle = Puzzle.from_json(data["puzzle"])
	level.puzzle.id = level.id
	level.par = int(data.get("min_magnets", 0))
	level.solution_count = int(data.get("solution_count", 0))

	var solution: Dictionary = data.get("solution", {})
	for m: Dictionary in solution.get("magnets", []):
		var type := Magnet.Type.PLUS if m["t"] == "plus" else Magnet.Type.MINUS
		level.solution_magnets.append(Magnet.new(Vector2i(int(m["r"]), int(m["c"])), type))
	for step: float in solution.get("sequence", []):
		level.solution_sequence.append(int(step))
	return level


## Human-readable difficulty derived from [member par].
func difficulty_label() -> String:
	return Solution.difficulty_label(par)


## The proven solution as a [Solution], or null when the level ships without one.
func to_solution() -> Solution:
	if solution_magnets.is_empty():
		return null
	return Solution.new(solution_magnets, solution_sequence, par)
