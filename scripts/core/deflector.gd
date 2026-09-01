@tool
class_name Deflector
extends RefCounted

## A diagonal deflector tile that turns a sliding ball 90°.
##
## On entering a deflector cell the ball's step `(dr, dc)` is rotated:
##  - [constant BACKSLASH] `\` maps `(dr, dc)` -> `(dc, dr)`  (right<->down, left<->up);
##  - [constant SLASH]     `/` maps `(dr, dc)` -> `(-dc, -dr)` (right<->up, left<->down).
##
## The turn is integer-exact and deterministic, so the ball's resting cell stays
## fully computable — the same predictability contract as a plain slide. The
## reflection itself lives in [Movement], the single source of truth for movement.

enum Dir { SLASH, BACKSLASH }

const NONE := -1


## Parses the JSON token ('slash' / 'backslash', or '/' / '\').
static func parse(s: String) -> Dir:
	return Dir.SLASH if (s == "slash" or s == "/") else Dir.BACKSLASH


static func to_token(dir: Dir) -> String:
	return "slash" if dir == Dir.SLASH else "backslash"
