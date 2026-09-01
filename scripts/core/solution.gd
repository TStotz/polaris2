@tool
class_name Solution
extends RefCounted

## A solution found by the [Solver].
##
## [member magnets] is the placement; [member sequence] is the activation order
## as indices into [member magnets] (the same magnet may appear more than once —
## repeated activation is allowed). [member magnet_count] is the objective
## difficulty measure.

## [Array] of [Magnet].
var magnets: Array = []

## [Array] of [int] — indices into [member magnets], in activation order.
var sequence: Array = []

var magnet_count: int = 0

## How many magnet sets the search examined before landing here. Diagnostics only.
var checked: int = 0


func _init(
	solution_magnets: Array, solution_sequence: Array, count: int, sets_checked: int = 0
) -> void:
	magnets = solution_magnets
	sequence = solution_sequence
	magnet_count = count
	checked = sets_checked


func activation_count() -> int:
	return sequence.size()


## Human-readable difficulty derived from the minimal magnet count.
static func difficulty_label(count: int) -> String:
	if count <= 0:
		return "Ungelöst"
	if count <= 1:
		return "Sehr leicht"
	if count == 2:
		return "Leicht"
	if count == 3:
		return "Mittel"
	if count == 4:
		return "Schwer"
	return "Sehr schwer"
