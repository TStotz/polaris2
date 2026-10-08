@tool
extends McpTestSuite

## Authoring tool, not a test — delete once every level carries a par replay.
##
## Searches for a winning hold schedule per level and appends it to
## `res://tools/replays_found.txt`. One test method per level because the runner
## only services the editor transport *between* tests; a single multi-minute body
## drops the session.

const REPORT_PATH := "res://tools/replays_found.txt"
## Deliberately small. This file lives in `tests/` so the MCP runner can drive it,
## but it is an authoring tool, not a test — it asserts nothing. At 2000 samples a
## full `test_run` cost 90 seconds, which taxes every unrelated change. Raise it
## when actually searching for a new level's replay, then put it back.
const SAMPLES := 250
## The campaign default. A board with its own [member SimLevel.max_ticks] is a
## chained board, and the sweeps here place a single magnet — so those are skipped
## rather than measured against the wrong horizon.
const MAX_TICKS := SimWorld.MAX_RUN_TICKS
const GRAIN := 5

## Placements tried per reverse-level slice. Each one gets its whole timing grid
## enumerated, so this is multiplied by a few dozen runs — at 40 a full `test_run`
## took 76 seconds. Throttled like SAMPLES; raise both when actually searching.
const PLACEMENT_TRIES := 6


func suite_name() -> String:
	return "zz_find_replays"


func test_00_reset_report() -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	file.store_string("")
	file.close()
	assert_true(true)


func test_01_schub() -> void:
	_search_level(1)


func test_02_zug() -> void:
	_search_level(2)


func test_03_luecke() -> void:
	_search_level(3)


func test_04a_zwei() -> void:
	_search_level(4)


func test_04b_zwei() -> void:
	_search_level(4, 1)


func test_04c_zwei() -> void:
	_search_level(4, 2)


func test_04d_zwei() -> void:
	_search_level(4, 3)


func test_04e_zwei() -> void:
	_search_level(4, 4)


func test_04f_zwei() -> void:
	_search_level(4, 5)


func test_05_parcours() -> void:
	_search_level(5)


## Three slices, not the ten the search needed. Platforms make each sample cost
## about four times a static level's, and the extras pushed a full `test_run` to
## 42 seconds — paid on every unrelated change. Add slices back when hunting for a
## replay, alongside raising SAMPLES.
## Levels with a fixed magnet and the reverse key are searched exhaustively
## instead of sampled.
##
## The plan is one hold window plus one reverse window, so the whole grid is a
## few thousand runs — cheaper than 1200 random samples and, unlike them, an
## answer rather than a guess. Random sampling failed here for a specific reason
## worth remembering: it drew the hold's start over 0..445 ticks, while every
## winning plan on this board starts at tick 0, so 89 samples in 90 were spent
## before the search even reached the interesting part.
func test_07a_schleuder() -> void:
	_sweep_flip_level(7, 0)


func test_07b_schleuder() -> void:
	_sweep_flip_level(7, 1)


func test_07c_schleuder() -> void:
	_sweep_flip_level(7, 2)


## Reverse levels: the placement is sampled, the *timing* is enumerated.
##
## Splitting it this way is the point. The placement space is far too large to
## enumerate, but the timing space — one hold window crossed with one reverse
## window — is a few dozen plans, and that is exactly the part random sampling was
## worst at: it drew the reverse independently of the hold, so almost every sample
## reversed while nothing was switched on.
func _sweep_flip_level(id: int, chunk: int) -> void:
	var level := Levels.by_id(id)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7000 + id * 100 + chunk
	var charge_ticks := int(level.charge_seconds * SimWorld.TICK_HZ)
	var step := GRAIN * 2
	var world := SimWorld.new()
	var best := {}
	var valid := 0

	for _sample in PLACEMENT_TRIES:
		var placed: Array = []
		for _b in level.budget:
			placed.append(_random_magnet(level, rng))
		for hold_end in range(step * 2, charge_ticks + step, step):
			for flip_at in range(step, hold_end, step):
				var plan := [[0, 0, hold_end], [SimWorld.INVERT_INPUT, flip_at, hold_end]]
				world.setup(level, placed)
				var res := world.run_schedule(plan, MAX_TICKS)
				if res["outcome"] != SimWorld.Outcome.WON:
					continue
				if not _needs_every_magnet(world, plan, level):
					continue
				valid += 1
				if best.is_empty() or int(res["ticks"]) < int(best["ticks"]):
					best = {"ticks": res["ticks"], "plan": plan, "placed": placed}

	var lines: Array[String] = []
	if best.is_empty():
		lines.append("LEVEL %d %s: KEINE LOESUNG in %d Platzierungen" % [id, level.title, PLACEMENT_TRIES])
	else:
		lines.append(
			"LEVEL %d %s: %d Ticks (%.2f s), %d gueltige Plaene"
			% [id, level.title, best["ticks"], float(best["ticks"]) / SimWorld.TICK_HZ, valid]
		)
		lines.append("	level.par_placements = %s" % _placements_source(best["placed"]))
		lines.append("	level.par_holds = %s" % str(best["plan"]))
	_append(lines)
	assert_true(true)


func test_06a_aufzug() -> void:
	_search_level(6)


func test_06b_aufzug() -> void:
	_search_level(6, 1)


func test_06c_aufzug() -> void:
	_search_level(6, 2)


## The strict form of "a path level needs its path": no *static* magnet anywhere
## on the board, of either polarity, at any of a spread of hold windows, may win.
##
## This is the check that was missing when Level 7 shipped a reverse level winnable
## without reversing — that guard only removed the input from the par and left the
## par's own placement standing, so it could not see a different placement solving
## the board. Too slow for the fast suite, hence here, and sliced because a single
## body over ~20s drops the editor session.
func test_08a_path_is_required() -> void:
	_no_static_magnet_wins(0, 9)


func test_08b_path_is_required() -> void:
	_no_static_magnet_wins(9, 18)


func _no_static_magnet_wins(gx_from: int, gx_to: int) -> void:
	var world := SimWorld.new()
	var wins: Array[String] = []
	for level: SimLevel in Levels.all():
		if not level.paths_enabled or level.twin_of != 0:
			continue
		for gx in range(gx_from, gx_to):
			for gy in 13:
				# Steps derived from the arena, not fixed at 50px: a hard-coded grid
				# covers only the first 900x650 and would have "proved" nothing about
				# the far four fifths of a 2200px board.
				var x := (float(gx) + 0.5) * level.arena.size.x / 18.0 + level.arena.position.x
				var y := (float(gy) + 0.5) * level.arena.size.y / 13.0 + level.arena.position.y
				var blocked := false
				for solid: Rect2 in level.solids:
					if solid.grow(SimWorld.BALL_RADIUS + 6.0).has_point(Vector2(x, y)):
						blocked = true
						break
				if blocked:
					continue
				for pol in 2:
					for start in [0, 40]:
						for stop in [80, 180, 270]:
							world.setup(level, [SimLevel.MagnetSpec.new(x, y, pol == 0, false)])
							if world.run_schedule([[0, start, stop]], MAX_TICKS)["outcome"] == SimWorld.Outcome.WON:
								wins.append(
									"Level %d: stehender Magnet (%d,%d) %s gewinnt bei %d-%d"
									% [level.id, x, y, "anziehend" if pol == 0 else "abstossend", start, stop]
								)
	assert_true(wins.is_empty(), "
  ".join(wins))


## The strict form of "a furniture level needs its furniture": strip the level's
## own field and no placement of the player's magnet, of either polarity, at any
## hold window, may win. Sliced, like the path check.
## Sliced the same way and for the same reason as the zone proof: Level 11 has
## furniture too, and its runs are long.
func test_09a_furniture_is_required() -> void:
	_no_win_without_furniture(0, 3)


func test_09b_furniture_is_required() -> void:
	_no_win_without_furniture(3, 6)


func test_09c_furniture_is_required() -> void:
	_no_win_without_furniture(6, 9)


func test_09d_furniture_is_required() -> void:
	_no_win_without_furniture(9, 12)


func test_09e_furniture_is_required() -> void:
	_no_win_without_furniture(12, 15)


func test_09f_furniture_is_required() -> void:
	_no_win_without_furniture(15, 18)


func _no_win_without_furniture(gx_from: int, gx_to: int) -> void:
	var world := SimWorld.new()
	var wins: Array[String] = []
	for level: SimLevel in Levels.all():
		# A twin is the same geometry as its original — proving it again would cost a
		# minute of the suite's budget for an answer already on file.
		# And a chained board is skipped, because this proof does not fit it: it places
		# *one* magnet and looks for a win, while Level 15 needs five. It would report
		# zero winners with the feature and zero without, which proves nothing — the
		# same empty green a uniform grid once gave on Level 11 until an
		# `assert winners > 0` caught it. A proof that does not fit is not faked.
		# The cheap per-par checks in `test_sim.gd` still run on these boards.
		if level.fixed_magnets.is_empty() or level.twin_of != 0 or level.par_placements.size() > 1:
			continue
		var bare := SimLevel.new()
		bare.arena = level.arena
		bare.start = level.start
		bare.target = level.target
		bare.solids = level.solids
		bare.movers = level.movers
		bare.budget = level.budget
		bare.charge_seconds = level.charge_seconds
		for gx in range(gx_from, gx_to):
			for gy in 13:
				# Steps derived from the arena, not fixed at 50px: a hard-coded grid
				# covers only the first 900x650 and would have "proved" nothing about
				# the far four fifths of a 2200px board.
				var x := (float(gx) + 0.5) * level.arena.size.x / 18.0 + level.arena.position.x
				var y := (float(gy) + 0.5) * level.arena.size.y / 13.0 + level.arena.position.y
				var blocked := false
				for solid: Rect2 in bare.solids:
					if solid.grow(SimWorld.BALL_RADIUS + 6.0).has_point(Vector2(x, y)):
						blocked = true
						break
				if blocked:
					continue
				for pol in 2:
					for start in [0, 20, 50]:
						for stop in [40, 70, 90]:
							world.setup(bare, [SimLevel.MagnetSpec.new(x, y, pol == 0, false)])
							if world.run_schedule([[0, start, stop]], MAX_TICKS)["outcome"] == SimWorld.Outcome.WON:
								wins.append(
									"Level %d: (%d,%d) %s %d-%d gewinnt ohne das Feld"
									% [level.id, x, y, "anz" if pol == 0 else "abs", start, stop]
								)
	assert_true(wins.is_empty(), "
  ".join(wins))


## Strict form: strip the flipping zones and no placement of the player's magnet,
## either polarity, any hold window, may win. Sliced like the other grid proofs.
## Six slices, not four. With two zone levels and one of them 2200px wide, four
## slices ran 20.7s each — close enough to the ~20s cutoff that the editor session
## would eventually be dropped mid-run.
func test_10a_zone_is_required() -> void:
	_no_win_without_zone(0, 3)


func test_10b_zone_is_required() -> void:
	_no_win_without_zone(3, 6)


func test_10c_zone_is_required() -> void:
	_no_win_without_zone(6, 9)


func test_10d_zone_is_required() -> void:
	_no_win_without_zone(9, 12)


func test_10e_zone_is_required() -> void:
	_no_win_without_zone(12, 15)


func test_10f_zone_is_required() -> void:
	_no_win_without_zone(15, 18)


func _no_win_without_zone(gx_from: int, gx_to: int) -> void:
	var world := SimWorld.new()
	var wins: Array[String] = []
	for level: SimLevel in Levels.all():
		# And a chained board is skipped, because this proof does not fit it: it places
		# *one* magnet and looks for a win, while Level 15 needs five. It would report
		# zero winners with the feature and zero without, which proves nothing — the
		# same empty green a uniform grid once gave on Level 11 until an
		# `assert winners > 0` caught it. A proof that does not fit is not faked.
		# The cheap per-par checks in `test_sim.gd` still run on these boards.
		if level.zones.is_empty() or level.twin_of != 0 or level.par_placements.size() > 1:
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
		for gx in range(gx_from, gx_to):
			for gy in 13:
				# Steps derived from the arena, not fixed at 50px: a hard-coded grid
				# covers only the first 900x650 and would have "proved" nothing about
				# the far four fifths of a 2200px board.
				var x := (float(gx) + 0.5) * level.arena.size.x / 18.0 + level.arena.position.x
				var y := (float(gy) + 0.5) * level.arena.size.y / 13.0 + level.arena.position.y
				var blocked := false
				for solid: Rect2 in flat.solids:
					if solid.grow(SimWorld.BALL_RADIUS + 6.0).has_point(Vector2(x, y)):
						blocked = true
						break
				if blocked:
					continue
				for pol in 2:
					for start in [0, 30, 60, 90]:
						for stop in [40, 70, 90]:
							if stop <= start:
								continue
							world.setup(flat, [SimLevel.MagnetSpec.new(x, y, pol == 0, false)])
							if world.run_schedule([[0, start, stop]], MAX_TICKS)["outcome"] == SimWorld.Outcome.WON:
								wins.append(
									"Level %d: (%d,%d) %s %d-%d gewinnt ohne Zone"
									% [level.id, x, y, "anz" if pol == 0 else "abs", start, stop]
								)
	assert_true(wins.is_empty(), "
  ".join(wins))


func _search_level(id: int, chunk: int = 0) -> void:
	var level := Levels.by_id(id)
	var rng := RandomNumberGenerator.new()
	# Seeded per level and chunk so a re-run reproduces the same answer.
	rng.seed = 9000 + id * 100 + chunk

	var charge_ticks := int(level.charge_seconds * SimWorld.TICK_HZ)
	var world := SimWorld.new()
	var best := {}

	for _sample in SAMPLES:
		var placed: Array = []
		for _b in level.budget:
			placed.append(_random_magnet(level, rng))
		world.setup(level, placed)

		var schedule: Array = []
		for i in world.magnets.size():
			# Waiting only ever helps when the world changes on its own. On a static
			# board every winning plan starts almost immediately, and drawing the start
			# over 445 ticks threw away the overwhelming majority of samples.
			var start_range := 90 if not level.movers.is_empty() else 12
			var start := (rng.randi() % start_range) * GRAIN
			var duration := GRAIN + (rng.randi() % maxi(1, charge_ticks / GRAIN)) * GRAIN
			schedule.append([i, start, start + duration])
		if level.flip_enabled and not schedule.is_empty():
			# The reverse rides in the same schedule as any hold; its "magnet index"
			# is the invert bit's position.
			#
			# Drawn *inside* the first magnet's hold window rather than independently.
			# Reversing does nothing while no magnet is on, so independent draws spent
			# almost every sample on plans that could not differ from not reversing at
			# all — 1200 of them found nothing.
			var hold_start := int(schedule[0][1])
			var hold_span: int = maxi(1, (int(schedule[0][2]) - hold_start) / GRAIN)
			var flip_at := hold_start + (rng.randi() % hold_span) * GRAIN
			var flip_for := GRAIN + (rng.randi() % 40) * GRAIN
			schedule.append([SimWorld.INVERT_INPUT, flip_at, flip_at + flip_for])

		var result := world.run_schedule(schedule, MAX_TICKS)
		if result["outcome"] != SimWorld.Outcome.WON:
			continue
		if not _needs_every_magnet(world, schedule, level):
			continue
		if best.is_empty() or int(result["ticks"]) < int(best["ticks"]):
			best = {"ticks": result["ticks"], "placed": placed, "schedule": schedule}

	var lines: Array[String] = []
	if best.is_empty():
		lines.append("LEVEL %d %s: KEINE LOESUNG in %d Versuchen" % [id, level.title, SAMPLES])
	else:
		lines.append(
			"LEVEL %d %s: %d Ticks (%.2f s)"
			% [id, level.title, best["ticks"], float(best["ticks"]) / SimWorld.TICK_HZ]
		)
		lines.append("\tlevel.par_placements = %s" % _placements_source(best["placed"]))
		lines.append("\tlevel.par_holds = %s" % str(best["schedule"]))
	_append(lines)
	assert_true(true)


## The strict form of "a checkpoint saves a run instead of locking it".
##
## Carrying speed across a checkpoint is what makes a long board one journey
## rather than a level select with extra steps — but it also means the player can
## arrive in a state nobody ever proved the rest of the board solvable from. A
## checkpoint you cannot get out of is worse than no checkpoint at all: it ends the
## run without ending it, and the only way on is to throw the whole thing away.
##
## So the arrivals a player can actually produce are sampled — several prefixes
## that cross the same gate at different speeds — and each one has to be finishable
## with the magnet the checkpoint hands out.
##
## **Sampled, not proven.** The set of arrival states is continuous and a grid
## walks across it; a board can pass this and still have a bad corner. That is the
## price of carrying velocity, and it is written down here rather than quietly
## assumed. The alternative — coming to a stop at every checkpoint — is provable,
## and is a different game.
func test_11a_checkpoint_is_recoverable() -> void:
	_checkpoint_recovers(11, 0)


## Prefixes worth sampling: the par's own hold window, started earlier or later and
## cut shorter. Each variant that still crosses the gate is one arrival — same
## place, different speed.
func _arrival_variants(level: SimLevel) -> Array:
	var out: Array = []
	if level.par_holds.is_empty():
		return out
	var base: Array = level.par_holds[0]
	for shift in [-8, -5, -2, 0, 3, 5]:
		for shorten in [0, 10, 20, 25, 31]:
			var holds: Array = level.par_holds.duplicate(true)
			holds[0] = [int(base[0]), int(base[1]) + shift, int(base[2]) - shorten]
			out.append(holds)
	return out


func _checkpoint_recovers(level_id: int, index: int) -> void:
	var level := Levels.by_id(level_id)
	var dead_ends: Array[String] = []
	var arrivals := 0
	for holds: Array in _arrival_variants(level):
		var probe := SimWorld.new()
		probe.setup(level, _copy(level.par_placements))
		probe.run_schedule(holds, MAX_TICKS)
		if index >= probe.checkpoint_ticks.size():
			continue
		var cut: int = probe.checkpoint_ticks[index]
		if cut < 0:
			continue  # this prefix never reached the gate, so it is not an arrival
		arrivals += 1
		if not _can_finish_from(level, holds, cut):
			dead_ends.append(
				"Level %d: Ankunft an Checkpoint %d nach %d Ticks (Halten %s) ist eine Sackgasse"
				% [level.id, index + 1, cut, str(holds[0])]
			)
	assert_true(arrivals > 0, "kein Praefix erreicht Checkpoint %d" % (index + 1))
	assert_true(dead_ends.is_empty(), "\n  ".join(dead_ends))


## Whether *any* placement of the checkpoint's magnet finishes the board from the
## arrival [param holds] produces at tick [param cut].
##
## Returns on the first winner, so a healthy checkpoint costs a handful of runs and
## only a dead end pays for the whole grid.
func _can_finish_from(level: SimLevel, holds: Array, cut: int) -> bool:
	var world := SimWorld.new()
	var index := level.par_placements.size()
	var charge := int(level.charge_seconds * float(SimWorld.TICK_HZ))
	for gx in 8:
		for gy in 6:
			var x := (float(gx) + 0.5) * level.arena.size.x / 8.0 + level.arena.position.x
			var y := (float(gy) + 0.5) * level.arena.size.y / 6.0 + level.arena.position.y
			if _blocked(level, Vector2(x, y)):
				continue
			for pol in 2:
				for delay in [0, 90, 180, 300]:
					var placed := _copy(level.par_placements)
					placed.append(SimLevel.MagnetSpec.new(
						x, y, pol == 0, false, Vector2.ZERO, 1, false, cut
					))
					var schedule: Array = holds.duplicate(true)
					schedule.append([index, cut + delay, cut + delay + charge])
					world.setup(level, placed)
					if world.run_schedule(schedule, MAX_TICKS)["outcome"] == SimWorld.Outcome.WON:
						return true
	return false


func _blocked(level: SimLevel, at: Vector2) -> bool:
	if not level.arena.has_point(at):
		return true
	for solid: Rect2 in level.solids:
		if solid.grow(SimWorld.BALL_RADIUS + 6.0).has_point(at):
			return true
	for mover: SimLevel.MoverSpec in level.movers:
		if mover.swept_rect().grow(SimWorld.BALL_RADIUS + 6.0).has_point(at):
			return true
	return false


func _copy(specs: Array) -> Array:
	var out: Array = []
	for spec: SimLevel.MagnetSpec in specs:
		out.append(spec.duplicate_spec())
	return out


## A gate has to sit *across* the corridor, not in it.
##
## Level 11's gates were small boxes on the floor to begin with. A ball that flew,
## bounced, or came back up off the moving platform went straight past them, and
## the player was thrown back to the start of a board they had visibly got half way
## through. Reported from play, then measured: of the runs that got beyond the
## bridge at all, one in four tripped the gate.
##
## The criterion that catches it: **a run that wins must have passed every
## checkpoint.** A gate that a winning route can miss is not across the way — and
## nothing else in the suite would notice, because the par goes through it.
func test_11c_no_winning_route_skips_a_gate() -> void:
	_gates_catch_every_winner(-7, 0)


func test_11d_no_winning_route_skips_a_gate() -> void:
	_gates_catch_every_winner(0, 7)


## Winning routes come from the neighbourhood of the par placement, not from a
## blank grid: a coarse grid over this board wins *nothing* (measured — the
## vacuity guard below caught exactly that), so it would have proved nothing while
## staying green. Shifting the proven magnet and its hold window gives genuinely
## different trajectories that still reach the goal.
func _gates_catch_every_winner(dx_from: int, dx_to: int) -> void:
	var slipped: Array[String] = []
	var winners := 0
	for level: SimLevel in Levels.all():
		if level.checkpoints.is_empty() or level.par_placements.is_empty():
			continue
		# A board whose par needs more than one magnet is skipped: this sweep places
		# one, so on Level 15 it would win nothing, prove nothing, and spend minutes
		# doing it. The global `winners > 0` guard below would not notice, because
		# Level 11 supplies winners on behalf of every board here.
		if level.par_placements.size() > 1:
			continue
		if level.twin_of != 0:
			continue
		var seed_spec: SimLevel.MagnetSpec = level.par_placements[0]
		for dx in range(dx_from, dx_to):
			for dy in range(-3, 4):
				var x := seed_spec.x + float(dx) * 25.0
				var y := seed_spec.y + float(dy) * 25.0
				if _blocked(level, Vector2(x, y)):
					continue
				for on in [5, 15, 25]:
					for dur in [50, 80, 120]:
						var world := SimWorld.new()
						world.setup(level, [
							SimLevel.MagnetSpec.new(x, y, seed_spec.attract, false)
						])
						var result := world.run_schedule([[0, on, on + dur]], MAX_TICKS)
						if int(result["outcome"]) != SimWorld.Outcome.WON:
							continue
						winners += 1
						for i in level.checkpoints.size():
							if world.checkpoint_ticks[i] < 0 and slipped.size() < 8:
								slipped.append(
									"Level %d: Sieg mit Magnet (%d,%d) ab %d fuer %d, aber Tor %d nie ausgeloest"
									% [level.id, x, y, on, dur, i + 1]
								)
	assert_true(winners > 0, "kein einziger Sieg im Raster \u2014 das Kriterium prueft nichts")
	assert_true(slipped.is_empty(), "\n  ".join(slipped))


## Every magnet must be load-bearing: drop each one's holds in turn and the run
## must stop winning. Otherwise the level ships a magnet that does nothing, which
## teaches the player the wrong thing about their own budget.
func _needs_every_magnet(world: SimWorld, schedule: Array, level: SimLevel) -> bool:
	var inputs: Array[int] = []
	for i in world.magnets.size():
		inputs.append(i)
	if level.flip_enabled:
		# The reverse key is held to the same standard: a level filed under
		# "Polarität umkehren" whose answer wins without ever reversing is mis-filed.
		inputs.append(SimWorld.INVERT_INPUT)
	for id in inputs:
		var without: Array = []
		for entry: Array in schedule:
			if int(entry[0]) != id:
				without.append(entry)
		if world.run_schedule(without, MAX_TICKS)["outcome"] == SimWorld.Outcome.WON:
			return false
	return true


func _append(lines: Array[String]) -> void:
	var existing := ""
	if FileAccess.file_exists(REPORT_PATH):
		var reader := FileAccess.open(REPORT_PATH, FileAccess.READ)
		existing = reader.get_as_text()
		reader.close()
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	file.store_string(existing + "\n".join(lines) + "\n")
	file.close()


func _random_magnet(level: SimLevel, rng: RandomNumberGenerator) -> SimLevel.MagnetSpec:
	for _try in 40:
		var x := float((rng.randi() % 18) * 50 + 25) + level.arena.position.x
		var y := float((rng.randi() % 13) * 50 + 25) + level.arena.position.y
		var blocked := false
		for solid: Rect2 in level.solids:
			if solid.grow(SimWorld.BALL_RADIUS + 6.0).has_point(Vector2(x, y)):
				blocked = true
				break
		# A moving platform sweeps a corridor; a magnet inside it would spend half
		# the run buried in the platform.
		for mover: SimLevel.MoverSpec in level.movers:
			if mover.swept_rect().grow(SimWorld.BALL_RADIUS + 6.0).has_point(Vector2(x, y)):
				blocked = true
				break
		if not blocked:
			return SimLevel.MagnetSpec.new(x, y, rng.randi() % 2 == 0, false)
	return SimLevel.MagnetSpec.new(level.arena.get_center().x, 40.0, true, false)


func _placements_source(placed: Array) -> String:
	var parts: Array[String] = []
	for spec: SimLevel.MagnetSpec in placed:
		parts.append(
			"SimLevel.MagnetSpec.new(%d, %d, %s, false)"
			% [int(spec.x), int(spec.y), "true" if spec.attract else "false"]
		)
	return "[%s]" % ", ".join(parts)
