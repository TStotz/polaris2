@tool
class_name Difficulty
extends RefCounted

## How hard a generated puzzle should be.
##
## Difficulty here is **how hard the solution is to find**, not just how big it
## is. Three forces are stacked on top of the magnet count:
##
##  - finite [member Puzzle.magnet_strength] + [member Puzzle.single_use] make a
##    magnet a stepping stone, so a distant target needs a *chain* of distinct
##    magnets;
##  - a **tight budget** (exactly the magnets the solution uses) removes the
##    slack a player would otherwise brute-force with;
##  - **scarcity + detours**: candidates are filtered to those with at most
##    `max_solutions` distinct minimal solutions and, for harder bands, a
##    *non-monotone* solution (the ball must retreat from the target at least
##    once). An open, monotone puzzle with dozens of interchangeable solutions is
##    trivial no matter how many magnets it needs.
##
## The bands still map to a magnet count, but each is genuinely a search:
##
##  - [constant EASY]   — 2 magnets, up to 3 solutions, no forced detour.
##  - [constant MEDIUM] — 3 magnets, <=2 solutions, must detour.
##  - [constant HARD]   — 4+ magnets, <=2 solutions, must detour.
##
## Construction hints (`strength`, `chain`, wall counts) only *bias* generation;
## the [Solver] is still the ground truth, so they affect how many tries are
## needed, never correctness.

# Named Band, not Level: `Level` is taken by the campaign class, and GDScript
# resolves a bare `Level` in a type position to that global class instead of this
# enum — which silently made generator.gd unloadable.
enum Band { EASY, MEDIUM, HARD }

## Band parameters, keyed by [enum Band]:
##  - `label`: short selector label — the band's target minimal magnet count;
##  - `min_magnets` / `max_magnets`: accepted band for the solver's minimal
##    magnet count, inclusive;
##  - `strength`: magnet strength for this band (cells travelled per activation);
##  - `chain`: how many stepping-stone magnets the construction tries to lay down;
##  - `min_walls` / `extra_walls`: wall-count range scattered onto the board.
##    Dense walls cut down the number of interchangeable solutions and force the
##    ball around obstacles;
##  - `max_solutions`: reject candidates with more distinct minimal solutions;
##  - `require_detour`: require the minimal solution to make the ball retreat
##    from the target at least once (a non-obvious "go away to come back" route).
const PARAMS := {
	Band.EASY: {
		"label": "2",
		"name": "Leicht",
		"min_magnets": 2,
		"max_magnets": 2,
		"strength": 2,
		"chain": 2,
		"min_walls": 8,
		"extra_walls": 5,
		"max_solutions": 3,
		"require_detour": false,
	},
	Band.MEDIUM: {
		"label": "3",
		"name": "Mittel",
		"min_magnets": 3,
		"max_magnets": 3,
		"strength": 2,
		"chain": 3,
		"min_walls": 9,
		"extra_walls": 5,
		"max_solutions": 2,
		"require_detour": true,
	},
	Band.HARD: {
		"label": "4+",
		"name": "Schwer",
		"min_magnets": 4,
		"max_magnets": 6,
		"strength": 2,
		"chain": 4,
		"min_walls": 9,
		"extra_walls": 5,
		"max_solutions": 2,
		"require_detour": true,
	},
}


static func params(band: Band) -> Dictionary:
	return PARAMS[band]


## Whether a candidate whose minimal solution uses [param magnet_count] magnets
## is in this band.
static func accepts(band: Band, magnet_count: int) -> bool:
	var p: Dictionary = PARAMS[band]
	return magnet_count >= p["min_magnets"] and magnet_count <= p["max_magnets"]


static func display_name(band: Band) -> String:
	return PARAMS[band]["name"]
