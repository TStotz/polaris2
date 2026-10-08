@tool
extends McpTestSuite

## Guards on the build mode's data half.
##
## The build *screen* has no coverage — it is a `Node2D` the test runner cannot
## instantiate, same as the play screen, and UI state is still checked by hand.
## What can be checked is the part that matters most if it is wrong: the text the
## tool tells you to paste into `levels.gd`, and the conversion that turns a run
## you won into a proven replay. A silent flaw there ships a level that says
## something other than what was built.

func suite_name() -> String:
	return "build"



## Every campaign level survives a trip through the emitter.
##
## Deliberately not a byte comparison against `levels.gd`: the emitter writes only
## the fields a board actually sets, while the file carries comments and the
## occasional hand-written flourish. What it has to do is produce something for
## every shape the campaign contains, without choking on one.
func test_the_emitter_handles_every_level() -> void:
	var problems: Array[String] = []
	for level: SimLevel in Levels.all():
		var text := LevelSource.to_gdscript(level, "_probe")
		if not text.begins_with("## TODO"):
			problems.append("Level %d: kein Kopf" % level.id)
		if not text.ends_with("\treturn level\n"):
			problems.append("Level %d: kein Abschluss" % level.id)
		if not text.contains("level.arena = Rect2("):
			problems.append("Level %d: keine Arena" % level.id)
		if not level.checkpoints.is_empty() and not text.contains("SimLevel.Checkpoint.new("):
			problems.append("Level %d: Tore fehlen im Text" % level.id)
		if not level.zones.is_empty() and not text.contains("SimLevel.GravitySpec.new("):
			problems.append("Level %d: Zone fehlt im Text" % level.id)
		if not level.movers.is_empty() and not text.contains("SimLevel.MoverSpec.new("):
			problems.append("Level %d: Plattform fehlt im Text" % level.id)
	assert_true(problems.is_empty(), "\n  ".join(problems))


## A board that sets nothing says nothing.
##
## The definitions in `levels.gd` are read as documentation. A draft that never
## touched slowed time must not ship a line claiming a value for it, or the two
## numbers that *were* chosen drown in defaults.
func test_the_emitter_leaves_out_what_was_never_set() -> void:
	var plain := LevelSource.blank()
	var text := LevelSource.to_gdscript(plain, "_probe")
	var silent: Array[String] = [
		"max_ticks", "magnet_strength", "field_strength", "slowmo_ticks", "hazards",
		"slowmo_points", "theme", "springs",
		"checkpoints", "zones", "movers", "fixed_magnets",
	]
	var noisy: Array[String] = []
	for field: String in silent:
		if text.contains("level.%s" % field):
			noisy.append(field)
	assert_true(noisy.is_empty(), "leerer Entwurf schreibt: " + ", ".join(noisy))


## A won run turned back into a hold schedule is the schedule it was played from.
##
## This is the whole reason a hand-built level is cheap: the proof that a board can
## be won is the run you just made. If the conversion drops an entry or shifts a
## tick, a level ships with a par that does not replay — and `test_sim.gd` would
## then reject a board that is actually fine, or worse, accept one that is not.
##
## Level 7's par includes an [constant SimWorld.INVERT_INPUT] entry, so the reverse
## key rides through this test as well.
func test_a_recorded_run_becomes_the_schedule_it_came_from() -> void:
	var problems: Array[String] = []
	for level: SimLevel in Levels.all():
		if level.par_holds.is_empty():
			continue
		var last := 0
		for entry: Array in level.par_holds:
			last = maxi(last, int(entry[2]))

		# The recording the play screen would have made of exactly this plan.
		var recording: Array[int] = []
		for t in last:
			var mask := 0
			for entry: Array in level.par_holds:
				if t >= int(entry[1]) and t < int(entry[2]):
					mask |= 1 << int(entry[0])
			recording.append(mask)

		var back := LevelSource.holds_from(recording)
		var want := _sorted(level.par_holds)
		var got := _sorted(back)
		if str(want) != str(got):
			problems.append("Level %d: %s statt %s" % [level.id, str(got), str(want)])
	assert_true(problems.is_empty(), "\n  ".join(problems))


## Two holds of the same magnet with a gap between them stay two holds.
##
## The obvious implementation — remember the first tick a bit was seen and the last
## — would fold them into one and quietly give the player charge they never spent.
func test_a_gap_in_a_hold_stays_a_gap() -> void:
	var recording: Array[int] = []
	for t in 40:
		var mask := 0
		if (t >= 5 and t < 10) or (t >= 20 and t < 25):
			mask |= 1
		recording.append(mask)
	assert_eq(str(LevelSource.holds_from(recording)), str([[0, 5, 10], [0, 20, 25]]))


## A hold still down when the run ends is closed at the end of it.
func test_a_hold_that_never_ends_is_closed_at_the_last_tick() -> void:
	var recording: Array[int] = [0, 1, 1, 1]
	assert_eq(str(LevelSource.holds_from(recording)), str([[0, 1, 4]]))


## An undo snapshot shares nothing with the level it was taken from.
##
## A shallow copy would let an edit reach back into the history and rewrite it,
## which is the sort of bug that only shows up as "undo did nothing" long after.
func test_a_copied_draft_shares_nothing_with_its_original() -> void:
	var original := Levels.by_id(15)
	var clone := LevelSource.copy(original)

	clone.solids[0] = Rect2(1, 2, 3, 4)
	clone.arena = Rect2(0, 0, 1, 1)
	clone.budget = 99
	(clone.checkpoints[0] as SimLevel.Checkpoint).rect = Rect2(5, 6, 7, 8)
	(clone.movers[0] as SimLevel.MoverSpec).period = 1234
	(clone.par_placements[0] as SimLevel.MagnetSpec).x = -1.0
	(clone.par_holds[0] as Array)[1] = -1

	var untouched := Levels.by_id(15)
	assert_eq(str(original.solids[0]), str(untouched.solids[0]))
	assert_eq(str(original.arena), str(untouched.arena))
	assert_eq(original.budget, untouched.budget)
	assert_eq(
		str((original.checkpoints[0] as SimLevel.Checkpoint).rect),
		str((untouched.checkpoints[0] as SimLevel.Checkpoint).rect)
	)
	assert_eq(
		(original.movers[0] as SimLevel.MoverSpec).period,
		(untouched.movers[0] as SimLevel.MoverSpec).period
	)
	assert_eq(
		(original.par_placements[0] as SimLevel.MagnetSpec).x,
		(untouched.par_placements[0] as SimLevel.MagnetSpec).x
	)
	assert_eq(int((original.par_holds[0] as Array)[1]), int((untouched.par_holds[0] as Array)[1]))


## A quarter turn swaps the sides and leaves the middle where it was, give or take
## the half step the grid costs.
##
## Half a step is the price of the trade, and it is the right way round: keeping the
## middle is how a shape stands up *in place* instead of jumping across the board,
## and five pixels does not spend that. Being off the grid afterwards would.
func test_turning_swaps_the_sides_around_the_middle() -> void:
	var r := Rect2(200, 400, 200, 30)
	var turned := LevelSource.rotated(r, 10.0)
	assert_eq(str(turned.size), str(Vector2(30, 200)), "Seiten nicht getauscht")
	var drift := (turned.get_center() - r.get_center()).length()
	assert_true(drift <= 5.0 * sqrt(2.0), "Mitte um %.1f px verschoben" % drift)


## Four turns land exactly where they started.
##
## The version that kept the *corner* instead of the middle was reversible too, but
## it made a shape jump across the board rather than stand up in place. Keeping the
## middle and rounding to whole pixels gives both — for even side lengths, which is
## what campaign geometry is written in.
func test_four_turns_come_back_to_the_start() -> void:
	for r: Rect2 in [
		Rect2(200, 400, 200, 30), Rect2(0, 1200, 700, 40), Rect2(2620, 220, 24, 420),
	]:
		var back := LevelSource.rotated(
			LevelSource.rotated(
				LevelSource.rotated(LevelSource.rotated(r, 10.0), 10.0), 10.0
			),
			10.0
		)
		assert_eq(str(back), str(r), "viermal gedreht ist nicht wieder da")


## Turning keeps geometry on whole pixels.
##
## Level 15's par had to be re-derived once because the authoring tool placed
## magnets on fractions and printed them as integers. Anything that writes geometry
## has to stay on the numbers the file can hold.
func test_turning_stays_on_whole_pixels() -> void:
	for step: float in [0.0, 10.0]:
		var odd := LevelSource.rotated(Rect2(105, 207, 33, 15), step)
		assert_eq(odd.position.x, roundf(odd.position.x), "x nicht ganzzahlig")
		assert_eq(odd.position.y, roundf(odd.position.y), "y nicht ganzzahlig")


## A turn leaves the board on its grid.
##
## The case that used to break it: sides whose difference is not a multiple of
## twenty, so half of it is a multiple of five. A 200×30 wall — which is what most
## of the campaign’s platforms are — turned to x=185 and took every number measured
## off it with it.
func test_turning_keeps_the_board_on_its_grid() -> void:
	for r: Rect2 in [
		Rect2(200, 400, 200, 30), Rect2(100, 100, 200, 30), Rect2(0, 1200, 700, 50),
		Rect2(2620, 220, 30, 410),
	]:
		var turned := LevelSource.rotated(r, 10.0)
		assert_eq(fmod(turned.position.x, 10.0), 0.0, "x %s nicht im Raster" % turned.position.x)
		assert_eq(fmod(turned.position.y, 10.0), 0.0, "y %s nicht im Raster" % turned.position.y)


## A shape put somewhere unround on purpose stays exactly as unround as it was.
##
## Alt places without the grid, and a turn afterwards must not quietly drag the
## shape onto it — the turn adds a whole number of steps and never a fraction of
## one. This is what the *offset* being rounded buys over the position.
func test_turning_leaves_an_unround_shape_alone() -> void:
	var r := Rect2(127, 343, 200, 30)
	var turned := LevelSource.rotated(r, 10.0)
	assert_eq(fmod(turned.position.x - r.position.x, 10.0), 0.0, "x aufs Raster gezogen")
	assert_eq(fmod(turned.position.y - r.position.y, 10.0), 0.0, "y aufs Raster gezogen")


## The lattice is symmetric about zero, which is what makes a turn reversible.
##
## [method @GlobalScope.snappedf] is not: it rounds halves upward, so +85 lands on
## +90 while −85 lands on −80. A quarter turn adds half the difference of the sides
## and the next one takes it back, so five pixels of asymmetry there is twenty
## pixels of drift over four turns — measured, before this existed.
func test_the_lattice_is_symmetric_about_zero() -> void:
	for v: Vector2 in [Vector2(85, 5), Vector2(12, 0), Vector2(1183.7, -7.5)]:
		assert_eq(
			str(LevelSource.on_lattice(-v, 10.0)),
			str(-LevelSource.on_lattice(v, 10.0)),
			"%s und sein Gegenteil runden verschieden" % v
		)
	assert_eq(str(LevelSource.on_lattice(Vector2(85, -85), 10.0)), str(Vector2(90, -90)))
	assert_eq(str(LevelSource.on_lattice(Vector2(1183.7, 0.4), 0.0)), str(Vector2(1184, 0)))


## A path turns with the thing it belongs to, anticlockwise, keeping its length.
##
## The direction is spelled out because screen axes invert the intuition: y grows
## downward, so anticlockwise sends a *downward* vector to a *rightward* one. A
## lift that kept running up and down after its shaft was laid on its side would be
## a surprise rather than a convenience — and a path whose length changed would
## silently change the platform's speed, since the period is derived from it.
func test_a_path_turns_with_its_owner() -> void:
	var down := Vector2(0, 100)
	var right := LevelSource.turned(down)
	assert_eq(str(right), str(Vector2(100, 0)), "runter wird nicht rechts")
	assert_eq(str(LevelSource.turned(right)), str(Vector2(0, -100)), "rechts wird nicht hoch")
	assert_eq(right.length(), down.length(), "Länge verändert")
	var round_trip := LevelSource.turned(
		LevelSource.turned(LevelSource.turned(LevelSource.turned(down)))
	)
	assert_eq(str(round_trip), str(down), "viermal gedreht ist nicht wieder da")


## Aligning keeps the size and moves only the one axis asked for.
##
## The failure that would be easy to miss: a shape that also drifts sideways when
## you asked for the same height. On a board that would silently move a platform
## out from under the jump it was cut for.
func test_aligning_moves_one_axis_and_keeps_the_size() -> void:
	var anchor := Rect2(200, 400, 200, 30)
	var other := Rect2(600, 530, 160, 40)

	var level_with := LevelSource.align_to(other, anchor, false, false)
	assert_eq(level_with.position.y, 400.0, "Höhe nicht übernommen")
	assert_eq(level_with.position.x, 600.0, "seitlich verrutscht")
	assert_eq(str(level_with.size), str(other.size), "Größe verändert")

	var column := LevelSource.align_to(other, anchor, true, false)
	assert_eq(column.position.x, 200.0, "Spalte nicht übernommen")
	assert_eq(column.position.y, 530.0, "senkrecht verrutscht")


## Centre alignment lines up middles, not edges.
##
## Two shapes of different widths on the same left edge are not centred, and on a
## board that difference is visible — it is the whole reason the variant exists.
func test_aligning_by_centre_lines_up_middles() -> void:
	var anchor := Rect2(200, 400, 200, 30)   # centre x 300
	var other := Rect2(600, 530, 160, 40)    # width 160

	var centred := LevelSource.align_to(other, anchor, true, true)
	assert_eq(centred.get_center().x, anchor.get_center().x, "Mitten nicht bündig")
	assert_eq(centred.position.x, 220.0, "erwartet 300 - 80")

	var stacked := LevelSource.align_to(other, anchor, false, true)
	assert_eq(stacked.get_center().y, anchor.get_center().y, "Mitten nicht bündig")


## Aligning something to itself changes nothing. The build screen skips the anchor,
## but the arithmetic has to be harmless anyway — it is the case a future caller
## will hit first.
func test_aligning_to_itself_changes_nothing() -> void:
	var r := Rect2(120, 340, 90, 25)
	for vertical in [false, true]:
		for by_centre in [false, true]:
			assert_eq(str(LevelSource.align_to(r, r, vertical, by_centre)), str(r))


## The two strengths are written separately.
##
## They are different knobs — one is the ball in your hand, the other is what the
## board does on its own — and an export that folded them into one would quietly
## change a level on the way back into `levels.gd`.
func test_the_emitter_writes_both_strengths() -> void:
	var draft := LevelSource.blank()
	draft.magnet_strength = 6000.0
	draft.field_strength = 3200.0
	var text := LevelSource.to_gdscript(draft, "_probe")
	assert_true(text.contains("level.magnet_strength = 6000"), "Magnetstärke fehlt")
	assert_true(text.contains("level.field_strength = 3200"), "Fremdfeld-Stärke fehlt")


## A world that was chosen is written down.
##
## The counterpart to the omission test above: leaving it out would lose the one
## thing the build mode cannot re-derive from geometry.
func test_the_emitter_writes_a_world_that_was_chosen() -> void:
	var draft := LevelSource.blank()
	draft.theme = "Werft"
	assert_true(
		LevelSource.to_gdscript(draft, "_probe").contains('level.theme = "Werft"'),
		"Welt fehlt im Text"
	)


## A world is scenery, and scenery never reaches the rules.
##
## The strictest version of "presentation only": two boards that differ in nothing
## but their theme have to produce the same run, tick for tick and bit for bit. If
## this ever fails, something that belongs in the art layer has leaked into
## [SimWorld] — and every pinned fingerprint in `test_sim.gd` becomes a statement
## about the palette.
func test_a_world_never_reaches_the_simulation() -> void:
	for name: String in ["Werft", "Schacht", "Reaktor", "Wrack", "Sortieranlage", "Sturm"]:
		var plain := Levels.by_id(15)
		var dressed := LevelSource.copy(plain)
		dressed.theme = name

		var bare := SimWorld.new()
		bare.setup(plain, _specs(plain.par_placements))
		var one := bare.run_schedule(plain.par_holds)

		var painted := SimWorld.new()
		painted.setup(dressed, _specs(dressed.par_placements))
		var two := painted.run_schedule(dressed.par_holds)

		assert_eq(int(two["hash"]), int(one["hash"]), "Welt %s verschiebt die Bahn" % name)
		assert_eq(int(two["ticks"]), int(one["ticks"]), "Welt %s verschiebt die Dauer" % name)


## An unknown world is the default one. A typo in a level definition should cost
## the look, not the level.
func test_an_unknown_world_falls_back() -> void:
	PolarisTheme.use("Gibtsnicht")
	assert_eq(PolarisTheme.world().name, "Polaris")
	PolarisTheme.use("Reaktor")
	assert_eq(PolarisTheme.world().name, "Reaktor")
	PolarisTheme.use("")
	assert_eq(PolarisTheme.world().name, "Polaris")


## A world repaints the scenery and nothing that carries meaning.
##
## Red pulls, blue pushes, amber is the goal, mint is a checkpoint. A board that
## recolours those is not a new world — it is a board the player has to learn to
## read again, and the campaign's first ten levels taught that vocabulary.
func test_a_world_repaints_scenery_and_not_meaning() -> void:
	var before := [
		PolarisTheme.PLUS, PolarisTheme.MINUS, PolarisTheme.TARGET,
		PolarisTheme.ACCENT, PolarisTheme.OK, PolarisTheme.BALL,
		PolarisTheme.ZONE_BODY, PolarisTheme.ZONE_UP, PolarisTheme.ZONE_DOWN,
		PolarisTheme.INK, PolarisTheme.BG,
	]
	for world: PolarisTheme.World in PolarisTheme.WORLDS:
		PolarisTheme.use(world.name)
		var after := [
			PolarisTheme.PLUS, PolarisTheme.MINUS, PolarisTheme.TARGET,
			PolarisTheme.ACCENT, PolarisTheme.OK, PolarisTheme.BALL,
			PolarisTheme.ZONE_BODY, PolarisTheme.ZONE_UP, PolarisTheme.ZONE_DOWN,
			PolarisTheme.INK, PolarisTheme.BG,
		]
		assert_eq(str(after), str(before), "Welt %s fasst die Bedeutung an" % world.name)
	PolarisTheme.use("")


## Every world separates the ground you can stand on from the ground you cannot.
##
## That contrast is the only thing a palette must not lose. A wall face darker than
## the background behind it makes a platform read as a hole.
func test_every_world_keeps_its_walls_readable() -> void:
	var flat: Array[String] = []
	for world: PolarisTheme.World in PolarisTheme.WORLDS:
		if world.face_top.get_luminance() <= world.low.get_luminance() + 0.05:
			flat.append(world.name)
	assert_true(flat.is_empty(), "Wandfläche hebt sich nicht ab: " + ", ".join(flat))


## Every world's bands are a whole board, and every motif it names can be drawn.
##
## Shares that fall short leave a seam of unpainted arena; shares that overshoot
## push the last band off the bottom. A name with no branch behind it is worse
## than either — [method WorldArt._motif] simply draws nothing, the world looks
## thin, and no error is ever raised.
func test_every_world_band_adds_up() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/ui/world_art.gd")
	assert_true(source.length() > 0, "world_art.gd nicht lesbar")
	var problems: Array[String] = []
	for world: PolarisTheme.World in PolarisTheme.WORLDS:
		if world.bands.is_empty():
			problems.append("%s hat keine Bänder" % world.name)
			continue
		var total := 0.0
		for entry: Array in world.bands:
			total += float(entry[1])
			if not source.contains('"%s": _' % String(entry[0])):
				problems.append("%s: Motiv \"%s\" wird nirgends gezeichnet" % [
					world.name, String(entry[0])
				])
		if absf(total - 1.0) > 0.0001:
			problems.append("%s: Anteile ergeben %.3f" % [world.name, total])
	assert_true(problems.is_empty(), "
".join(problems))


## The scenery never borrows a colour that already means something.
##
## [constant PolarisTheme.PLUS] pulls, [constant PolarisTheme.MINUS] pushes,
## [constant PolarisTheme.TARGET] is the goal, [constant PolarisTheme.OK] is a
## checkpoint. The player learned all four in the first ten boards, and a world
## that repaints one is not a new place — it is a board that has to be read again
## from scratch.
##
## Checked by reading the source rather than by comparing colours, because that is
## the only way to catch it *everywhere*: a palette test can compare the seven
## fields of a [PolarisTheme.World], but not a motif that reaches past them and
## draws in a constant directly. [WorldArt] exists as its own file so that this
## question has a file to ask it about.
##
## Comment lines are stripped first, since the file's own header names all six of
## them while explaining that it may not use them.
func test_scenery_never_borrows_a_meaning() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/ui/world_art.gd")
	assert_true(source.length() > 0, "world_art.gd nicht lesbar")
	var code := ""
	for line: String in source.split("
"):
		if line.strip_edges().begins_with("#"):
			continue
		code += line + "
"
	var borrowed: Array[String] = []
	for name: String in ["PLUS", "MINUS", "TARGET", "OK", "ACCENT", "BALL"]:
		if code.contains("PolarisTheme." + name):
			borrowed.append(name)
	assert_true(
		borrowed.is_empty(),
		"Kulisse greift nach einer Bedeutung: " + ", ".join(borrowed)
	)


## A polygon goes out as source that reads as geometry.
##
## One outline per line, every corner spelled out — including one at the origin,
## which the general vector formatter would have written as `Vector2.ZERO`. That is
## right for a path that goes nowhere and wrong for a corner.
func test_the_emitter_writes_a_polygon() -> void:
	var draft := LevelSource.blank()
	draft.polygons = [PackedVector2Array([Vector2(0, 0), Vector2(200, 0), Vector2(100, 150)])]
	var text := LevelSource.to_gdscript(draft, "_probe")
	assert_true(text.contains("\tlevel.polygons = [\n"), "keine Polygonliste im Export")
	assert_true(
		text.contains("PackedVector2Array([Vector2(0, 0), Vector2(200, 0), Vector2(100, 150)]),"),
		"Polygon nicht als lesbare Ecken geschrieben:\n" + text
	)


## An undo snapshot owns its corners.
##
## A packed array can be handed around by reference, so a copy that took the list
## but not each outline would let the draft and its undo step edit the same
## corners — and undo would then restore a shape that had moved with it.
func test_a_copied_draft_shares_no_corners() -> void:
	var original := LevelSource.blank()
	original.polygons = [PackedVector2Array([Vector2(0, 0), Vector2(200, 0), Vector2(100, 150)])]
	var clone := LevelSource.copy(original)
	var corners: PackedVector2Array = clone.polygons[0]
	corners[1] = Vector2(999, 999)
	clone.polygons[0] = corners
	assert_eq(str(original.polygons[0][1]), str(Vector2(200, 0)), "die Kopie teilt ihre Ecken")


## A polygon turns exactly as a box does: in place, on the grid, and four turns
## come back to the start.
##
## Built on [method LevelSource.rotated], so it inherits that function's proofs —
## and this checks the inheritance holds: the turned outline's box *is* the turned
## box, for a shape whose box has an odd half-difference of sides (the case that
## once walked a wall twenty pixels in four turns).
func test_turning_a_polygon_four_times_comes_back() -> void:
	for outline: PackedVector2Array in [
		PackedVector2Array([Vector2(100, 100), Vector2(300, 100), Vector2(100, 130)]),
		PackedVector2Array([
			Vector2(200, 200), Vector2(400, 200), Vector2(400, 240),
			Vector2(260, 240), Vector2(260, 420), Vector2(200, 420),
		]),
		PackedVector2Array([Vector2(200, 200), Vector2(290, 230), Vector2(240, 370)]),
	]:
		var turning := outline
		for turn in 4:
			var box := SimLevel.polygon_bounds(turning)
			turning = LevelSource.rotated_polygon(turning, 10.0)
			assert_eq(
				str(SimLevel.polygon_bounds(turning)), str(LevelSource.rotated(box, 10.0)),
				"Drehung %d: der Umriss folgt seinem Kasten nicht" % (turn + 1)
			)
			for corner: Vector2 in turning:
				assert_eq(fmod(corner.x, 10.0), 0.0, "Ecke %s nicht im Raster" % corner)
				assert_eq(fmod(corner.y, 10.0), 0.0, "Ecke %s nicht im Raster" % corner)
		assert_eq(str(turning), str(outline), "viermal gedreht ist nicht wieder da")


## And it turns the same way a box's path does: anticlockwise as the screen sees it.
##
## A triangle whose sharp tip points right must point *up* afterwards. Screen y
## grows downward, which is exactly where getting this backwards is easy — so the
## direction is checked on a shape, not just on the arithmetic.
func test_a_polygon_turns_anticlockwise() -> void:
	var arrow := PackedVector2Array([Vector2(0, 0), Vector2(200, 50), Vector2(0, 100)])
	var turned := LevelSource.rotated_polygon(arrow, 10.0)
	var top := turned[0].y
	for corner: Vector2 in turned:
		top = minf(top, corner.y)
	assert_eq(turned[1].y, top, "die Spitze zeigt nach der Drehung nicht nach oben: %s" % turned)


## An outline that cannot be a wall is refused, and says why.
##
## "Inside" only means something for a simple polygon. A bow-tie has two insides
## that a crossing count calls one; a corner visited twice pinches the shape to a
## point; an edge that runs back along itself has no width at all. Each gets its
## own sentence, because the hint line is the only place the builder learns it.
func test_a_bad_outline_is_refused() -> void:
	var cases := [
		[PackedVector2Array([Vector2(0, 0), Vector2(100, 0)]), "drei Ecken"],
		[PackedVector2Array([Vector2(0, 0), Vector2(100, 100), Vector2(100, 0), Vector2(0, 100)]), "kreuzen"],
		[PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(100, 0), Vector2(0, 100)]), "aufeinander"],
		[PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(50, 0)]), "zurück"],
		[PackedVector2Array([
			Vector2(0, 0), Vector2(100, 0), Vector2(50, 50),
			Vector2(100, 100), Vector2(0, 100), Vector2(50, 50),
		]), "kreuzen"],
	]
	for case: Array in cases:
		var problem := LevelSource.polygon_problem(case[0] as PackedVector2Array)
		assert_true(
			problem.contains(String(case[1])),
			"%s: erwartet \"%s\", bekommen \"%s\"" % [case[0], case[1], problem]
		)

	for fine: PackedVector2Array in [
		PackedVector2Array([Vector2(0, 0), Vector2(200, 50), Vector2(0, 100)]),
		PackedVector2Array([
			Vector2(200, 300), Vector2(260, 300), Vector2(260, 540), Vector2(540, 540),
			Vector2(540, 300), Vector2(600, 300), Vector2(600, 600), Vector2(200, 600),
		]),
	]:
		assert_eq(LevelSource.polygon_problem(fine), "", "ein gültiger Umriss wird abgelehnt: %s" % fine)


## A duration reads as a duration.
##
## `charge_seconds = 2` assigns an int to a float field — legal, and it reads as a
## count of something rather than as a span of time.
func test_a_duration_keeps_its_decimal_point() -> void:
	var draft := LevelSource.blank()
	draft.charge_seconds = 2.0
	assert_true(
		LevelSource.to_gdscript(draft, "_probe").contains("level.charge_seconds = 2.0"),
		"Ladung ohne Komma geschrieben"
	)


## A blank draft is a board, not an empty arena: it has a floor, a ball on it and
## a goal. An empty one gives nothing to drag against.
func test_a_blank_draft_is_something_to_start_from() -> void:
	var draft := LevelSource.blank()
	assert_true(not draft.solids.is_empty(), "kein Boden")
	assert_true(draft.target.has_area(), "kein Ziel")
	assert_true(draft.budget >= 1, "kein Magnet im Budget")
	assert_true(draft.arena.has_point(draft.start), "Start liegt ausserhalb der Arena")


func _specs(placements: Array) -> Array:
	var out: Array = []
	for magnet: SimLevel.MagnetSpec in placements:
		out.append(magnet.duplicate_spec())
	return out


func _sorted(holds: Array) -> Array:
	var out: Array = []
	for entry: Array in holds:
		out.append([int(entry[0]), int(entry[1]), int(entry[2])])
	out.sort_custom(func(a: Array, b: Array) -> bool:
		if int(a[1]) != int(b[1]):
			return int(a[1]) < int(b[1])
		return int(a[0]) < int(b[0])
	)
	return out
