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
		if not level.paths_enabled:
			continue
		for gx in range(gx_from, gx_to):
			for gy in 13:
				var x := gx * 50.0 + 25.0
				var y := gy * 50.0 + 25.0
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
