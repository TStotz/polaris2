@tool
class_name SimLevel
extends RefCounted

## One level's static data: geometry, the magnets it ships with, and how many the
## player may add.
##
## Pure data — no engine types beyond [Rect2] and [Vector2], no nodes. Everything
## the simulation reads lives here, so a level can be replayed headlessly in a
## test without a scene.

## A magnet in the world. [member attract] pulls the ball in, otherwise it pushes
## it away. [member fixed] magnets are part of the level and cannot be moved;
## the rest were placed by the player.
class MagnetSpec:
	var x: float
	var y: float
	var attract: bool
	var fixed: bool

	## Planned path, drawn before the run: the offset at the far end, and how many
	## ticks one leg takes. The magnet shuttles out and back for the whole run.
	##
	## A zero [member travel] is a plain static magnet, and [method position_at]
	## returns early for it — so every replay recorded before paths existed still
	## hashes the same, and the pinned fingerprints prove it.
	##
	## The path is decided *before* tick 0, which is what keeps it cheap: it is level
	## data, not input. The rule that input is one bitmask per tick is untouched, and
	## a recorded run needs no new fields.
	var travel: Vector2 = Vector2.ZERO
	var period: int = 1

	func _init(
		px: float, py: float, pulls: bool, is_fixed: bool = true,
		path: Vector2 = Vector2.ZERO, ticks: int = 1
	) -> void:
		x = px
		y = py
		attract = pulls
		fixed = is_fixed
		travel = path
		period = maxi(1, ticks)

	## Where the magnet is at [param tick].
	##
	## Triangle wave off the tick counter, same as [MoverSpec] and for the same
	## reason: `sin` is not bit-specified by IEEE 754. Nothing accumulates, so a long
	## run cannot drift and any tick is evaluable on its own.
	func position_at(tick: int) -> Vector2:
		if travel.x == 0.0 and travel.y == 0.0:
			return Vector2(x, y)
		var span := period * 2
		var t := tick % span
		if t < 0:
			t += span
		var leg := t if t < period else span - t
		var f := float(leg) / float(period)
		return Vector2(x + travel.x * f, y + travel.y * f)

	func moves() -> bool:
		return travel.x != 0.0 or travel.y != 0.0

	func duplicate_spec() -> MagnetSpec:
		return MagnetSpec.new(x, y, attract, fixed, travel, period)


## A platform that moves along a fixed, repeating path.
##
## Out along [member travel] over [member period] ticks, then back — a triangle
## wave, driven by the tick counter. Deliberately not a sine: `sin` is not
## specified to the last bit by IEEE 754, so it would break the one rule the
## simulation lives by. A triangle needs integer arithmetic and one divide.
##
## The path is a function of the tick alone. It does not accumulate, so a platform
## cannot drift out of phase over a long run, and any tick can be evaluated
## without replaying the ticks before it.
class MoverSpec:
	var rect: Rect2      ## where the platform sits at phase zero
	var travel: Vector2  ## its offset at the far end of the path
	var period: int      ## ticks for one leg; there and back is twice this
	var phase: int       ## tick offset, so several platforms can be staggered

	func _init(start_rect: Rect2, moves_by: Vector2, ticks: int, offset: int = 0) -> void:
		rect = start_rect
		travel = moves_by
		period = maxi(1, ticks)
		phase = offset

	## Position along the path at [param tick], running 0.0 → 1.0 → 0.0.
	func progress_at(tick: int) -> float:
		var span := period * 2
		var t := (tick + phase) % span
		if t < 0:
			t += span
		var leg := t if t < period else span - t
		return float(leg) / float(period)

	func rect_at(tick: int) -> Rect2:
		return Rect2(rect.position + travel * progress_at(tick), rect.size)

	## How far the platform moves during [param tick], in pixels. [SimWorld] turns
	## this into a velocity; the tick rate is deliberately not known here.
	func step_at(tick: int) -> Vector2:
		var span := period * 2
		var t := (tick + phase) % span
		if t < 0:
			t += span
		var direction := 1.0 if t < period else -1.0
		return travel * (direction / float(period))

	## Everything the platform ever covers. Used to keep magnets out of its path —
	## a magnet the platform drives through would be unreachable half the time.
	func swept_rect() -> Rect2:
		return rect.merge(Rect2(rect.position + travel, rect.size))

	func duplicate_spec() -> MoverSpec:
		return MoverSpec.new(rect, travel, period, phase)


var id: int = 0
var title: String = ""

## Which mechanic this board introduces. The menu groups by it, so the campaign
## reads as one level per feature rather than an undifferentiated list.
var feature: String = "Grundlagen"

## One line shown while placing — what this board is trying to teach.
var lesson: String = ""

var arena: Rect2 = Rect2(0, 0, 900, 660)
var start: Vector2 = Vector2(100, 80)

## Reaching any part of this rect wins.
var target: Rect2 = Rect2(0, 0, 0, 0)

## Solid, axis-aligned blocks. The arena's side walls are added by [SimWorld];
## a floor is only solid if a level lists one, so an open bottom means falling
## out is a loss.
var solids: Array[Rect2] = []

## Platforms that move. [Array] of [MoverSpec]. Kept apart from [member solids]
## so a level without any is byte-for-byte the simulation it was before movers
## existed.
var movers: Array = []

## Magnets baked into the level. [Array] of [MagnetSpec].
var fixed_magnets: Array = []

## Whether this board hands the player the reverse key.
##
## Per level rather than global: the earlier boards teach that attract parks the
## ball and repel drives it, and those lessons only hold while the polarity a
## magnet was placed with is the polarity it keeps.
var flip_enabled: bool = false

## Whether the player may drag a path for a magnet on this board.
##
## Per level like the reverse key, and for the same reason: the earlier boards
## teach what a magnet standing in one spot does, and those lessons hold only
## while it stays there.
var paths_enabled: bool = false

## Ticks of leeway this board must give on *when* to reverse. Default 15 (250 ms).
##
## Per level and not a constant, so a board that cannot meet the bar has to say so
## out loud in its own definition rather than the bar quietly dropping for
## everyone. Lowering it is an admission, not a fix.
var min_flip_window: int = 15

## How many magnets the player may add on top of [member fixed_magnets].
var budget: int = 0

## Seconds of activation each magnet carries. Spending it is the core decision,
## so levels tune it rather than sharing one global value.
var charge_seconds: float = 1.5

## A hold schedule proven to win this level, as `[[magnet_index, on_tick,
## off_tick], ...]`, plus the placements it assumes.
##
## Every shipped level carries one and `test_sim_levels.gd` replays it. This is
## the same contract the grid campaign had — no level ships unless something has
## actually beaten it — and it doubles as a demo and a ghost.
var par_placements: Array = []
var par_holds: Array = []


## Every magnet in play for a given set of player placements: the fixed ones
## first, then the placed ones, in placement order. Indices into this list are
## what the hold schedule and the number keys refer to.
func magnets_for(placed: Array) -> Array:
	var all: Array = []
	for spec: MagnetSpec in fixed_magnets:
		all.append(spec)
	for spec: MagnetSpec in placed:
		all.append(spec)
	return all
