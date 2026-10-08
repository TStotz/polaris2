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
##
## A board may ask for a longer one via [member SimLevel.max_ticks], and then
## [member run_ticks] is the number everybody reads. What had to survive is the
## rule that actually mattered — game, test and finder agree about a *given*
## board. Raising it globally was the lazy version: every grid proof would pay,
## and the two fairness sweeps in `test_sim.gd` are already 6 of the suite's 6.6
## seconds because they run losing plans all the way to the horizon.
const MAX_RUN_TICKS := 1200

## The horizon of the board currently set up: [member SimLevel.max_ticks], or
## [constant MAX_RUN_TICKS] when the board does not ask for its own.
##
## Resolved in [method setup], so a board's horizon is decided once and read by
## the game, the tests and the finder from the same place.
var run_ticks: int = MAX_RUN_TICKS

## Whether the run ended on a hazard rather than by leaving the world.
##
## Observation, like [member rode_mover] and the checkpoint ticks: nothing in the
## rules reads it and it never touches the checksum. The play screen wants it
## because the two deaths deserve different pictures — a ball that fell out of the
## arena simply goes, a ball that hit spikes comes apart where it was.
var hit_hazard := false

## How many magnets a player can actually hold: keys `1`..`6`.
##
## It was four for as long as a board's longest chain was four, and four is what
## caps how many stations a journey can have — one magnet up front plus one per
## gate. A five-station board needs six, and six is where the *hand* starts to be
## the limit rather than the bitmask: bits 0..15 are free below
## [constant INVERT_INPUT], so the mask has room for far more than a player has
## fingers. Raise it again only after watching someone reach for key 7.
##
## `test_a_level_never_promises_more_magnets_than_there_are_keys` holds every
## board to it, because a checkpoint hands its magnet out *during* the run — a
## board inside its budget at tick 0 can still promise a key that does not exist.
const HOLD_KEYS := 6

## Bit position in the input mask that reverses every active field this tick.
##
## It rides in the same one-integer-per-tick mask as the hold bits, well above
## the [constant HOLD_KEYS] magnet bits, so the rule that input is one bitmask per tick
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

## Tick each checkpoint was first reached, or -1. Observation only, like
## [member rode_mover]: it never feeds back into the motion and never enters the
## checksum, so a board with checkpoints computes exactly what it would without.
var checkpoint_ticks: Array[int] = []

## Highest checkpoint reached so far, or -1.
var checkpoint_reached: int = -1

## Tick each slow-motion point was first entered, or -1, and the highest one
## reached. Observation exactly like the checkpoints above — the play screen reads
## it to decide how fast to *draw*, and the rules never see it.
var slowmo_ticks: Array[int] = []
var slowmo_reached: int = -1

## Rolling checksum of the trajectory, so a divergence in the middle of a run is
## caught even when the final position happens to match.
var _checksum: int = 0

## Peak magnet force for this run: the level's own if it sets one, otherwise
## [constant MAGNET_STRENGTH]. Resolved once in [method setup], so the tick loop
## reads a float either way and a board on the default is bit-identical.
var _strength: float = MAGNET_STRENGTH

## Peak force of the level's own always-on fields. Equal to [member _strength]
## unless the board asked for its own — see [member SimLevel.field_strength].
var _field_strength: float = MAGNET_STRENGTH

var _solids: Array[Rect2] = []

## The level's own [member SimLevel.polygons], and a box around each one, worked
## out once. The box is a reject test, not geometry: a ball further than its own
## radius from it cannot touch the outline, and most polygons are nowhere near the
## ball in most ticks.
var _polygons: Array[PackedVector2Array] = []
var _polygon_bounds: Array[Rect2] = []

## [Array] of [SimLevel.MoverSpec]. Empty on every level that has none, which is
## what keeps those levels bit-identical to before movers existed.
var _movers: Array = []

## [Array] of [SimLevel.GravitySpec]. Same story: empty means the loop below never
## runs and gravity is the constant it always was.
var _zones: Array = []


## Prepares a run of [param sim_level] with the player's [param placed] magnets.
func setup(sim_level: SimLevel, placed: Array = []) -> void:
	level = sim_level
	magnets = sim_level.magnets_for(placed)

	_strength = sim_level.magnet_strength if sim_level.magnet_strength > 0.0 else MAGNET_STRENGTH
	run_ticks = sim_level.max_ticks if sim_level.max_ticks > 0 else MAX_RUN_TICKS
	# Defaults to the player's, so a board that never split the two computes exactly
	# what it always did.
	_field_strength = sim_level.field_strength if sim_level.field_strength > 0.0 else _strength
	_solids = sim_level.solids.duplicate()
	_polygons = sim_level.polygons
	_polygon_bounds.clear()
	for points: PackedVector2Array in _polygons:
		_polygon_bounds.append(SimLevel.polygon_bounds(points))
	_movers = sim_level.movers
	_zones = sim_level.zones
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
	hit_hazard = false
	checkpoint_reached = -1
	checkpoint_ticks.clear()
	for _c in level.checkpoints:
		checkpoint_ticks.append(-1)
	slowmo_reached = -1
	slowmo_ticks.clear()
	for _s in level.slowmo_points:
		slowmo_ticks.append(-1)
	_checksum = 0
	charges.clear()
	for _m in magnets:
		charges.append(level.charge_seconds)


## Adds a magnet to a run already under way, as the player placing one at a
## checkpoint does.
##
## Inserted *before* the level's own magnets, because that is where
## [method SimLevel.magnets_for] puts placed ones — so the array ends up exactly as
## a fresh [method setup] with the same placement list would build it, and the key
## a magnet answers to never shifts. Rebuilding the world from that list (which is
## what resuming from a checkpoint does) therefore reproduces this run.
##
## Nothing here runs unless a magnet is actually added, so every board that never
## calls it computes what it always did.
func add_magnet(spec: SimLevel.MagnetSpec) -> void:
	var at := magnets.size() - level.fixed_magnets.size()
	magnets.insert(at, spec)
	charges.insert(at, level.charge_seconds)


## Advances exactly one tick. [param held_mask] has bit `i` set while magnet `i`
## is being held down.
func step(held_mask: int) -> void:
	if outcome != Outcome.RUNNING:
		return

	var force_x := 0.0
	var force_y := GRAVITY

	# A flipped zone replaces gravity rather than adding to it: inside, down *is*
	# up. Choosing a sign is not an extra term, so a board with no zones computes
	# exactly what it always did — the pinned fingerprints prove it.
	for zone: SimLevel.GravitySpec in _zones:
		if zone.pulls_up_at(tick_count) and _in_rect(zone.rect, ball_x, ball_y):
			force_y = -GRAVITY
			break

	var inverted := (held_mask & INVERT_BIT) != 0
	for i in magnets.size():
		var magnet: SimLevel.MagnetSpec = magnets[i]
		# A magnet placed at a checkpoint does not exist before that checkpoint. One
		# comparison against a field that is 0 everywhere else, so the ticks a run
		# replays on the way back to its checkpoint compute what they computed the
		# first time — and boards without checkpoints stay bit-identical.
		if tick_count < magnet.spawn_tick:
			continue
		# Furniture needs no key and spends no charge; everything else takes exactly
		# the path it always took, so boards without furniture stay bit-identical.
		if not magnet.always_on:
			if (held_mask & (1 << i)) == 0:
				continue
			if charges[i] <= 0.0:
				continue
			charges[i] = charges[i] - TICK_DELTA
			if charges[i] < 0.0:
				charges[i] = 0.0
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
		# The level's own fields may be stronger or weaker than the player's. Choosing
		# between two numbers is a branch, not an extra term — and on a board that
		# never split them the two are equal, so the arithmetic is the arithmetic it
		# always was and the pinned fingerprints hold.
		var force: float = _field_strength if magnet.always_on else _strength
		var scale := force * falloff / distance
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

	# Launch plates, after the contacts so a plate lying on a floor is not undone by
	# the floor's own bounce in the same tick.
	#
	# The rule: while the ball is inside, its speed *along the plate's axis* is
	# exactly the plate's strength, and everything sideways is untouched. Setting it
	# rather than adding to it is what makes a plate plannable — see
	# [member SimLevel.springs] — and it is also what makes this idempotent, so no
	# "already bounced" state is needed.
	#
	# `sqrt` and the four operations only, and an empty list is a loop that does not
	# run, so boards without plates compute exactly what they always did.
	for spring: SimLevel.BounceSpec in level.springs:
		if not _touches(spring.rect):
			continue
		var reach := sqrt(spring.push.x * spring.push.x + spring.push.y * spring.push.y)
		if reach <= 0.0:
			continue
		var nx := spring.push.x / reach
		var ny := spring.push.y / reach
		var along := vel_x * nx + vel_y * ny
		if along >= reach:
			continue
		vel_x = vel_x - nx * along + spring.push.x
		vel_y = vel_y - ny * along + spring.push.y

	tick_count += 1
	_fold_checksum()

	for i in level.checkpoints.size():
		if checkpoint_ticks[i] >= 0:
			continue
		var cp: SimLevel.Checkpoint = level.checkpoints[i]
		if _in_rect(cp.rect, ball_x, ball_y):
			checkpoint_ticks[i] = tick_count
			if i > checkpoint_reached:
				checkpoint_reached = i

	for i in level.slowmo_points.size():
		if slowmo_ticks[i] >= 0:
			continue
		if _in_rect(level.slowmo_points[i], ball_x, ball_y):
			slowmo_ticks[i] = tick_count
			if i > slowmo_reached:
				slowmo_reached = i

	# Checked before the goal, so a board that puts the two within a ball's width of
	# each other kills rather than rewards. If both can fire on one tick the level
	# has a problem, and the safer reading is that the danger it drew is real.
	#
	# An empty list is a loop that does not run, so boards without hazards compute
	# exactly what they always did — the pinned fingerprints prove it.
	for hazard: Rect2 in level.hazards:
		if _touches(hazard):
			outcome = Outcome.LOST
			hit_hazard = true
			break

	if outcome == Outcome.RUNNING:
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
		for i in _polygons.size():
			_resolve_polygon(_polygons[i], _polygon_bounds[i])
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

	_push_out(normal_x, normal_y, penetration, plat_vx, plat_vy)


## One contact against a wall of any shape.
##
## Only the search for the nearest point is new. What happens once it is found —
## pushing out, bouncing, rubbing — is [method _push_out], the same function a box
## uses, which is the whole argument for why slopes did not need a new contact
## model: the bounce was always written along an arbitrary normal, and only the
## box's nearest-point query was axis-aligned.
##
## The nearest point is the closest point over every edge, found with a projection
## and a clamp: `+ - * /` and one `sqrt`, all exact in IEEE 754, so a polygon is as
## reproducible as a box. Inside or outside comes from an even-odd crossing count,
## which is comparisons and one division per edge that straddles the ball.
##
## A concave corner touches two edges at once. This resolves the nearer one per
## pass, and the second pass takes the other — the same argument that makes two
## passes enough for a ball wedged between two boxes. Not for a *sharp* notch,
## though: an inside angle much narrower than a right angle can leave the ball a
## little sunk after two passes, to be pushed out the tick after. Still exact,
## still reproducible; it just looks like a shiver. Build notches square or wider.
func _resolve_polygon(points: PackedVector2Array, bounds: Rect2) -> void:
	if (
		ball_x < bounds.position.x - BALL_RADIUS or ball_x > bounds.end.x + BALL_RADIUS
		or ball_y < bounds.position.y - BALL_RADIUS or ball_y > bounds.end.y + BALL_RADIUS
	):
		return

	var count := points.size()
	var inside := false
	var best := INF
	var near_x := 0.0
	var near_y := 0.0
	var edge_x := 0.0
	var edge_y := 0.0
	var last := count - 1
	for i in count:
		var a := points[last]
		var b := points[i]
		last = i
		# A ray to the right crosses this edge: count it. Straddling means the two
		# ends are on different sides of the ball's height, so b.y - a.y is never 0.
		if (a.y > ball_y) != (b.y > ball_y):
			var cross := a.x + (ball_y - a.y) * (b.x - a.x) / (b.y - a.y)
			if ball_x < cross:
				inside = not inside
		var ex := b.x - a.x
		var ey := b.y - a.y
		var length_squared := ex * ex + ey * ey
		var along := 0.0
		if length_squared > 0.0:
			along = _clamp(((ball_x - a.x) * ex + (ball_y - a.y) * ey) / length_squared, 0.0, 1.0)
		var px := a.x + ex * along
		var py := a.y + ey * along
		var dx := ball_x - px
		var dy := ball_y - py
		var distance_squared := dx * dx + dy * dy
		if distance_squared < best:
			best = distance_squared
			near_x = px
			near_y = py
			edge_x = ex
			edge_y = ey

	if not inside and best >= BALL_RADIUS * BALL_RADIUS:
		return

	var normal_x := 0.0
	var normal_y := 0.0
	var penetration := 0.0
	if best > 0.000001:
		var distance := sqrt(best)
		# Outside, the normal runs from the wall to the ball. Inside it runs the other
		# way — toward the nearest edge, which is the shortest way out — and the ball
		# has a whole radius plus that distance to travel.
		var side := -1.0 if inside else 1.0
		normal_x = (ball_x - near_x) / distance * side
		normal_y = (ball_y - near_y) / distance * side
		penetration = (BALL_RADIUS + distance) if inside else (BALL_RADIUS - distance)
	else:
		# The centre sits exactly on the outline, so there is no direction from the
		# wall to the ball to take. Out along the edge's perpendicular instead, on the
		# side the winding says is outside.
		var length := sqrt(edge_x * edge_x + edge_y * edge_y)
		if length <= 0.0:
			normal_y = -1.0
		else:
			var turn := 1.0 if winding(points) > 0.0 else -1.0
			normal_x = edge_y / length * turn
			normal_y = -edge_x / length * turn
		penetration = BALL_RADIUS

	_push_out(normal_x, normal_y, penetration, 0.0, 0.0)


## Twice the signed area of [param points]. Positive means the corners run
## clockwise *on screen* — y grows downward — and then an edge's outward side is
## `(ey, -ex)`: the top edge of a square listed left to right faces up.
##
## Public because the drawing needs the same answer: a lit cap on the wrong side of
## an edge would light the underside of a slope and leave its top dark.
static func winding(points: PackedVector2Array) -> float:
	var area := 0.0
	var last := points.size() - 1
	for i in points.size():
		area += points[last].x * points[i].y - points[i].x * points[last].y
		last = i
	return area


## Moves the ball out along [param normal_x]/[param normal_y] by [param penetration]
## and reflects its velocity, in the frame of whatever it hit.
##
## Lifted out of [method _resolve_one] unchanged, statement for statement, so that
## polygons could share it. Moving arithmetic into a function changes nothing about
## it — the values are the same doubles in the same order — and the pinned
## fingerprints are what say so, not this comment.
func _push_out(
	normal_x: float, normal_y: float, penetration: float, plat_vx: float, plat_vy: float
) -> void:
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
## How close a magnet has to be to beat gravity on *this* board.
##
## [constant LIFT_RADIUS] is the same number for the default strength; this one
## follows [member SimLevel.magnet_strength], which is what the reach rings have to
## draw or they would lie on a board that changed it.
func lift_radius() -> float:
	return MAGNET_RADIUS * (1.0 - GRAVITY / _strength)


## The same distance for the level's own fields, which since
## [member SimLevel.field_strength] may be a different number.
##
## Drawn, never simulated — but drawing the player's radius around a foreign field
## would be the same lie [method lift_radius] exists to prevent, one board further
## along.
func field_lift_radius() -> float:
	return MAGNET_RADIUS * (1.0 - GRAVITY / _field_strength)


## Ticks for one leg of [param travel] at [constant MAGNET_SWEEP_SPEED].
##
## `sqrt` only — exactly specified by IEEE 754 — and the result is an integer, so
## the path stays a pure function of the tick counter.
static func sweep_ticks(travel: Vector2) -> int:
	var length := sqrt(travel.x * travel.x + travel.y * travel.y)
	return maxi(1, int(length / MAGNET_SWEEP_SPEED * float(TICK_HZ)))


## Replays [param schedule] to its end. [param max_ticks] of 0 means this board's
## own horizon, [member run_ticks].
func run_schedule(schedule: Array, max_ticks: int = 0) -> Dictionary:
	reset()
	for t in (max_ticks if max_ticks > 0 else run_ticks):
		var mask := 0
		for entry: Array in schedule:
			if t >= int(entry[1]) and t < int(entry[2]):
				mask |= 1 << int(entry[0])
		step(mask)
		if outcome != Outcome.RUNNING:
			break
	return {"outcome": outcome, "ticks": tick_count, "hash": state_hash()}
