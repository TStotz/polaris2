@tool
class_name SimWorld
extends RefCounted

## The deterministic simulation. One ball, static blocks, magnets.
##
## [b]This is the single source of truth for the rules[/b] — the game, any replay
## and any future level tool step the same [method step]. It is deliberately
## engine-free: no nodes, no [code]_physics_process[/code], no [RigidBody2D].
##
## [b]Why not Godot's physics?[/b] Fixed timestep alone does not buy
## reproducibility. Godot's solver gives no cross-platform guarantee, its
## iteration order is not part of its contract, and a body's rest state depends on
## internal tolerances that change between versions. A single circle against
## axis-aligned boxes is small enough to own outright, and owning it is what makes
## leaderboards and shared ghosts possible at all.
##
## [b]The determinism rules[/b], which every line here obeys:
##
##  - Time advances only in whole ticks of [constant TICK_DELTA]. The engine's
##    `delta` is never read — a frame drop must not change the outcome.
##  - Arithmetic is limited to `+ - * /` and `sqrt`. All five are exactly
##    specified by IEEE 754, so they give identical results on any conforming
##    machine. `sin`, `cos`, `pow` and `atan2` are **not** specified to the last
##    bit and appear nowhere in the simulation.
##  - No randomness, and no iteration over a Dictionary. Solids and magnets are
##    Arrays so the order is the order they were written in.
##  - Input arrives as one integer bitmask per tick, so there is nothing
##    continuous to sample at the wrong moment.
##
## [method state_hash] folds the whole trajectory into one integer, and
## `test_sim_determinism.gd` pins it. Anything that breaks a rule above — reading
## engine delta, calling `randf()`, reaching for `sin` — changes that number and
## fails the test.

enum Outcome { RUNNING, WON, LOST }

## 60 Hz, fixed. The number is part of the rules: changing it changes every
## recorded replay, so it belongs with the physics constants, not with settings.
const TICK_HZ := 60
const TICK_DELTA := 1.0 / 60.0

const GRAVITY := 1500.0
const BALL_RADIUS := 15.0

## Peak magnet force, at the magnet's centre, falling linearly to zero at
## [constant MAGNET_RADIUS].
##
## Linear rather than the physical inverse square: a real 1/r² spikes towards
## infinity at contact, so the ball snaps to the magnet and the input stops
## reading as steering. And a quadratic falloff left the outer two thirds of the
## drawn circle too weak to do anything, which made the reach a lie.
const MAGNET_STRENGTH := 2600.0
const MAGNET_RADIUS := 400.0

## Speed ceiling. Discrete integration steps past thin geometry above a certain
## speed; capping is cheaper and steadier than sub-stepping everything.
const MAX_SPEED := 1100.0

const RESTITUTION := 0.22  ## bounciness against solids

## Tangential loss per tick *while touching*. Small on purpose: at 60 Hz even
## 0.05 compounds to a 95% loss per second, which stops a rolling ball dead and
## makes every push feel like shoving through sand.
const FRICTION := 0.015
const AIR_DRAG := 0.002  ## per tick, keeps terminal speed finite

## Inside this distance a magnet's field beats gravity; outside it, it can only
## nudge a ball that is already moving.
##
## Derived, not chosen: the field falls off linearly, so it overpowers gravity
## exactly while MAGNET_STRENGTH * (1 - d / MAGNET_RADIUS) > GRAVITY. Worth having
## as a number because the drawn reach circle is [constant MAGNET_RADIUS] and says
## nothing about lifting — the play screen draws this one too, after a level asked
## the player to place a magnet that had to lift and gave them no way to see where
## that was possible.
const LIFT_RADIUS := MAGNET_RADIUS * (1.0 - GRAVITY / MAGNET_STRENGTH)

## How fast a magnet travels along a planned path, in pixels per second.
##
## Fixed rather than a second thing to dial in: the player draws *where* the
## magnet goes, and the speed follows from the length. One gesture, one decision.
const MAGNET_SWEEP_SPEED := 200.0

## How far outside the arena the ball may drift before the run counts as lost.
const OUT_OF_BOUNDS := 220.0

## The horizon for an offline run: 20 seconds. A ball that has neither won nor
## left the arena by then has come to rest somewhere harmless.
##
## It lives here, as one number, because a level tool and a verification test that
## disagree about it disagree about what "winnable" means. They did once: the
## replay finder capped runs at 480 ticks while `test_sim.gd` used 1200, so the
## finder cheerfully certified a schedule the test then rejected.
const MAX_RUN_TICKS := 1200

## Bit position in the input mask that reverses every active field this tick.
##
## It rides in the same one-integer-per-tick mask as the hold bits, well above
## the four magnet bits, so the rule that input is a single bitmask per tick
## survives untouched. In a hold schedule it appears as any other entry:
## `[INVERT_INPUT, an_tick, aus_tick]`.
##
## Deliberately **hold to invert**, not a toggle. A toggle would need memory of
## the previous tick, and one lost or duplicated tick would leave the polarity
## flipped for the rest of the run. Held, every tick stands on its own.
const INVERT_INPUT := 16
const INVERT_BIT := 1 << INVERT_INPUT

var level: SimLevel

var ball_x: float = 0.0
var ball_y: float = 0.0
var vel_x: float = 0.0
var vel_y: float = 0.0

## Remaining activation seconds per magnet, index-aligned with [member magnets].
var charges: Array[float] = []

## Every magnet in play: the level's fixed ones, then the player's.
var magnets: Array = []

var tick_count: int = 0
var outcome: Outcome = Outcome.RUNNING

## Whether the ball has touched a moving platform during this run. Observation
## only — it never feeds back into the motion and never enters the checksum. It
## exists so a test can ask whether a level that ships a moving platform actually
## needs it, the same way `test_every_placed_magnet_is_load_bearing` asks that of
## magnets.
var rode_mover: bool = false

## Rolling checksum of the trajectory, so a divergence in the middle of a run is
## caught even when the final position happens to match.
var _checksum: int = 0

var _solids: Array[Rect2] = []

## [Array] of [SimLevel.MoverSpec]. Empty on every level that has none, which is
## what keeps those levels bit-identical to before movers existed.
var _movers: Array = []


## Prepares a run of [param sim_level] with the player's [param placed] magnets.
func setup(sim_level: SimLevel, placed: Array = []) -> void:
	level = sim_level
	magnets = sim_level.magnets_for(placed)

	_solids = sim_level.solids.duplicate()
	_movers = sim_level.movers
	# Side walls, so a run cannot simply leave sideways. The floor is deliberately
	# not added: an open bottom is how a level says "missing means falling".
	var arena := sim_level.arena
	_solids.append(Rect2(arena.position.x - 60.0, arena.position.y - 400.0, 60.0, arena.size.y + 800.0))
	_solids.append(Rect2(arena.end.x, arena.position.y - 400.0, 60.0, arena.size.y + 800.0))
	reset()


## Rewinds to tick zero. Placement and geometry are untouched.
func reset() -> void:
	ball_x = level.start.x
	ball_y = level.start.y
	vel_x = 0.0
	vel_y = 0.0
	tick_count = 0
	outcome = Outcome.RUNNING
	rode_mover = false
	_checksum = 0
	charges.clear()
	for _m in magnets:
		charges.append(level.charge_seconds)


## Advances exactly one tick. [param held_mask] has bit `i` set while magnet `i`
## is being held down.
func step(held_mask: int) -> void:
	if outcome != Outcome.RUNNING:
		return

	var force_x := 0.0
	var force_y := GRAVITY

	var inverted := (held_mask & INVERT_BIT) != 0
	for i in magnets.size():
		if (held_mask & (1 << i)) == 0:
			continue
		if charges[i] <= 0.0:
			continue
		charges[i] = charges[i] - TICK_DELTA
		if charges[i] < 0.0:
			charges[i] = 0.0
		var magnet: SimLevel.MagnetSpec = magnets[i]
		# A magnet with no planned path returns its own coordinates unchanged here,
		# so boards without paths compute exactly what they always did.
		var at := magnet.position_at(tick_count)
		var dx := ball_x - at.x
		var dy := ball_y - at.y
		var distance := sqrt(dx * dx + dy * dy)
		if distance >= MAGNET_RADIUS:
			continue
		# Never divide by a distance smaller than this; at the exact centre the
		# direction is undefined and the force would explode.
		if distance < 8.0:
			distance = 8.0
		var falloff := 1.0 - distance / MAGNET_RADIUS
		var scale := MAGNET_STRENGTH * falloff / distance
		# Reversing is a decision about *which* branch is taken, not an extra term,
		# so a run that never inverts computes exactly what it computed before this
		# existed — the pinned fingerprints prove it.
		var attract := magnet.attract
		if inverted:
			attract = not attract
		if attract:
			scale = -scale
		force_x += dx * scale
		force_y += dy * scale

	# Semi-implicit Euler: velocity first, then position. Stabler than explicit
	# Euler at the same cost, and it is what every recorded replay assumes.
	vel_x += force_x * TICK_DELTA
	vel_y += force_y * TICK_DELTA

	var drag := 1.0 - AIR_DRAG
	vel_x *= drag
	vel_y *= drag

	var speed := sqrt(vel_x * vel_x + vel_y * vel_y)
	if speed > MAX_SPEED:
		var trim := MAX_SPEED / speed
		vel_x *= trim
		vel_y *= trim

	ball_x += vel_x * TICK_DELTA
	ball_y += vel_y * TICK_DELTA

	_resolve_contacts()

	tick_count += 1
	_fold_checksum()

	if _in_rect(level.target, ball_x, ball_y):
		outcome = Outcome.WON
	elif not _in_rect(level.arena.grow(OUT_OF_BOUNDS), ball_x, ball_y):
		outcome = Outcome.LOST


## Pushes the ball out of anything it has sunk into and reflects its velocity.
##
## Two passes, because a ball wedged in a corner touches two blocks and one pass
## would leave it inside the second. Two is enough for axis-aligned geometry and
## keeps the cost fixed — an unbounded loop would make the tick's duration depend
## on the situation, which is exactly what a fixed timestep is meant to avoid.
func _resolve_contacts() -> void:
	# Platforms are evaluated one tick ahead: the ball has already been integrated
	# through this tick, so the platform must be where it ends up too, not where it
	# started. Resolving against a stale rect lets a rising platform pass through
	# the ball.
	var at := tick_count + 1
	for _pass in 2:
		for solid: Rect2 in _solids:
			_resolve_one(solid, 0.0, 0.0)
		for mover: SimLevel.MoverSpec in _movers:
			var rect := mover.rect_at(at)
			if not rode_mover and _touches(rect):
				rode_mover = true
			var shift := mover.step_at(at)
			_resolve_one(rect, shift.x * TICK_HZ, shift.y * TICK_HZ)


## One contact, resolved in the block's own frame of reference.
##
## [param plat_vx]/[param plat_vy] are the block's velocity: zero for a wall, the
## platform's own for a mover. Doing the bounce and the friction on the *relative*
## velocity is what lets a platform carry the ball instead of scraping past it,
## and it costs the static case nothing — subtracting and re-adding zero is exact
## in IEEE 754, so every replay recorded before movers existed still hashes the
## same.
func _resolve_one(solid: Rect2, plat_vx: float, plat_vy: float) -> void:
	var closest_x := _clamp(ball_x, solid.position.x, solid.end.x)
	var closest_y := _clamp(ball_y, solid.position.y, solid.end.y)
	var dx := ball_x - closest_x
	var dy := ball_y - closest_y
	var distance_squared := dx * dx + dy * dy

	var normal_x := 0.0
	var normal_y := 0.0
	var penetration := 0.0

	if distance_squared > 0.000001:
		if distance_squared >= BALL_RADIUS * BALL_RADIUS:
			return
		var distance := sqrt(distance_squared)
		normal_x = dx / distance
		normal_y = dy / distance
		penetration = BALL_RADIUS - distance
	else:
		# Centre is inside the block: escape along the shallowest axis.
		var left := ball_x - solid.position.x
		var right := solid.end.x - ball_x
		var top := ball_y - solid.position.y
		var bottom := solid.end.y - ball_y
		var least := left
		normal_x = -1.0
		normal_y = 0.0
		if right < least:
			least = right
			normal_x = 1.0
			normal_y = 0.0
		if top < least:
			least = top
			normal_x = 0.0
			normal_y = -1.0
		if bottom < least:
			least = bottom
			normal_x = 0.0
			normal_y = 1.0
		penetration = least + BALL_RADIUS

	ball_x += normal_x * penetration
	ball_y += normal_y * penetration

	var rel_x := vel_x - plat_vx
	var rel_y := vel_y - plat_vy
	var along_normal := rel_x * normal_x + rel_y * normal_y
	if along_normal >= 0.0:
		return  # already separating
	# Reflect the normal component, damp the tangential one.
	var bounce := along_normal * (1.0 + RESTITUTION)
	rel_x -= normal_x * bounce
	rel_y -= normal_y * bounce
	var dot := rel_x * normal_x + rel_y * normal_y
	var tangent_x := rel_x - normal_x * dot
	var tangent_y := rel_y - normal_y * dot
	rel_x -= tangent_x * FRICTION
	rel_y -= tangent_y * FRICTION
	vel_x = rel_x + plat_vx
	vel_y = rel_y + plat_vy


func _touches(solid: Rect2) -> bool:
	var dx := ball_x - _clamp(ball_x, solid.position.x, solid.end.x)
	var dy := ball_y - _clamp(ball_y, solid.position.y, solid.end.y)
	return dx * dx + dy * dy < BALL_RADIUS * BALL_RADIUS


static func _clamp(value: float, low: float, high: float) -> float:
	if value < low:
		return low
	if value > high:
		return high
	return value


static func _in_rect(rect: Rect2, x: float, y: float) -> bool:
	return (
		x >= rect.position.x
		and x <= rect.end.x
		and y >= rect.position.y
		and y <= rect.end.y
	)


## Folds this tick's state into the rolling checksum.
##
## Positions are quantised to 1/64 px before hashing. The quantisation is not a
## weakening: two runs that agree to that resolution every tick for hundreds of
## ticks have not diverged, and it keeps the checksum from tripping over the last
## bit of a float that no player could ever perceive.
func _fold_checksum() -> void:
	var qx := int(ball_x * 64.0)
	var qy := int(ball_y * 64.0)
	var qvx := int(vel_x * 64.0)
	var qvy := int(vel_y * 64.0)
	_checksum = (_checksum * 31 + qx) & 0x7fffffff
	_checksum = (_checksum * 31 + qy) & 0x7fffffff
	_checksum = (_checksum * 31 + qvx) & 0x7fffffff
	_checksum = (_checksum * 31 + qvy) & 0x7fffffff


## One integer standing for the entire run so far. Two runs fed the same inputs
## must produce the same number.
func state_hash() -> int:
	return _checksum


## Runs [param schedule] from a fresh start and reports how it ended.
##
## [param schedule] is `[[magnet_index, on_tick, off_tick], ...]`. Returns
## `{"outcome": Outcome, "ticks": int, "hash": int}`.
## Ticks for one leg of [param travel] at [constant MAGNET_SWEEP_SPEED].
##
## `sqrt` only — exactly specified by IEEE 754 — and the result is an integer, so
## the path stays a pure function of the tick counter.
static func sweep_ticks(travel: Vector2) -> int:
	var length := sqrt(travel.x * travel.x + travel.y * travel.y)
	return maxi(1, int(length / MAGNET_SWEEP_SPEED * float(TICK_HZ)))


func run_schedule(schedule: Array, max_ticks: int = MAX_RUN_TICKS) -> Dictionary:
	reset()
	for t in max_ticks:
		var mask := 0
		for entry: Array in schedule:
			if t >= int(entry[1]) and t < int(entry[2]):
				mask |= 1 << int(entry[0])
		step(mask)
		if outcome != Outcome.RUNNING:
			break
	return {"outcome": outcome, "ticks": tick_count, "hash": state_hash()}
