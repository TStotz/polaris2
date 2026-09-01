@tool
class_name Gate
extends RefCounted

## A gate tile: solid when closed, empty when open.
##
## Gates belong to a [member channel]. Every plate on the same channel toggles
## every gate on it, so a channel is one linked mechanism. [member open_at_start]
## lets a level ship gates that begin open and slam shut, not only the other way
## round.
##
## The live open/closed state is **not** stored here. It lives in a per-run
## bitmask of toggled channels that the movement rules take as an argument, so
## the puzzle definition stays immutable and a slide is always evaluated against
## exactly one board.

var channel: int
var open_at_start: bool


func _init(gate_channel: int, opens_at_start: bool = false) -> void:
	channel = gate_channel
	open_at_start = opens_at_start


## Whether this gate stands open given the run's [param gate_mask].
func is_open(gate_mask: int) -> bool:
	var toggled := (gate_mask & (1 << channel)) != 0
	return open_at_start != toggled  # XOR


func _to_string() -> String:
	return "gate(ch%d%s)" % [channel, ",open" if open_at_start else ""]
