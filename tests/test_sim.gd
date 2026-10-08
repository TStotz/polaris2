@tool
extends McpTestSuite

## The two guarantees the real-time game rests on.
##
## **1 — Determinism.** The same inputs must produce the same run, tick for tick.
## Without it there are no leaderboards, no shared ghosts, and no way to ship a
## level with a proven solution. This is the property that made owning the physics
## worth it instead of using [RigidBody2D].
##
## **2 — Every shipped level is winnable.** Each one carries a hold schedule that
## has actually beaten it (found by `test_zz_find_replays.gd`), and this suite
## replays all of them. It is the same contract the grid campaign had, carried
## across the rewrite: nothing ships unproven.

func suite_name() -> String:
	return "sim"


func _world(level: SimLevel, placed: Array = []) -> SimWorld:
	var world := SimWorld.new()
	world.setup(level, placed)
	return world


# --- Determinism ------------------------------------------------------------

func test_the_same_inputs_replay_identically() -> void:
	var level := Levels.by_id(5)
	var placed := _copy(level.par_placements)
	var first := _world(level, placed).run_schedule(level.par_holds)
	var second := _world(level, _copy(level.par_placements)).run_schedule(level.par_holds)

	assert_eq(first["hash"], second["hash"], "two identical runs must agree bit for bit")
	assert_eq(first["ticks"], second["ticks"])
	assert_eq(first["outcome"], second["outcome"])


func test_a_fresh_world_reproduces_a_reused_one() -> void:
	# Catches state that leaks across runs — a charge not refilled, a velocity not
	# cleared. Reusing one world and resetting it must match a brand new one.
	var level := Levels.by_id(3)
	var reused := _world(level, _copy(level.par_placements))
	reused.run_schedule(level.par_holds)
	var again := reused.run_schedule(level.par_holds)
	var fresh := _world(level, _copy(level.par_placements)).run_schedule(level.par_holds)
	assert_eq(again["hash"], fresh["hash"], "reset must leave no trace of the previous run")


func test_one_different_tick_changes_the_hash() -> void:
	# A checksum that cannot tell runs apart would make the tests above vacuous.
	var level := Levels.by_id(1)
	var normal := _world(level, _copy(level.par_placements)).run_schedule(level.par_holds)
	var nudged := _world(level, _copy(level.par_placements)).run_schedule([[0, 6, 76]])
	assert_ne(normal["hash"], nudged["hash"], "a one-tick shift must be visible in the hash")


func test_the_simulation_never_reads_engine_time() -> void:
	# Stepping by hand, with no scene tree and no frames elapsing at all, must
	# still produce the level's proven result. If anything reached for the
	# engine's delta or clock, this would diverge.
	var level := Levels.by_id(2)
	var world := _world(level, _copy(level.par_placements))
	for t in 400:
		var mask := 0
		for entry: Array in level.par_holds:
			if t >= int(entry[1]) and t < int(entry[2]):
				mask |= 1 << int(entry[0])
		world.step(mask)
		if world.outcome != SimWorld.Outcome.RUNNING:
			break
	assert_eq(world.outcome, SimWorld.Outcome.WON)


# --- Physics sanity ---------------------------------------------------------

func test_the_ball_falls_and_comes_to_rest_on_a_floor() -> void:
	var level := Levels.by_id(1)
	var world := _world(level)
	for _t in 180:
		world.step(0)
	assert_true(
		absf(world.ball_y - (420.0 - SimWorld.BALL_RADIUS)) < 2.0,
		"should settle on the floor at y=420, got %.1f" % world.ball_y
	)
	assert_true(absf(world.vel_y) < 12.0, "and stop bouncing, got %.1f" % world.vel_y)


func test_a_magnet_out_of_reach_does_nothing() -> void:
	var level := Levels.by_id(1)
	# The level's own par placement, since no level builds a magnet in any more.
	var held := _world(level, _copy(level.par_placements)).run_schedule([[0, 5, 35]])
	var idle := _world(level, _copy(level.par_placements)).run_schedule([])
	assert_ne(held["hash"], idle["hash"], "holding a magnet in reach must change the run")


func test_charge_runs_out() -> void:
	# A magnet parked far out of reach, on the one board with a floor across its
	# whole width. The ball settles and nothing else happens, so the run cannot end
	# early — and the charge still drains, because holding costs whether or not the
	# field reaches anything.
	#
	# Deliberately independent of any level's par. Two earlier versions of this test
	# leaned on a specific board outliving its own charge, and both broke the moment
	# that board got a faster solution.
	var level := Levels.by_id(1)
	var world := _world(level, [SimLevel.MagnetSpec.new(860, 60, false, false)])
	world.run_schedule([[0, 0, 400]], 400)
	assert_eq(world.charges[0], 0.0, "charge must bottom out at exactly zero, never below")


func test_the_ball_stays_inside_the_arena_or_loses() -> void:
	var level := Levels.by_id(5)
	var world := _world(level, _copy(level.par_placements))
	world.run_schedule(level.par_holds)
	# Whatever happened, it ended in a defined state rather than drifting forever.
	assert_ne(world.outcome, SimWorld.Outcome.RUNNING)


# --- Every level is winnable ------------------------------------------------

func test_every_level_ships_a_proven_replay() -> void:
	var missing: Array[String] = []
	for level: SimLevel in Levels.all():
		if level.par_holds.is_empty():
			missing.append("%d %s" % [level.id, level.title])
	assert_true(missing.is_empty(), "levels without a par replay: %s" % ", ".join(missing))


func test_every_par_replay_wins() -> void:
	var failures: Array[String] = []
	for level: SimLevel in Levels.all():
		var world := _world(level, _copy(level.par_placements))
		var result := world.run_schedule(level.par_holds)
		if result["outcome"] != SimWorld.Outcome.WON:
			failures.append(
				"Level %d %s endete als %s nach %d Ticks"
				% [level.id, level.title, _outcome_name(result["outcome"]), result["ticks"]]
			)
	assert_true(failures.is_empty(), "\n  ".join(failures))


## The trajectory hashes of the shipped replays, pinned to literals.
##
## `[level id, ticks, hash]`. Every other determinism test here compares runs
## against each other, which cannot see a change that moves *all* runs the same
## way — a tweak to gravity, restitution or the contact solver would leave them
## all passing. These numbers are the absolute reference.
##
## They are not sacred: change the physics on purpose and these change with it.
## Then re-verify the par replays still win and re-pin. What must never happen is
## them changing without anyone noticing.
## Ticks and trajectory hash per level, as literals. Intent may change them.
const PAR_FINGERPRINTS := [

	[1, 73, 1440854023],
	[2, 43, 1583506679],
	[3, 75, 1327488285],
	[4, 199, 948528529],
	[5, 227, 120131000],
	[6, 295, 944500438],
	[7, 59, 769956630],
	[8, 216, 2027035587],
	[9, 80, 122766518],
	[10, 114, 151283026],
	[11, 299, 1276947690],
	# Level 12 is Level 11's board built by the same function; slowed time is
	# presentation and never reaches the simulation, so the two must pin identically.
	# If these ever drift apart, something that should have stayed in the play screen
	# has leaked into the rules.
	[12, 299, 1276947690],
	[13, 396, 1039007152],
	[14, 353, 140499595],
	[15, 967, 834420538],
]


func test_par_runs_match_their_pinned_fingerprint() -> void:
	var drift: Array[String] = []
	for row: Array in PAR_FINGERPRINTS:
		var level := Levels.by_id(int(row[0]))
		var world := _world(level, _copy(level.par_placements))
		var result := world.run_schedule(level.par_holds)
		if int(result["ticks"]) != int(row[1]) or int(result["hash"]) != int(row[2]):
			drift.append(
				"Level %d: %d Ticks / Hash %d — erwartet %d / %d"
				% [row[0], result["ticks"], result["hash"], row[1], row[2]]
			)
	assert_true(drift.is_empty(), "
  ".join(drift))


## A level that ships a moving platform has to actually need it.
##
## The campaign is one level per mechanic, so a board filed under "Bewegte
## Plattformen" whose replay never touches the platform is mis-filed — it teaches
## nothing about the thing it is named after. Same reasoning as the load-bearing
## rule below, one axis over.
func test_a_level_with_movers_actually_rides_one() -> void:
	var unused: Array[String] = []
	for level: SimLevel in Levels.all():
		if level.movers.is_empty():
			continue
		var world := _world(level, _copy(level.par_placements))
		world.run_schedule(level.par_holds)
		if not world.rode_mover:
			unused.append("Level %d %s gewinnt, ohne die Plattform zu berühren" % [level.id, level.title])
	assert_true(unused.is_empty(), "
  ".join(unused))


## The zone's flow must not teleport when gravity flips.
##
## Not a simulation guarantee — it is about the drawing — but it lives here because
## it is the one thing about this feature that screenshots cannot check, and it was
## wrong three times running. The offending construction was a positive drift times
## the direction's sign, which moves every chevron by twice the drift in a single
## frame the moment the sign changes: measured, 62px per tick, 1.5 times a second.
##
## Walking whole ticks across several flips and bounding the frame-to-frame step is
## what a still image can never show.
func test_the_zone_flow_never_jumps() -> void:
	var zone := SimLevel.GravitySpec.new(Rect2(0, 0, 100, 400), 40)
	var worst := 0.0
	var worst_tick := -1
	var previous := BoardArt.zone_offset(zone.pulls_up_at(0), zone.progress_at(0))
	for tick in range(1, 400):
		var now := BoardArt.zone_offset(zone.pulls_up_at(tick), zone.progress_at(tick))
		var step := absf(now - previous)
		if step > worst:
			worst = step
			worst_tick = tick
		previous = now
	assert_true(
		worst < 6.0,
		"Der Fluss springt um %.1f px bei Tick %d — höchstens 6 sind ruhig" % [worst, worst_tick]
	)


## A level with a flipping-gravity zone has to need the zone.
##
## Same shape as the furniture rule: rebuild the board without its zones and the
## par must stop winning. The strict form — no placement at all wins without them
## — is in the authoring suite as `test_10_zone_is_required`.
func test_a_zone_level_actually_needs_it() -> void:
	var unused: Array[String] = []
	for level: SimLevel in Levels.all():
		if level.zones.is_empty():
			continue
		var flat := SimLevel.new()
		flat.arena = level.arena
		flat.start = level.start
		flat.target = level.target
		flat.solids = level.solids
		flat.movers = level.movers
		flat.fixed_magnets = level.fixed_magnets
		flat.budget = level.budget
		flat.charge_seconds = level.charge_seconds
		var world := SimWorld.new()
		world.setup(flat, _copy(level.par_placements))
		if world.run_schedule(level.par_holds)["outcome"] == SimWorld.Outcome.WON:
			unused.append("Level %d %s gewinnt auch ohne die Zone" % [level.id, level.title])
	assert_true(unused.is_empty(), "
  ".join(unused))


## A level that ships its own field has to need it.
##
## Furniture is the one thing a level may build in, and the price is that it must
## earn its place: remove it and the par must stop winning. The strict form — no
## placement of the player's own magnet wins without the furniture — lives in the
## authoring suite as `test_09_furniture_is_required`, because sweeping the whole
## grid is too slow to run on every change.
## A board can weaken or strengthen its own field without touching the player's.
##
## Two knobs that do different jobs: the foreign field has to *help lift* from
## behind a wall, while the player's magnet must not simply park the ball at
## itself. One number could serve one of those at a time — Level 15's wall climb
## is where that became a wall rather than an inconvenience.
##
## The half that matters most is the second assertion: set to the same number, the
## split computes the run it always computed. That is what keeps every
## fingerprint above a statement about physics rather than about a refactor.
## A plate sets the speed along its axis and leaves the rest alone.
##
## Both halves matter. The first is what makes it a springboard rather than a
## bumper; the second is what makes it *plannable* — a plate that added to the
## ball's speed would fling a quick ball twice as far as a slow one, and no route
## through it could be drawn in advance.
func test_a_plate_sets_the_speed_it_promises() -> void:
	var level := Levels.by_id(1)
	var plate := SimLevel.BounceSpec.new(Rect2(300.0, 380.0, 120.0, 20.0), Vector2(0.0, -700.0))
	level.springs.append(plate)

	var world := _world(level)
	world.ball_x = 360.0
	world.ball_y = 385.0
	world.vel_x = 240.0
	world.vel_y = 130.0
	world.step(0)

	assert_eq(roundf(world.vel_y), -700.0, "senkrecht nicht auf die Zusage gesetzt")
	# Sideways is untouched but for the tick's own air drag, which is 0.2%.
	assert_true(absf(world.vel_x - 240.0) < 2.0, "seitwärts verändert: %f" % world.vel_x)


## Standing on a plate does not wind the ball up.
##
## The rule is "your speed along the axis *is* this", not "add this", so applying it
## twice is applying it once. That is what lets the plate work without an "already
## bounced" flag — and the flag is the thing that would have to be reset, replayed
## and checksummed.
func test_a_plate_does_not_compound() -> void:
	var level := Levels.by_id(1)
	level.springs.append(SimLevel.BounceSpec.new(Rect2(300.0, 300.0, 120.0, 160.0), Vector2(0.0, -700.0)))
	var world := _world(level)
	world.ball_x = 360.0
	world.ball_y = 380.0
	world.vel_y = 0.0
	var seen: Array[float] = []
	for i in 4:
		world.step(0)
		seen.append(roundf(world.vel_y))
	for v: float in seen:
		assert_true(v <= -690.0 and v >= -710.0, "aufgeschaukelt: %s" % str(seen))


## A board with no plates computes what it always computed.
func test_a_board_without_plates_is_untouched() -> void:
	var level := Levels.by_id(11)
	assert_true(level.springs.is_empty(), "Level 11 hat ein Sprungfeld bekommen — Test anpassen")
	var straight := _world(level, _copy(level.par_placements)).run_schedule(level.par_holds)

	var harmless := Levels.by_id(11)
	harmless.springs.append(
		SimLevel.BounceSpec.new(Rect2(-9000.0, -9000.0, 10.0, 10.0), Vector2(0.0, -900.0))
	)
	var same := _world(harmless, _copy(harmless.par_placements)).run_schedule(harmless.par_holds)
	assert_eq(int(same["hash"]), int(straight["hash"]), "die Sprungfeld-Prüfung verschiebt die Bahn")
	assert_eq(int(same["ticks"]), int(straight["ticks"]), "die Sprungfeld-Prüfung verschiebt die Dauer")


## Touching a hazard ends the run, and says so.
##
## Two halves, and the second is the one the play screen depends on: the run has to
## be *lost* and [member SimWorld.hit_hazard] has to be set, because falling out of
## the world is also a loss and the two deserve different pictures.
func test_touching_a_hazard_ends_the_run() -> void:
	var level := Levels.by_id(1)
	# Standing on the floor the ball rolls along, between it and the goal. Not where
	# it *falls* — the first version of this sat above the roll line and the ball
	# sailed under it, which is the same mistake a level designer makes once.
	level.hazards.append(Rect2(400.0, 370.0, 40.0, 50.0))

	var world := _world(level, _copy(level.par_placements))
	var result := world.run_schedule(level.par_holds)
	assert_eq(int(result["outcome"]), SimWorld.Outcome.LOST, "die Zacken halten den Lauf nicht auf")
	assert_true(world.hit_hazard, "verloren, aber nicht als Zacken-Tod gemeldet")


## A board with no hazards computes what it always computed.
##
## The check was folded in next to the goal and the arena bounds, which meant
## restructuring the branch every run takes. An empty list has to be a loop that
## does not run, and nothing more — otherwise every pinned fingerprint above
## becomes a statement about this edit.
func test_a_board_without_hazards_is_untouched() -> void:
	var level := Levels.by_id(11)
	assert_true(level.hazards.is_empty(), "Level 11 hat Zacken bekommen — Test anpassen")
	var straight := _world(level, _copy(level.par_placements)).run_schedule(level.par_holds)

	var harmless := Levels.by_id(11)
	# A hazard far outside the arena: present in the list, never touched.
	harmless.hazards.append(Rect2(-9000.0, -9000.0, 10.0, 10.0))
	var world := _world(harmless, _copy(harmless.par_placements))
	var same := world.run_schedule(harmless.par_holds)

	assert_eq(int(same["hash"]), int(straight["hash"]), "die Zacken-Prüfung verschiebt die Bahn")
	assert_eq(int(same["ticks"]), int(straight["ticks"]), "die Zacken-Prüfung verschiebt die Dauer")
	assert_true(not world.hit_hazard, "unberührte Zacken melden einen Treffer")


## A hazard is a trigger, not a wall: it never deflects anything, because there is
## nothing left to deflect. A ball that dies on contact and a ball that bounces off
## would be two different rules wearing one name.
func test_a_hazard_never_pushes_the_ball_around() -> void:
	var level := Levels.by_id(1)
	level.hazards.append(Rect2(level.start.x - 200.0, level.start.y - 300.0, 40.0, 40.0))
	var world := _world(level, _copy(level.par_placements))
	var with_it := world.run_schedule(level.par_holds)
	var without := _world(Levels.by_id(1), _copy(level.par_placements)).run_schedule(level.par_holds)
	assert_eq(int(with_it["hash"]), int(without["hash"]), "eine unberührte Zacke lenkt den Ball ab")


func test_a_board_can_tune_its_own_field_apart_from_the_players() -> void:
	var plain := Levels.by_id(9)  # the board built around a foreign field
	var straight := _world(plain, _copy(plain.par_placements)).run_schedule(plain.par_holds)

	var weak := Levels.by_id(9)
	weak.field_strength = 600.0
	var crippled := _world(weak, _copy(weak.par_placements)).run_schedule(weak.par_holds)
	assert_true(
		int(crippled["hash"]) != int(straight["hash"]),
		"ein schwächeres Fremdfeld ändert den Lauf nicht — greift das Feld überhaupt?"
	)

	var same := Levels.by_id(9)
	same.field_strength = SimWorld.MAGNET_STRENGTH
	var unchanged := _world(same, _copy(same.par_placements)).run_schedule(same.par_holds)
	assert_eq(int(unchanged["hash"]), int(straight["hash"]), "die Aufteilung verschiebt die Bahn")
	assert_eq(int(unchanged["ticks"]), int(straight["ticks"]), "die Aufteilung verschiebt die Dauer")


func test_a_furniture_level_actually_needs_it() -> void:
	var unused: Array[String] = []
	for level: SimLevel in Levels.all():
		if level.fixed_magnets.is_empty():
			continue
		var bare := SimLevel.new()
		bare.arena = level.arena
		bare.start = level.start
		bare.target = level.target
		bare.solids = level.solids
		bare.movers = level.movers
		bare.budget = level.budget
		bare.charge_seconds = level.charge_seconds
		var world := SimWorld.new()
		world.setup(bare, _copy(level.par_placements))
		if world.run_schedule(level.par_holds)["outcome"] == SimWorld.Outcome.WON:
			unused.append("Level %d %s gewinnt auch ohne sein eigenes Feld" % [level.id, level.title])
	assert_true(unused.is_empty(), "
  ".join(unused))


## A level whose answer draws a path has to need the path.
##
## Freezing the magnet where the par puts it must stop the run winning. The strict
## form of this — no *static* magnet anywhere on the board wins — is too slow for
## every test run and lives in the authoring suite as
## `test_08_path_is_required`; this is the fast guard that the shipped answer is
## not simply a static magnet with a decorative line attached.
func test_a_path_level_actually_needs_the_path() -> void:
	var unused: Array[String] = []
	for level: SimLevel in Levels.all():
		var draws_path := false
		var frozen: Array = []
		for spec: SimLevel.MagnetSpec in level.par_placements:
			if spec.moves():
				draws_path = true
			frozen.append(SimLevel.MagnetSpec.new(spec.x, spec.y, spec.attract, false))
		if not draws_path:
			continue
		var world := _world(level, frozen)
		if world.run_schedule(level.par_holds)["outcome"] == SimWorld.Outcome.WON:
			unused.append("Level %d %s gewinnt auch mit stehendem Magneten" % [level.id, level.title])
	assert_true(unused.is_empty(), "
  ".join(unused))


## A level that hands out the reverse key has to need it.
##
## Same rule as the moving platform above, one mechanic over: drop the inversion
## from the par and the run must stop winning. Without this a board could sit
## under "Polarität umkehren" and be beatable by holding the magnet the whole way.
func test_a_flip_level_actually_needs_the_flip() -> void:
	var unused: Array[String] = []
	for level: SimLevel in Levels.all():
		if not level.flip_enabled:
			continue
		var without: Array = []
		for entry: Array in level.par_holds:
			if int(entry[0]) != SimWorld.INVERT_INPUT:
				without.append(entry)
		var world := _world(level, _copy(level.par_placements))
		if world.run_schedule(without)["outcome"] == SimWorld.Outcome.WON:
			unused.append("Level %d %s gewinnt auch ohne Umpolen" % [level.id, level.title])
	assert_true(unused.is_empty(), "
  ".join(unused))


## A reverse level has to be winnable across a window a person can actually hit.
##
## The first version of Level 7 was solvable, load-bearing and shipped a proven
## replay — every criterion above was satisfied — and it was still unplayable:
## measured tick by tick, exactly three flip timings won. 50 ms. The landing was
## far enough away that only a near-maximum throw reached it, so the window was
## the sliver where the throw was perfect. Moving the landing closer and lower
## turned that into 900 ms, because then any throw over a lower bound arrives.
##
## Nothing else in this suite could see that. "Es ist lösbar" and "es ist fair"
## are different claims.
func test_a_flip_level_gives_the_player_room_to_react() -> void:
	var tight: Array[String] = []
	for level: SimLevel in Levels.all():
		if not level.flip_enabled:
			continue
		var hold: Array = []
		var flip_from := 0
		var flip_to := 0
		for entry: Array in level.par_holds:
			if int(entry[0]) == SimWorld.INVERT_INPUT:
				flip_from = int(entry[1])
				flip_to = int(entry[2])
			else:
				hold.append(entry)
		# For each reverse *moment*, ask whether ANY release time wins from it. The
			# player controls both, so pinning the release to the par's and sweeping only
			# the flip measured a 1D slice of a 2D choice and badly understated the room
			# a person actually has.
		var hold_end := flip_to
		for entry: Array in hold:
			hold_end = maxi(hold_end, int(entry[2]))
		var winners := 0
		for start in range(1, flip_to):
			for release in range(start + 5, hold_end + 40, 5):
				var plan: Array = []
				for entry: Array in hold:
					plan.append([entry[0], entry[1], release])
				plan.append([SimWorld.INVERT_INPUT, start, release])
				var world := _world(level, _copy(level.par_placements))
				if world.run_schedule(plan)["outcome"] == SimWorld.Outcome.WON:
					winners += 1
					break
		if winners < level.min_flip_window:
			tight.append(
				"Level %d %s: nur %d Ticks (%d ms) treffen — mindestens %d nötig"
				% [level.id, level.title, winners, winners * 1000 / SimWorld.TICK_HZ, level.min_flip_window]
			)
	assert_true(tight.is_empty(), "
  ".join(tight))


## The rule Level 4 broke: a magnet the solution does not need is scenery.
##
## Its first replay won in 56 ticks while holding the second magnet from tick 220
## — long after the run was over. The level said "two magnets" and meant one. This
## is the same criterion the grid game applied to deflectors, and it exists for
## the same reason: a level that lies about what it needs teaches the wrong thing.
func test_every_placed_magnet_is_load_bearing() -> void:
	var idle: Array[String] = []
	for level: SimLevel in Levels.all():
		var world := _world(level, _copy(level.par_placements))
		for i in world.magnets.size():
			# Furniture has no holds to remove, so this question does not apply to it.
			# That it earns its place is checked harder elsewhere, by rebuilding the
			# level without it — see `test_a_furniture_level_actually_needs_it`.
			if (world.magnets[i] as SimLevel.MagnetSpec).always_on:
				continue
			var without: Array = []
			for entry: Array in level.par_holds:
				if int(entry[0]) != i:
					without.append(entry)
			if world.run_schedule(without)["outcome"] == SimWorld.Outcome.WON:
				idle.append("Level %d gewinnt auch ohne Magnet %d" % [level.id, i + 1])
	assert_true(idle.is_empty(), "
  ".join(idle))


## A replay that places more magnets than the level allows could never be
## reproduced by a player.
##
## Two pots, counted separately. Magnets born at tick 0 are the ones placed while
## planning and must match [member SimLevel.budget] exactly. The rest were earned
## at a gate during the run, so they may number at most what the gates hand out —
## and every one of them has to carry a birthday, or it would silently be a fifth
## magnet on the board from the start.
func test_par_placements_match_the_budget() -> void:
	var problems: Array[String] = []
	for level: SimLevel in Levels.all():
		var upfront := 0
		var earned := 0
		for spec: SimLevel.MagnetSpec in level.par_placements:
			if spec.spawn_tick == 0:
				upfront += 1
			else:
				earned += 1
		var grants := 0
		for cp: SimLevel.Checkpoint in level.checkpoints:
			grants += cp.grants
		if upfront != level.budget:
			problems.append(
				"Level %d setzt %d Magnete vor dem Start, Budget ist %d"
				% [level.id, upfront, level.budget]
			)
		if earned > grants:
			problems.append(
				"Level %d holt %d Magnete an Toren, die Tore geben %d her"
				% [level.id, earned, grants]
			)
		for spec: SimLevel.MagnetSpec in level.par_placements:
			for solid: Rect2 in level.solids:
				if solid.grow(SimWorld.BALL_RADIUS).has_point(Vector2(spec.x, spec.y)):
					problems.append("Level %d setzt einen Magneten in eine Wand" % level.id)
	assert_true(problems.is_empty(), "\n  ".join(problems))


## Solvable is not the same as hittable.
##
## A proven replay says a board *can* be beaten and says nothing about whether a
## human can hit the moment. Level 11 shipped with a 12-tick window (200 ms) on its
## opening shove — miss it and the ball dropped into the bridge gap, bounced there
## for the whole 20-second horizon, and the run ended without ever reaching a
## checkpoint to fall back to. Every other test in this file was green. A player
## found it, which is the wrong way round.
##
## So: shift the first hold of the par earlier and later, keep its length, and
## measure the longest run of consecutive shifts that still wins. That run is the
## leeway the board actually gives. The bar is [member SimLevel.min_timing_window],
## per level, so a board that misses it admits it in its own definition — the same
## arrangement as the reverse window, and for the same reason.
## Criterion 6 for *when you press* — and on a chained board it is measured one
## station at a time, not end to end.
##
## End to end measures the **product** of the stations' tolerances. Level 15 has
## five stations of 27, 22, 21, 21 and 19 ticks and a whole-chain window of
## **one**: every station comfortably fair, the five together a knife edge. Nobody
## has to hit that product. A gate hands the run back at the point it was reached,
## so what a player retries is the segment — and the segment is what has to be
## fair. Measured as a chain this board would have been rejected without a single
## tight press anywhere on it.
##
## A station runs from its own magnet to the birth of the next one, which is the
## gate that grants it; the last runs to the goal. A par that spends one magnet is
## therefore one station, measured exactly as before — Level 11 has a gate but its
## par never spends what the gate hands out, and its number does not move.
func test_the_par_gives_room_for_when_you_press() -> void:
	var tight: Array[String] = []
	for level: SimLevel in Levels.all():
		if level.par_holds.is_empty():
			continue
		if level.checkpoints.is_empty():
			# No gates, so no stations: the plan stands or falls as one piece and
			# the question is the old one — shift the first press, does it still
			# win. Measuring a station here would drop the magnets that come after
			# it from a plan that needs all of them, and report 0 for a board that
			# is fine.
			var wins: Array[int] = []
			for d in range(-20, 21):
				var first: Array = level.par_holds[0]
				if int(first[1]) + d < 0:
					continue  # nobody can press before the run begins
				if _shifted_par_wins(level, d):
					wins.append(d)
			var whole := _longest_run(wins)
			if whole < level.min_timing_window:
				tight.append(
					"Level %d %s gibt nur %d Ticks Spielraum, verlangt sind %d"
					% [level.id, level.title, whole, level.min_timing_window]
				)
			continue
		for stage in level.par_placements.size():
			var window := _segment_window(level, stage)
			if window < level.min_timing_window:
				tight.append(
					"Level %d %s: Station %d gibt nur %d Ticks Spielraum, verlangt sind %d"
					% [level.id, level.title, stage + 1, window, level.min_timing_window]
				)
	assert_true(tight.is_empty(), "\n  ".join(tight))


## Consecutive ticks of leeway station [param stage] gives on its own hold.
##
## Stations before it stay at par, so the run up to that point is identical and
## the magnet's birth tick still falls where the plan says it does. Stations after
## it are left off the board entirely — a later magnet spawning part-way through
## would perturb the very stretch being measured.
##
## Success is reaching the gate that grants the *next* magnet, because that is the
## point at which the stretch stops being the player's to redo. With no next
## magnet the station runs to the goal and success is a win.
func _segment_window(level: SimLevel, stage: int) -> int:
	var entry := _entry_for(level.par_holds, stage)
	if entry.is_empty():
		return 9999  # no hold of its own — nothing to be early or late with
	var spec: SimLevel.MagnetSpec = level.par_placements[stage]

	# Which gate ends this station: the one the next magnet is born at.
	var ends_at := -1
	if stage + 1 < level.par_placements.size():
		var later: SimLevel.MagnetSpec = level.par_placements[stage + 1]
		var par := _world(level, _copy(level.par_placements))
		par.run_schedule(level.par_holds)
		ends_at = par.checkpoint_ticks.find(later.spawn_tick)

	var wins: Array[int] = []
	for d in range(-20, 21):
		var on: int = int(entry[1]) + d
		if on < spec.spawn_tick or on < 0:
			continue  # nobody can press before the magnet exists
		var placed: Array = []
		for i in range(0, stage + 1):
			placed.append((level.par_placements[i] as SimLevel.MagnetSpec).duplicate_spec())
		var schedule: Array = []
		for e: Array in level.par_holds:
			var index := int(e[0])
			if index > stage and index != SimWorld.INVERT_INPUT:
				continue
			if index == stage:
				schedule.append([index, on, on + int(entry[2]) - int(entry[1])])
			else:
				schedule.append([index, int(e[1]), int(e[2])])
		var world := _world(level, placed)
		world.run_schedule(schedule)
		if ends_at >= 0:
			if world.checkpoint_ticks[ends_at] >= 0:
				wins.append(d)
		elif world.outcome == SimWorld.Outcome.WON:
			wins.append(d)
	return _longest_run(wins)


## Replays the par with its first hold moved by [param d] ticks, and reports
## whether it still wins.
##
## On a board whose later magnets are handed out at gates, moving the first press
## moves everything after it: the ball reaches each gate later, so the magnet it
## grants is born later and is held later. Holding those at their original ticks
## would measure a plan no player could make — Level 13 came out at 11 ticks that
## way and at a very different number once the chain was followed properly.
##
## Each earned magnet keeps its *relative* timing from the par: born when its gate
## is actually crossed, held after the same offset and for the same length. Boards
## whose magnets are all placed before the start have nothing to re-derive and are
## measured exactly as before.
func _shifted_par_wins(level: SimLevel, d: int) -> bool:
	var upfront: Array = []
	var earned: Array = []
	for i in level.par_placements.size():
		var spec: SimLevel.MagnetSpec = level.par_placements[i]
		if spec.spawn_tick == 0:
			upfront.append(i)
		else:
			earned.append(i)

	# Everything placed before the start, with the whole schedule moved by d.
	var placed := _copy(level.par_placements)
	var schedule: Array = []
	for entry: Array in level.par_holds:
		schedule.append([int(entry[0]), int(entry[1]) + d, int(entry[2]) + d])
	if earned.is_empty():
		return int(_world(level, placed).run_schedule(schedule)["outcome"]) == SimWorld.Outcome.WON

	# Chained boards: walk the gates and rebuild the later entries as they fall.
	for slot in earned.size():
		var index: int = earned[slot]
		var spec: SimLevel.MagnetSpec = level.par_placements[index]
		var original: Array = _entry_for(level.par_holds, index)
		if original.is_empty():
			continue
		var probe := _world(level, _copy(placed))
		probe.run_schedule(schedule)
		if slot >= probe.checkpoint_ticks.size():
			return false
		var gate: int = probe.checkpoint_ticks[slot]
		if gate < 0:
			return false
		var born := gate + (int(original[1]) - spec.spawn_tick)
		placed[index] = SimLevel.MagnetSpec.new(
			spec.x, spec.y, spec.attract, spec.fixed,
			spec.travel, spec.period, spec.always_on, gate
		)
		for entry: Array in schedule:
			if int(entry[0]) == index:
				entry[1] = born
				entry[2] = born + (int(original[2]) - int(original[1]))
	return int(_world(level, placed).run_schedule(schedule)["outcome"]) == SimWorld.Outcome.WON


## The hold entry belonging to magnet [param index], or an empty array.
func _entry_for(holds: Array, index: int) -> Array:
	for entry: Array in holds:
		if int(entry[0]) == index:
			return entry
	return []


## The longest stretch of consecutive values — a window is a stretch, not a count.
## Sixteen scattered winning shifts are not a window; nobody can aim at a comb.
func _longest_run(values: Array[int]) -> int:
	var best := 0
	var run := 0
	var previous := -999
	for v: int in values:
		run = run + 1 if v == previous + 1 else 1
		previous = v
		if run > best:
			best = run
	return best


# --- Checkpoints ------------------------------------------------------------

## How long one stretch between checkpoints may be.
##
## The lower bound because a gate the ball crosses a moment after the previous one
## is not a station but a duplicate. The upper bound because the whole reason
## checkpoints exist is that no *solved* stretch should have to be played again:
## the simulation is deterministic, so replaying eight seconds you have already
## beaten teaches nothing and tests nothing — it is a waiting room.
const SEGMENT_MIN_TICKS := 45
const SEGMENT_MAX_TICKS := 480


## Every checkpoint has to sit on the line the ball actually takes, and the
## stretches between them have to be stretches.
##
## A gate placed where the board *looks* like the route goes is worth nothing: the
## player would never cross it, the level would silently be one long segment again
## — and every other test would stay green.
func test_the_par_passes_every_checkpoint_in_order() -> void:
	var problems: Array[String] = []
	for level: SimLevel in Levels.all():
		if level.checkpoints.is_empty():
			continue
		var world := _world(level, _copy(level.par_placements))
		var result := world.run_schedule(level.par_holds)
		var previous := 0
		for i in level.checkpoints.size():
			var at: int = world.checkpoint_ticks[i]
			if at < 0:
				problems.append(
					"Level %d: Checkpoint %d liegt nicht auf dem Par-Weg" % [level.id, i + 1]
				)
				continue
			if at - previous < SEGMENT_MIN_TICKS:
				problems.append(
					"Level %d: Abschnitt vor Checkpoint %d dauert nur %d Ticks"
					% [level.id, i + 1, at - previous]
				)
			if at - previous > SEGMENT_MAX_TICKS:
				problems.append(
					"Level %d: Abschnitt vor Checkpoint %d dauert %d Ticks"
					% [level.id, i + 1, at - previous]
				)
			previous = at
		var tail: int = int(result["ticks"]) - previous
		if tail > SEGMENT_MAX_TICKS:
			problems.append("Level %d: letzter Abschnitt dauert %d Ticks" % [level.id, tail])
	assert_true(problems.is_empty(), "\n  ".join(problems))


## Resuming from a checkpoint must give back the *same run*, not a similar one.
##
## This is the whole design in one assertion. A checkpoint does not snapshot the
## ball — it cuts the recorded input sequence and replays the part that stands,
## exactly the way [code]PlayScreen._rewind[/code] does: fresh world, same masks.
## The ball therefore arrives carrying the speed it had the first time, which is
## what makes a long board one journey instead of a level select with extra steps.
##
## A snapshot would be cheaper, and would put the ball in a state no input sequence
## produces — and a run that cannot be described as inputs is not a replay, not a
## ghost and not a leaderboard entry.
func test_a_run_resumed_from_a_checkpoint_is_the_same_run() -> void:
	var problems: Array[String] = []
	for level: SimLevel in Levels.all():
		if level.checkpoints.is_empty():
			continue
		var straight := _world(level, _copy(level.par_placements))
		var whole := straight.run_schedule(level.par_holds)

		for i in level.checkpoints.size():
			var cut: int = straight.checkpoint_ticks[i]
			if cut < 0:
				continue
			# What the play screen keeps: the masks of the ticks that stand.
			var prefix: Array[int] = []
			for t in cut:
				prefix.append(_mask_at(level.par_holds, t))

			var again := _world(level, _copy(level.par_placements))
			for mask: int in prefix:
				again.step(mask)
			for t in range(cut, again.run_ticks):
				again.step(_mask_at(level.par_holds, t))
				if again.outcome != SimWorld.Outcome.RUNNING:
					break
			if again.state_hash() != int(whole["hash"]) or again.tick_count != int(whole["ticks"]):
				problems.append(
					"Level %d: ab Checkpoint %d läuft ein anderer Lauf (%d Ticks / %d statt %d / %d)"
					% [level.id, i + 1, again.tick_count, again.state_hash(),
						whole["ticks"], whole["hash"]]
				)
	assert_true(problems.is_empty(), "\n  ".join(problems))


## A magnet placed at a checkpoint must not reach back into the ticks already
## played.
##
## Without [member SimLevel.MagnetSpec.spawn_tick] it would: the world is rebuilt
## from the player's whole placement list, so a magnet added at the second station
## would have been pulling at the ball during the first one, and the prefix the
## player watches again would no longer be the run they made. The second half of
## this test is the part that matters — the same magnet born at tick 0 *does*
## change the prefix, so the first half is not passing for want of any effect.
func test_a_magnet_placed_at_a_checkpoint_cannot_change_the_past() -> void:
	var level := Levels.by_id(11)
	var straight := _world(level, _copy(level.par_placements))
	straight.run_schedule(level.par_holds)
	var cut: int = straight.checkpoint_ticks[0]
	assert_true(cut > 0, "Level 11 muss seinen ersten Checkpoint erreichen")

	# Held for the whole prefix and right beside the ball's line along the floor,
	# so "no effect" cannot be an accident of distance.
	var schedule := level.par_holds.duplicate(true)
	schedule.append([1, 0, cut])
	var spot := Vector2(600, 930)

	var plain := _prefix_hash(level, _copy(level.par_placements), level.par_holds, cut)

	var late := _copy(level.par_placements)
	late.append(SimLevel.MagnetSpec.new(spot.x, spot.y, true, false, Vector2.ZERO, 1, false, cut))
	assert_eq(
		_prefix_hash(level, late, schedule, cut), plain,
		"ein am Checkpoint gesetzter Magnet darf die gelaufenen Ticks nicht verändern"
	)

	var early := _copy(level.par_placements)
	early.append(SimLevel.MagnetSpec.new(spot.x, spot.y, true, false))
	assert_ne(
		_prefix_hash(level, early, schedule, cut), plain,
		"derselbe Magnet ab Tick 0 muss sehr wohl etwas ändern — sonst prüft der Test oben nichts"
	)


## A magnet dropped into a run in progress must leave the run identical to one
## that had it in the placement list all along.
##
## This is what the whole live-placement idea rests on. Crossing a checkpoint holds
## the board and lets the player place a magnet then and there; pressing R later
## rebuilds the world from [member PlayScreen.placed] and replays the input. If
## [method SimWorld.add_magnet] put the magnet anywhere other than exactly where
## [method SimLevel.magnets_for] would have, those two would drift apart — the key
## the magnet answers to would move, and the run the player watches again would not
## be the run they made.
func test_a_magnet_added_mid_run_matches_a_rebuild() -> void:
	var level := Levels.by_id(11)
	var cut := 205
	var schedule := [[0, 35, 115], [1, cut, cut + 120]]
	var late := SimLevel.MagnetSpec.new(1250, 800, true, false, Vector2.ZERO, 1, false, cut)

	# Dropped in mid-flight, the way a checkpoint hands one over.
	var live := _world(level, _copy(level.par_placements))
	for t in cut:
		live.step(_mask_at(schedule, t))
	live.add_magnet(late.duplicate_spec())
	for t in range(cut, live.run_ticks):
		live.step(_mask_at(schedule, t))
		if live.outcome != SimWorld.Outcome.RUNNING:
			break

	# The same run rebuilt from the placement list, which is what R does.
	var rebuilt_placed := _copy(level.par_placements)
	rebuilt_placed.append(late.duplicate_spec())
	var rebuilt := _world(level, rebuilt_placed)
	var whole := rebuilt.run_schedule(schedule)

	assert_eq(live.tick_count, int(whole["ticks"]), "beide Läufe müssen gleich lang sein")
	assert_eq(live.outcome, int(whole["outcome"]))
	assert_eq(
		live.state_hash(), int(whole["hash"]),
		"ein mitten im Lauf gesetzter Magnet muss denselben Lauf ergeben wie einer aus der Liste"
	)
	assert_eq(live.magnets.size(), rebuilt.magnets.size())
	# And the magnet has to answer to the same key in both, or a hold schedule
	# recorded live would point at the wrong field on replay.
	for i in live.magnets.size():
		assert_eq(
			(live.magnets[i] as SimLevel.MagnetSpec).x,
			(rebuilt.magnets[i] as SimLevel.MagnetSpec).x,
			"Magnet %d steht in den beiden Welten an verschiedenen Stellen" % i
		)


## No board may promise more magnets than there are keys to hold them with.
##
## Four, because the hold keys are 1–4. Checkpoint grants are counted: they arrive
## while the level is running, so a board that is within budget at the start can
## still end up handing out a fifth magnet nobody can activate.
func test_a_level_never_promises_more_magnets_than_there_are_keys() -> void:
	var problems: Array[String] = []
	for level: SimLevel in Levels.all():
		var total := level.budget
		for cp: SimLevel.Checkpoint in level.checkpoints:
			total += cp.grants
		for spec: SimLevel.MagnetSpec in level.fixed_magnets:
			if not spec.always_on:
				total += 1
		if total > SimWorld.HOLD_KEYS:
			problems.append("Level %d käme auf %d Magnete, es gibt %d Tasten"
				% [level.id, total, SimWorld.HOLD_KEYS])
	assert_true(problems.is_empty(), "\n  ".join(problems))


## The input mask of [param schedule] at [param tick] — the same one bitmask per
## tick the game feeds in.
func _mask_at(schedule: Array, tick: int) -> int:
	var mask := 0
	for entry: Array in schedule:
		if tick >= int(entry[1]) and tick < int(entry[2]):
			mask |= 1 << int(entry[0])
	return mask


## State after exactly [param ticks] ticks: the prefix a checkpoint resumes from.
func _prefix_hash(level: SimLevel, placed: Array, schedule: Array, ticks: int) -> int:
	var world := _world(level, placed)
	for t in ticks:
		world.step(_mask_at(schedule, t))
	return world.state_hash()


# --- Polygon walls ----------------------------------------------------------

## A bare board for the geometry tests: an arena, a ball, and nothing else — no
## floor, no goal within reach, no magnets. Whatever the ball does, the wall under
## test is the only reason for it.
func _bare(start: Vector2) -> SimLevel:
	var level := SimLevel.new()
	level.arena = Rect2(0, 0, 900, 660)
	level.start = start
	level.target = Rect2(-5000, -5000, 10, 10)
	return level


## A polygon drawn as a box behaves like the box.
##
## The claim that slopes needed no new contact model rests on this: the bounce is
## shared, and only the nearest-point query differs. So a four-cornered polygon
## where a [Rect2] would be must carry the ball the same way — falling onto it, and
## then rolling along it, which is the half that exercises the friction.
##
## Not bit-for-bit, and deliberately not asserted as such. The box finds its
## nearest point with a clamp, the polygon with a projection, and the projection
## can land a last bit away. What is asserted is that the two never drift apart by
## more than a hundredth of a pixel over four seconds.
func test_a_polygon_holds_the_ball_like_a_box_does() -> void:
	var boxed := _bare(Vector2(300, 400))
	boxed.solids = [Rect2(0, 600, 900, 40)]
	var shaped := _bare(Vector2(300, 400))
	shaped.polygons = [PackedVector2Array([
		Vector2(0, 600), Vector2(900, 600), Vector2(900, 640), Vector2(0, 640),
	])]
	var a := _world(boxed)
	var b := _world(shaped)
	var worst := 0.0
	for tick in 240:
		if tick == 90:
			# Landed and settled; now roll, so the tangential half gets used too.
			a.vel_x = 300.0
			b.vel_x = 300.0
		a.step(0)
		b.step(0)
		worst = maxf(worst, Vector2(a.ball_x - b.ball_x, a.ball_y - b.ball_y).length())
	assert_true(worst < 0.01, "Polygon und Kasten laufen um %.4f px auseinander" % worst)
	assert_true(
		absf(b.ball_y - (600.0 - SimWorld.BALL_RADIUS)) < 1.0,
		"liegt nicht auf der Oberkante (y=%.2f)" % b.ball_y
	)
	assert_true(b.ball_x > 400.0, "ist nicht gerollt (x=%.1f)" % b.ball_x)


## A slope is a slope: dropped on it, the ball rolls down it.
##
## There is no static friction in the model, only a damping of sliding speed, so
## nothing rests on an incline. That is what makes a ramp a ramp — speed without a
## magnet — and this is the test that says it happens and happens the right way.
func test_a_ball_rolls_down_a_ramp() -> void:
	var level := _bare(Vector2(200, 250))
	var ramp := PackedVector2Array([Vector2(100, 300), Vector2(700, 600), Vector2(100, 600)])
	level.polygons = [ramp]
	level.solids = [Rect2(700, 600, 200, 40)]
	var world := _world(level)
	# Eighty ticks and not more: the ramp is 600 px long, and much later the ball has
	# left it, hit the far wall and may be rolling back up. Measured on the slope.
	for tick in 80:
		world.step(0)
		assert_true(
			not Geometry2D.is_point_in_polygon(Vector2(world.ball_x, world.ball_y), ramp),
			"Tick %d: der Ball steckt in der Rampe" % tick
		)
	assert_true(world.ball_x > 320.0, "ist die Rampe nicht hinuntergerollt (x=%.1f)" % world.ball_x)
	assert_true(world.vel_x > 200.0, "hat auf der Rampe kein Tempo aufgenommen (%.1f px/s)" % world.vel_x)


## A concave wall is judged by its outline, not by its box.
##
## A cup is the case a lazy inside test gets wrong: the ball resting on the cup's
## floor is well within the polygon's bounding box and well *outside* the polygon.
## Treating those two as the same would shoot the ball out of the top of the cup.
## Two edges meet at each inner corner, which is also the case the second contact
## pass exists for.
func test_a_ball_settles_in_a_cup() -> void:
	var level := _bare(Vector2(400, 200))
	var cup := PackedVector2Array([
		Vector2(200, 300), Vector2(260, 300), Vector2(260, 540), Vector2(540, 540),
		Vector2(540, 300), Vector2(600, 300), Vector2(600, 600), Vector2(200, 600),
	])
	level.polygons = [cup]
	var world := _world(level)
	for tick in 240:
		world.step(0)
		assert_true(
			not Geometry2D.is_point_in_polygon(Vector2(world.ball_x, world.ball_y), cup),
			"Tick %d: der Ball steckt in der Wand" % tick
		)
	assert_true(
		absf(world.ball_y - (540.0 - SimWorld.BALL_RADIUS)) < 1.0,
		"liegt nicht auf dem Boden der Schale (y=%.2f)" % world.ball_y
	)
	assert_true(absf(world.ball_x - 400.0) < 20.0, "ist aus der Schale gewandert (x=%.1f)" % world.ball_x)


## Nothing gets through a slanted wall, even at the speed limit.
##
## The ball covers at most `MAX_SPEED / 60` = 18.3 px a tick against a radius of
## 15, so a wall thinner than about 6.7 px can be crossed in one tick and then
## pushed out on the *far* side — the nearest edge is the wrong one by then. This
## wall is 8.9 px thick across its slope, just over that, and is fired at from
## several directions at full speed.
func test_a_slanted_wall_stops_a_ball_at_full_speed() -> void:
	var strip := PackedVector2Array([
		Vector2(400, 100), Vector2(410, 100), Vector2(610, 500), Vector2(600, 500),
	])
	for aim: Vector2 in [Vector2(1, 0), Vector2(1, -0.4), Vector2(1, 0.4), Vector2(0.6, 1)]:
		var level := _bare(Vector2(330, 300))
		level.polygons = [strip]
		var world := _world(level)
		var throw := aim.normalized() * SimWorld.MAX_SPEED
		world.vel_x = throw.x
		world.vel_y = throw.y
		for tick in 60:
			world.step(0)
			var at := Vector2(world.ball_x, world.ball_y)
			assert_true(
				not Geometry2D.is_point_in_polygon(at, strip),
				"Wurf %s, Tick %d: steckt in der Wand" % [aim, tick]
			)
			# The side of the strip's centre line it started on, checked only along the
			# strip's own height: a ball that slides off the bottom end and swings right
			# underneath it has gone *around*, not through.
			if at.y <= 100.0 or at.y >= 500.0:
				continue
			var side := (Vector2(605, 500) - Vector2(405, 100)).cross(at - Vector2(405, 100))
			assert_true(side > 0.0, "Wurf %s, Tick %d: ist durch die Wand" % [aim, tick])


## A polygon nobody touches changes nothing.
##
## The list is walked every pass of every tick once it is non-empty, and what this
## pins down is that walking it is all it does: a wall far outside the arena leaves
## a proven run bit-identical.
func test_a_polygon_nobody_touches_changes_nothing() -> void:
	var level := Levels.by_id(11)
	assert_true(level.polygons.is_empty(), "Level 11 hat ein Polygon bekommen — Test anpassen")
	var straight := _world(level, _copy(level.par_placements)).run_schedule(level.par_holds)

	var harmless := Levels.by_id(11)
	harmless.polygons = [PackedVector2Array([
		Vector2(-9000, -9000), Vector2(-8900, -9000), Vector2(-8950, -8900),
	])]
	var same := _world(harmless, _copy(harmless.par_placements)).run_schedule(harmless.par_holds)
	assert_eq(int(same["hash"]), int(straight["hash"]), "ein fernes Polygon verschiebt die Bahn")
	assert_eq(int(same["ticks"]), int(straight["ticks"]), "ein fernes Polygon verschiebt die Dauer")


func _copy(specs: Array) -> Array:
	var out: Array = []
	for spec: SimLevel.MagnetSpec in specs:
		out.append(spec.duplicate_spec())
	return out


func _outcome_name(outcome: int) -> String:
	if outcome == SimWorld.Outcome.WON:
		return "WON"
	if outcome == SimWorld.Outcome.LOST:
		return "LOST"
	return "RUNNING"
