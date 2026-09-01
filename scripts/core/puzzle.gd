@tool
class_name Puzzle
extends RefCounted

## A single puzzle definition.
##
## This is the immutable input to a game: the board geometry plus the magnet
## budget and the number of attempts. The mutable, in-progress state (placed
## magnets, activation sequence, attempts used) lives in [GameState].
##
## Cells are [Vector2i] with **x = row, y = col** (see [Movement]). Sets of cells
## ([member walls]) are Dictionaries used as sets: the cell is the key, `true`
## the value.

## Sentinel for an unlimited [member magnet_strength], standing in for Dart's
## `int?`.
const UNLIMITED := -1

var id: int = 0
var size: int = 6
var start: Vector2i = Vector2i.ZERO
var target: Vector2i = Vector2i.ZERO

## Wall cells, as a set (cell -> true).
var walls: Dictionary = {}

## Cells the ball must collect before the target counts as reached. A waypoint is
## collected the moment the ball touches its cell — whether it stops on it or
## merely slides through it. Order does not matter. Empty for a plain "reach the
## target" puzzle. [Array] of [Vector2i].
var waypoints: Array = []

## Diagonal deflector tiles, keyed by cell (cell -> [enum Deflector.Dir]). A
## sliding ball turns 90° on entering one. They are pure routing tiles: not
## blockers, and no magnet may be placed on them.
var deflectors: Dictionary = {}

## Extra balls beyond the primary [member start]/[member target]. Each entry is a
## Dictionary `{"start": Vector2i, "target": Vector2i}`, so ball `i+1` must
## arrive on `extra_balls[i].target`. Empty for a classic single-ball puzzle.
##
## A single activation moves **every** ball on the magnet's line at once, and
## balls are solid (they block each other and the magnetic slide, like magnets).
## That shared move is the whole point: one action that helps one ball can strand
## another. See [method ball_starts] / [method ball_targets] and
## [method Movement.activate_all].
var extra_balls: Array = []

## Pressure plates, keyed by cell -> channel. A ball touching one toggles every
## [Gate] on that channel — whether it stops on the plate or merely slides
## through, exactly like a waypoint.
##
## The toggle lands **after** the activation has fully resolved, so a slide is
## always computed against one consistent board. That also makes pressing a plate
## a move of its own, which is the whole point: it forces an order.
var plates: Dictionary = {}

## Gate tiles, keyed by cell -> [Gate]. A closed gate is a wall in every
## respect — it stops the ball and it cuts off a magnet's field.
var gates: Dictionary = {}

var plus_budget: int = 0
var minus_budget: int = 0
var max_runs: int = 5

## How many cells the ball *travels* in a single activation, or
## [constant UNLIMITED]. This is the magnet's **strength** (the push/pull
## distance); shorter values turn a magnet into a stepping stone rather than a
## teleport. A per-magnet [member Magnet.strength] overrides it.
var magnet_strength: int = UNLIMITED

## How many cells away a magnet still *grabs* the ball — its **reach** (field
## radius). Beyond it, or with a wall on the straight line between ball and
## magnet ([method blocks_reach]), the magnet has no effect. Always finite (a
## magnet's pull/push is never board-wide) and **required** so it can never be
## left unlimited by accident. Independent of [member magnet_strength]; a
## per-magnet [member Magnet.reach] overrides it.
var magnet_reach: int = 5

## When true, each magnet may be activated at most once per run (no re-pumping).
## Combined with a finite [member magnet_strength] this is the main lever for
## genuine difficulty: a distant target then needs a *chain* of distinct magnets,
## so the minimal magnet count scales with distance. Default false keeps the
## original "repeats allowed" rule.
var single_use: bool = false


## Builds a puzzle from a config Dictionary — GDScript's stand-in for named
## arguments. Required keys: `start`, `target`, `plus_budget`, `minus_budget`,
## `magnet_reach`. `walls` and `waypoints` take Arrays of [Vector2i].
static func create(config: Dictionary) -> Puzzle:
	var p := Puzzle.new()
	p.id = config.get("id", 0)
	p.size = config.get("size", 6)
	p.start = config.get("start", Vector2i.ZERO)
	p.target = config.get("target", Vector2i.ZERO)
	p.walls = _as_set(config.get("walls", []))
	p.waypoints = (config.get("waypoints", []) as Array).duplicate()
	p.deflectors = (config.get("deflectors", {}) as Dictionary).duplicate()
	p.extra_balls = (config.get("extra_balls", []) as Array).duplicate()
	p.plates = (config.get("plates", {}) as Dictionary).duplicate()
	p.gates = (config.get("gates", {}) as Dictionary).duplicate()
	p.plus_budget = config.get("plus_budget", 0)
	p.minus_budget = config.get("minus_budget", 0)
	p.max_runs = config.get("max_runs", 5)
	p.magnet_strength = config.get("magnet_strength", UNLIMITED)
	p.magnet_reach = config.get("magnet_reach", p.size - 1)
	p.single_use = config.get("single_use", false)
	return p


## A copy of this puzzle with the given fields replaced. Replaces the family of
## `_withX` copy helpers the Dart generator needed.
func with_overrides(overrides: Dictionary) -> Puzzle:
	var config := {
		"id": id,
		"size": size,
		"start": start,
		"target": target,
		"walls": walls.keys(),
		"waypoints": waypoints,
		"deflectors": deflectors,
		"extra_balls": extra_balls,
		"plates": plates,
		"gates": gates,
		"plus_budget": plus_budget,
		"minus_budget": minus_budget,
		"max_runs": max_runs,
		"magnet_strength": magnet_strength,
		"magnet_reach": magnet_reach,
		"single_use": single_use,
	}
	config.merge(overrides, true)
	return Puzzle.create(config)


## Accepts an Array of cells or an already-built set Dictionary.
static func _as_set(value: Variant) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate()
	var out := {}
	for cell: Vector2i in (value as Array):
		out[cell] = true
	return out


## Every ball's start, primary first: `[start, ...extra_balls.start]`.
func ball_starts() -> Array:
	var out: Array = [start]
	for b: Dictionary in extra_balls:
		out.append(b["start"])
	return out


## Every ball's target, index-aligned with [method ball_starts].
func ball_targets() -> Array:
	var out: Array = [target]
	for b: Dictionary in extra_balls:
		out.append(b["target"])
	return out


## Number of balls in play (always >= 1).
func ball_count() -> int:
	return 1 + extra_balls.size()


## True when the puzzle has more than one ball (shared-move rules apply).
func is_multi_ball() -> bool:
	return not extra_balls.is_empty()


func in_bounds(p: Vector2i) -> bool:
	return p.x >= 0 and p.x < size and p.y >= 0 and p.y < size


func is_wall(p: Vector2i) -> bool:
	return walls.has(p)


func is_target(p: Vector2i) -> bool:
	return p == target


func is_start(p: Vector2i) -> bool:
	return p == start


## Which ball's target sits on [param p], or -1. Index 0 is the primary ball.
func target_index_at(p: Vector2i) -> int:
	if p == target:
		return 0
	for i in extra_balls.size():
		if extra_balls[i]["target"] == p:
			return i + 1
	return -1


## Which ball starts on [param p], or -1. Index 0 is the primary ball.
func start_index_at(p: Vector2i) -> int:
	if p == start:
		return 0
	for i in extra_balls.size():
		if extra_balls[i]["start"] == p:
			return i + 1
	return -1


func is_waypoint(p: Vector2i) -> bool:
	return waypoints.has(p)


func is_deflector(p: Vector2i) -> bool:
	return deflectors.has(p)


## The deflector on [param p], or [constant Deflector.NONE].
func deflector_at(p: Vector2i) -> int:
	return deflectors.get(p, Deflector.NONE)


func is_plate(p: Vector2i) -> bool:
	return plates.has(p)


func is_gate(p: Vector2i) -> bool:
	return gates.has(p)


## Whether the gate on [param p] stands open under [param gate_mask]. Cells
## without a gate are trivially "open" — the caller asks this only about gates.
func gate_open(p: Vector2i, gate_mask: int) -> bool:
	var gate: Gate = gates.get(p)
	return gate == null or gate.is_open(gate_mask)


## Whether [param p] stops a ball: a wall, or a gate that is currently shut.
func blocks_ball(p: Vector2i, gate_mask: int = 0) -> bool:
	return is_wall(p) or (is_gate(p) and not gate_open(p, gate_mask))


## The channels the cells in [param paths] toggle. A channel flips once per
## activation no matter how many of its plates were crossed — two plates on one
## channel cancelling out would be a gotcha, not a puzzle.
func plates_toggled_by(paths: Array) -> int:
	if plates.is_empty():
		return 0
	var mask := 0
	for path: Array in paths:
		for cell: Vector2i in path:
			if plates.has(cell):
				mask |= 1 << int(plates[cell])
	return mask


## Whether a magnet of [param type] has its reach (field) blocked at cell
## [param p] on the straight line to the ball. Today every wall blocks both
## polarities; this is the seam for future wall types that let only pulling
## (plus) or only pushing (minus) fields pass — that logic will branch on
## [param type] here.
func blocks_reach(p: Vector2i, _type: Magnet.Type, gate_mask: int = 0) -> bool:
	return blocks_ball(p, gate_mask)


## A cell that can hold a magnet (free, not on any ball start/target, and not a
## waypoint or deflector). A magnet on a waypoint would make it impossible to
## collect, and a deflector is a fixed routing tile, so both are off-limits; with
## multiple balls every start and target is likewise off-limits.
func is_placeable(p: Vector2i) -> bool:
	return (
		in_bounds(p)
		and not is_wall(p)
		and start_index_at(p) == -1
		and target_index_at(p) == -1
		and not is_waypoint(p)
		and not is_deflector(p)
		# A magnet on a plate would make it impossible to press, and a gate cell
		# can turn solid underneath it.
		and not is_plate(p)
		and not is_gate(p)
	)


# --- Serialisation ---------------------------------------------------------

static func _pos(m: Dictionary) -> Vector2i:
	return Vector2i(int(m["r"]), int(m["c"]))


static func _pos_json(p: Vector2i) -> Dictionary:
	return {"r": p.x, "c": p.y}


static func from_json(json: Dictionary) -> Puzzle:
	var budget: Dictionary = json["budget"]
	var size: int = int(json.get("size", 6))

	var walls: Array = []
	for m: Dictionary in json.get("walls", []):
		walls.append(_pos(m))

	var waypoints: Array = []
	for m: Dictionary in json.get("waypoints", []):
		waypoints.append(_pos(m))

	var deflectors := {}
	for m: Dictionary in json.get("deflectors", []):
		deflectors[_pos(m)] = Deflector.parse(str(m["d"]))

	var extra_balls: Array = []
	for b: Dictionary in json.get("balls", []):
		extra_balls.append({"start": _pos(b["start"]), "target": _pos(b["target"])})

	var plates := {}
	for m: Dictionary in json.get("plates", []):
		plates[_pos(m)] = int(m["ch"])

	var gates := {}
	for m: Dictionary in json.get("gates", []):
		gates[_pos(m)] = Gate.new(int(m["ch"]), bool(m.get("open", false)))

	return Puzzle.create({
		# The level pack keeps the id on the level entry, not on the board, so a
		# puzzle payload without one is normal rather than malformed.
		"id": int(json.get("id", 0)),
		"size": size,
		"start": _pos(json["start"]),
		"target": _pos(json["target"]),
		"walls": walls,
		"waypoints": waypoints,
		"deflectors": deflectors,
		"extra_balls": extra_balls,
		"plates": plates,
		"gates": gates,
		"plus_budget": int(budget["plus"]),
		"minus_budget": int(budget["minus"]),
		"max_runs": int(json.get("max_runs", 5)),
		"magnet_strength": int(json.get("magnet_strength", UNLIMITED)),
		# Reach is always finite; a board that omits it falls back to its full
		# span rather than "unlimited".
		"magnet_reach": int(json.get("magnet_reach", size - 1)),
		"single_use": bool(json.get("single_use", false)),
	})


func to_json() -> Dictionary:
	var wall_list: Array = []
	for cell: Vector2i in walls.keys():
		wall_list.append(_pos_json(cell))

	var waypoint_list: Array = []
	for cell: Vector2i in waypoints:
		waypoint_list.append(_pos_json(cell))

	var deflector_list: Array = []
	for cell: Vector2i in deflectors.keys():
		var entry := _pos_json(cell)
		entry["d"] = Deflector.to_token(deflectors[cell])
		deflector_list.append(entry)

	var plate_list: Array = []
	for cell: Vector2i in plates.keys():
		var entry := _pos_json(cell)
		entry["ch"] = plates[cell]
		plate_list.append(entry)

	var gate_list: Array = []
	for cell: Vector2i in gates.keys():
		var gate: Gate = gates[cell]
		var entry := _pos_json(cell)
		entry["ch"] = gate.channel
		entry["open"] = gate.open_at_start
		gate_list.append(entry)

	var ball_list: Array = []
	for b: Dictionary in extra_balls:
		ball_list.append({"start": _pos_json(b["start"]), "target": _pos_json(b["target"])})

	return {
		"id": id,
		"size": size,
		"start": _pos_json(start),
		"target": _pos_json(target),
		"walls": wall_list,
		"waypoints": waypoint_list,
		"deflectors": deflector_list,
		"plates": plate_list,
		"gates": gate_list,
		"balls": ball_list,
		"budget": {"plus": plus_budget, "minus": minus_budget},
		"max_runs": max_runs,
		"magnet_strength": magnet_strength,
		"magnet_reach": magnet_reach,
		"single_use": single_use,
	}
