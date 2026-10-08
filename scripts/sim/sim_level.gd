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

	## Level furniture: a field that is simply there.
	##
	## No key activates it and no charge limits it — it is part of the board, like a
	## wall is, and the player navigates *around* or *with* it rather than owning it.
	## This is the one use [member SimLevel.fixed_magnets] is meant for; a magnet the
	## player would otherwise have placed must never be built in.
	var always_on: bool = false

	## First tick this magnet exists. Everything before it, the magnet is not there
	## at all — no force, no charge, nothing drawn.
	##
	## It is what makes a magnet placed at a checkpoint honest: the ticks already
	## played must compute exactly what they computed the first time, or the prefix
	## the run resumes from would quietly become a different prefix. Zero for every
	## magnet placed before the start, so it is a skipped comparison and boards
	## without checkpoints stay bit-identical.
	var spawn_tick: int = 0

	func _init(
		px: float, py: float, pulls: bool, is_fixed: bool = true,
		path: Vector2 = Vector2.ZERO, ticks: int = 1, permanent: bool = false,
		born: int = 0
	) -> void:
		x = px
		y = py
		attract = pulls
		fixed = is_fixed
		travel = path
		period = maxi(1, ticks)
		always_on = permanent
		spawn_tick = born

	## Where the magnet is at [param tick].
	##
	## Triangle wave off the tick counter, same as [MoverSpec] and for the same
	## reason: `sin` is not bit-specified by IEEE 754. Nothing accumulates, so a long
	## run cannot drift and any tick is evaluable on its own.
	func position_at(tick: int) -> Vector2:
		if travel.x == 0.0 and travel.y == 0.0:
			return Vector2(x, y)
		var span := period * 2
		# Measured from the magnet's own first tick, so one placed mid-run starts at
		# the near end of its line instead of somewhere in the middle of a swing.
		# Identical for the usual spawn_tick of 0.
		var t := (tick - spawn_tick) % span
		if t < 0:
			t += span
		var leg := t if t < period else span - t
		var f := float(leg) / float(period)
		return Vector2(x + travel.x * f, y + travel.y * f)

	func moves() -> bool:
		return travel.x != 0.0 or travel.y != 0.0

	func duplicate_spec() -> MagnetSpec:
		return MagnetSpec.new(x, y, attract, fixed, travel, period, always_on, spawn_tick)


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


## A region where gravity flips, on a fixed beat.
##
## Inside [member rect] the pull is *upward* for [member period] ticks, then normal
## for the same, and so on. The state is a pure function of the tick counter and
## an integer comparison — no accumulation, no float phase, so it cannot drift and
## any tick can be evaluated on its own. Same discipline as [MoverSpec].
class GravitySpec:
	var rect: Rect2
	var period: int   ## ticks per half-cycle
	var phase: int    ## tick offset, so several zones can beat out of step

	func _init(area: Rect2, ticks: int, offset: int = 0) -> void:
		rect = area
		period = maxi(1, ticks)
		phase = offset

	func pulls_up_at(tick: int) -> bool:
		var span := period * 2
		var t := (tick + phase) % span
		if t < 0:
			t += span
		return t < period

	## How far through the current half-cycle, 0.0 to 1.0. Drawing only — the
	## simulation never needs it, and it is the number the player needs to see if
	## the flip is to be anticipated rather than guessed.
	func progress_at(tick: int) -> float:
		var span := period * 2
		var t := (tick + phase) % span
		if t < 0:
			t += span
		var within: int = t if t < period else t - period
		return float(within) / float(period)

	func duplicate_spec() -> GravitySpec:
		return GravitySpec.new(rect, period, phase)


## A plate that throws the ball. Not a magnet — see [member SimLevel.springs].
class BounceSpec:
	var rect: Rect2

	## The velocity it puts into the ball along its own axis, in px/s. Direction and
	## strength in one vector, so turning the plate turns what it does.
	var push: Vector2

	func _init(area: Rect2, impulse: Vector2 = Vector2(0.0, -900.0)) -> void:
		rect = area
		push = impulse

	func duplicate_spec() -> BounceSpec:
		return BounceSpec.new(rect, push)


## A point the run can be resumed from, and the magnets reaching it hands out.
##
## Reaching one does not stop or slow the ball — [member SimWorld] only records the
## tick. Everything else (pausing to place, retrying) is the play screen's job,
## because it concerns a *session*, not the physics.
class Checkpoint:
	var rect: Rect2
	var grants: int

	func _init(area: Rect2, extra_magnets: int = 1) -> void:
		rect = area
		grants = extra_magnets


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

## Walls of any shape: each one a closed outline, its corners in order. The last
## corner joins back to the first.
##
## **Given by corners, never by an angle.** A slope defined as "30 degrees" would
## need `sin` and `cos` to become geometry, and neither is exact in IEEE 754 — two
## machines could disagree about where the wall is. Corners on whole pixels are
## exact, and every angle this game has is the one they imply: 1:1, 1:2, 3:1.
##
## A separate list rather than a generalisation of [member solids], and that is
## what keeps the campaign where it is. The boxes still take the box path; a board
## with no polygons runs a loop that does not run, and the pinned fingerprints
## prove it.
##
## Must be *simple* — no edge crossing another, no corner twice, some area — or
## "inside" stops meaning anything. The build mode refuses to close one that is not
## ([method LevelSource.polygon_problem]); a hand-written one is the author's word.
var polygons: Array[PackedVector2Array] = []


## The smallest box around [param points]. Min and max only, so it is exact, and
## the simulation, the drawing and the build mode can all ask it and agree.
static func polygon_bounds(points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var low := points[0]
	var high := points[0]
	for point: Vector2 in points:
		low.x = minf(low.x, point.x)
		low.y = minf(low.y, point.y)
		high.x = maxf(high.x, point.x)
		high.y = maxf(high.y, point.y)
	return Rect2(low, high - low)

## Areas that end the run on contact — spikes, and whatever else a board draws
## into them. [Array] of [Rect2].
##
## A pure trigger, not a solid: the ball is not deflected, it is simply gone. There
## is nothing after the contact to bounce, so giving one a surface would be geometry
## nobody ever meets.
##
## The rectangle *is* the danger. What [BoardArt] draws inside it is a picture of
## that rule, so a spike whose tip pokes above its rect would promise a hit it does
## not deliver, and one that hides in the bottom half would kill from thin air.
##
## Empty on every board that has none, which is a loop that does not run — so those
## stay bit-identical, and the pinned fingerprints prove it.
var hazards: Array[Rect2] = []

## Plates that throw the ball. [Array] of [BounceSpec].
##
## **Not a magnet.** No polarity, no reach, no charge, no key: it acts on what is
## inside it and on nothing else. A magnet is a field you place and spend; this is
## a piece of the board you plan a route around.
##
## The rule is one sentence: **while the ball is inside, its speed along the
## plate's axis is exactly the plate's strength.** Everything sideways is left
## alone, so a ball rolling onto one keeps its forward speed and gains height —
## which is what a springboard is.
##
## Written that way rather than as "add the impulse", on purpose. Adding would make
## the jump depend on how fast the ball arrived, so one plate would send a quick
## ball twice as far as a slow one and no route through it could be planned.
## Setting it makes the plate a *statement* — from here you leave at this speed —
## and that is something a level can be built on. It also makes the rule
## idempotent, which is why no "already bounced" flag is needed: once the ball is up
## to speed, the plate has nothing left to do.
##
## A consequence worth knowing while building: a *thick* plate keeps holding the
## ball at that speed for as long as it is inside, so it reads as sustained thrust
## rather than a kick. Keep them thin for a springboard.
##
## Empty on every board that has none, which is a loop that does not run — so those
## stay bit-identical, and the pinned fingerprints prove it.
var springs: Array = []


## Waypoints, in order. [Array] of [Checkpoint]. A run is still one input sequence
## from tick 0; a checkpoint only marks a tick that sequence can be cut back to.
var checkpoints: Array = []

## Regions where gravity flips on a beat. [Array] of [GravitySpec]. Empty on every
## board that has none, which is what keeps those bit-identical.
var zones: Array = []

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

## Peak magnet force on this board, or 0 for the campaign default
## ([constant SimWorld.MAGNET_STRENGTH], 2600).
##
## Per level rather than global, and that is not timidity — it is the only way to
## change how heavy the ball feels without invalidating twelve proven replays. A
## board that leaves it at 0 computes exactly what it always did, down to the bit,
## and the pinned fingerprints prove it.
##
## What it buys: the force that beats gravity does so out to
## `MAGNET_RADIUS * (1 - GRAVITY / strength)`. At the default 2600 that is 169px,
## which is enough to steer a ball already rolling and *not* enough to feel like
## picking one up. Raise it and the ball can be lifted off a floor from a distance
## the player can actually aim at — which is what turns "steer" into "jump".
## What it does *not* cover: the level's own fields. Those follow
## [member field_strength], so a board can make the ball heavy in the player's hand
## and still have a field behind a wall strong enough to drag it up.
var magnet_strength: float = 0.0

## Peak force of this board's own always-on fields, or 0 for "same as
## [member magnet_strength]".
##
## Split from the player's strength because the two do different jobs and one
## number made them fight. Level 15's wall climb is the case that forced it: the
## foreign field has to *help lift* from behind a wall, which wants strength, while
## the player's magnet must not simply park the ball at itself, which wants
## restraint. A single number can serve one of those at a time.
##
## Zero means "whatever the player's magnets use", so every board written before
## this existed computes exactly what it always did — [SimWorld] picks between two
## equal numbers, which is a branch and not an extra term, and the pinned
## fingerprints prove it.
##
## Furniture only. A magnet the player placed is never touched by this, whatever
## the board says.
var field_strength: float = 0.0

## How many simulated ticks the slowed stretch lasts here, or 0 for the default
## ([constant PlayScreen.SLOW_TICKS], 25).
##
## The *place* was always the level's decision; the length had no business being
## global. On a board where the ball arrives at a platform and has to stop before
## it can be thrown the other way, the useful moment is well after the point is
## crossed — Level 14 measured 50 ticks between the two, so a 25-tick stretch was
## over before the decision it was meant to cover, and pressing inside it meant
## fighting the momentum instead of waiting it out.
##
## Presentation only, like the points themselves.
var slowmo_ticks: int = 0

## Regions that slow time down when the ball passes through them. [Array] of
## [Rect2].
##
## A *place*, like a checkpoint, and deliberately its own list. Slow motion first
## hung off the checkpoint and then off whether the ball had touched down, and both
## were wrong for the same reason: when the player needs time is a question the
## level should answer, not something to be derived from the ball's contact with
## the floor. A board that wants slowed time before a jump puts a point where the
## run-up starts.
##
## Level 13 puts them on its checkpoint rects — which is a choice that board makes,
## not a rule.
##
## Presentation only. [SimWorld] records the tick one is entered and nothing else:
## slow motion is fewer simulated ticks per second of wall clock, never a smaller
## tick, so the run is the same run either way and replays at full speed to the
## same result.
var slowmo_points: Array[Rect2] = []

## Id of the level this one is a geometric copy of, or 0.
##
## Level 12 is Level 11 built from the same function, differing only in the flag
## above — the point is to feel the same board with and without slowed time. The
## expensive grid proofs in `test_zz_find_replays.gd` skip a twin: they would spend
## a minute re-deriving an answer that already exists for the original, and the
## authoring suite has no room for that. The cheap per-level checks still run on
## both.
var twin_of: int = 0

## Ticks of leeway this board must give on *when* the run's first hold starts.
## Default 15 (250 ms).
##
## The sibling of [member min_flip_window], and it exists because a player found
## the gap it left. Level 11's opening shove had a 12-tick window: miss it and the
## ball dropped into the bridge gap, bounced there for the full 20-second horizon,
## and the run ended without ever reaching a checkpoint to fall back to. Every
## other test was green — a proven replay says the board is *solvable*, and says
## nothing at all about whether a human can hit it.
##
## Per level rather than global, for the same reason as the flip window: a board
## that cannot meet the bar has to say so out loud in its own definition instead of
## the bar quietly dropping for everyone. Lowering it is an admission, not a fix.
var min_timing_window: int = 15

## This board's run horizon in ticks, or 0 for the campaign default
## ([constant SimWorld.MAX_RUN_TICKS], 1200 = 20 s).
##
## Per level rather than global for one measured reason: the horizon is what a
## *losing* plan costs. The two fairness sweeps in `test_sim.gd` are 6.2 of the
## suite's 6.6 seconds, and the grid proofs in `test_zz_find_replays.gd` already
## sit at 200 s against a 300 s budget — tripling the number globally would have
## tripled both, to buy headroom for one board.
##
## What the horizon must never be is *two* numbers for the same board: the replay
## finder once capped at 480 while the test used 1200 and certified a schedule the
## test then rejected. [member SimWorld.run_ticks] resolves this once in
## [method SimWorld.setup], and game, test and finder all read it from there.
var max_ticks: int = 0

## Which world this board is dressed in, by name, or "" for the default.
##
## Presentation only, and more strictly so than anything else here: [SimWorld] does
## not read it, so two boards that differ only in their theme compute the same run
## down to the bit. It names an entry in [member PolarisTheme.WORLDS], and an
## unknown name falls back to the default — a typo costs the look, not the level.
##
## A world may repaint the background, the far blocks and the face of a wall. It
## may not touch the magnet colours, the goal, the checkpoint mint or the zone
## hues: those carry meaning the player has learned, and a board that recolours
## them is not a new world, it is a board that has to be read again from scratch.
var theme: String = ""

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


## Every magnet in play for a given set of player placements: the placed ones
## first, in placement order, then the level's own. Indices into this list are what
## the hold schedule and the number keys refer to.
##
## Placed first so the player's magnets are always keys 1..n starting at 1. With
## the level's furniture in front, a board with one built-in field would have put
## the player's own magnet on key 2, and a hold schedule's index would no longer
## match the key printed on the magnet. No shipped level has furniture yet, so the
## order costs nothing to fix now.
func magnets_for(placed: Array) -> Array:
	var all: Array = []
	for spec: MagnetSpec in placed:
		all.append(spec)
	for spec: MagnetSpec in fixed_magnets:
		all.append(spec)
	return all
