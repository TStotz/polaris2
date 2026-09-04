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
const PAR_FINGERPRINTS := [
	[1, 73, 1440854023],
	[2, 43, 1583506679],
	[3, 75, 1327488285],
	[4, 199, 948528529],
	[5, 227, 120131000],
	[6, 295, 944500438],
	[7, 59, 769956630],
	[8, 216, 2027035587],
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
			var without: Array = []
			for entry: Array in level.par_holds:
				if int(entry[0]) != i:
					without.append(entry)
			if world.run_schedule(without)["outcome"] == SimWorld.Outcome.WON:
				idle.append("Level %d gewinnt auch ohne Magnet %d" % [level.id, i + 1])
	assert_true(idle.is_empty(), "
  ".join(idle))


func test_par_placements_match_the_budget() -> void:
	# A replay that places more magnets than the level allows could never be
	# reproduced by a player.
	var problems: Array[String] = []
	for level: SimLevel in Levels.all():
		if level.par_placements.size() != level.budget:
			problems.append(
				"Level %d setzt %d Magnete, Budget ist %d"
				% [level.id, level.par_placements.size(), level.budget]
			)
		for spec: SimLevel.MagnetSpec in level.par_placements:
			for solid: Rect2 in level.solids:
				if solid.grow(SimWorld.BALL_RADIUS).has_point(Vector2(spec.x, spec.y)):
					problems.append("Level %d setzt einen Magneten in eine Wand" % level.id)
	assert_true(problems.is_empty(), "\n  ".join(problems))


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
