@tool
class_name Magnet
extends RefCounted

## A magnet placed on the board.
##
## [member pos] is a grid cell as [Vector2i] with **x = row, y = col** — the
## board-wide convention (see [Movement]).

## The two magnet polarities (Modell A).
##
## [constant PLUS] attracts the ball, parking it directly next to the magnet.
## [constant MINUS] repels the ball, pushing it to the last free cell before a blocker.
enum Type { PLUS, MINUS }

## Sentinel for "not set" on [member strength] / [member reach], standing in for
## Dart's nullable ints: the puzzle-wide value is used instead.
const INHERIT := -1

var pos: Vector2i
var type: Type

## How many cells the ball travels when this magnet acts, overriding the
## puzzle's [member Puzzle.magnet_strength] when set ([constant INHERIT] -> use
## the puzzle value).
var strength: int

## How many cells away the magnet still grabs the ball (its field radius),
## overriding [member Puzzle.magnet_reach] when set ([constant INHERIT] -> use
## the puzzle value). Beyond it — or with a wall blocking the line — the magnet
## has no effect.
##
## [member strength] and [member reach] are independent: a short-reach,
## high-strength magnet is a contact catapult; a long-reach, low-strength one is
## a gentle nudge. These are the seam for future "special" magnets; today placed
## magnets leave both at [constant INHERIT] and use the puzzle's values.
var reach: int


func _init(
	p: Vector2i,
	t: Type,
	magnet_strength: int = INHERIT,
	magnet_reach: int = INHERIT,
) -> void:
	pos = p
	type = t
	strength = magnet_strength
	reach = magnet_reach


func is_plus() -> bool:
	return type == Type.PLUS


func is_minus() -> bool:
	return type == Type.MINUS


func equals(other: Magnet) -> bool:
	return (
		other != null
		and other.pos == pos
		and other.type == type
		and other.strength == strength
		and other.reach == reach
	)


func duplicate_magnet() -> Magnet:
	return Magnet.new(pos, type, strength, reach)


func _to_string() -> String:
	var s := "" if strength == INHERIT else "·s%d" % strength
	var r := "" if reach == INHERIT else "·r%d" % reach
	var n := "plus" if type == Type.PLUS else "minus"
	return "%s@(%d,%d)%s%s" % [n, pos.x, pos.y, s, r]
