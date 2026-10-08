@tool
class_name LevelSource
extends RefCounted

## Turns a drafted [SimLevel] into the GDScript that defines it, and makes the
## copies the build screen's undo stack is built from.
##
## **It writes source text, not a save file, and that is the design.** Levels are
## code in this project, and the par finder already works exactly this way: it
## writes `tools/found_par.txt` and a person transcribes it. A serialisation
## format would be a *second* definition of what a level is, carrying a
## compatibility burden forever, bought to save a step that takes ten seconds.
##
## Nothing here touches [SimWorld] or the campaign. The build screen edits a level
## that exists only in memory, and the only thing that ever reaches `levels.gd` is
## text a person looked at.

## The starting board a new draft gets: a floor, a ball on it, a goal at the far
## end. Deliberately winnable-looking rather than empty — an empty arena gives
## nothing to drag against, and the first thing you do is move these anyway.
static func blank() -> SimLevel:
	var level := SimLevel.new()
	level.id = 99
	level.title = "Entwurf"
	level.feature = "Entwurf"
	level.lesson = "Noch keine Lektion."
	level.arena = Rect2(0, 0, 1400, 900)
	level.solids = [Rect2(0, 800, 1400, 40)]
	level.start = Vector2(140, 760)
	level.target = Rect2(1120, 660, 220, 140)
	level.budget = 1
	level.charge_seconds = 1.5
	return level


## A deep copy. Every list is rebuilt and every spec duplicated, so an undo step
## cannot share a rectangle with the level it was taken from.
static func copy(level: SimLevel) -> SimLevel:
	var out := SimLevel.new()
	out.id = level.id
	out.title = level.title
	out.feature = level.feature
	out.lesson = level.lesson
	out.theme = level.theme
	out.arena = level.arena
	out.start = level.start
	out.target = level.target
	out.solids = level.solids.duplicate()
	# Each outline duplicated on its own: a packed array handed around by reference
	# would let an undo step and the live draft edit the same corners.
	for points: PackedVector2Array in level.polygons:
		out.polygons.append(points.duplicate())
	out.hazards = level.hazards.duplicate()
	for spring: SimLevel.BounceSpec in level.springs:
		out.springs.append(spring.duplicate_spec())
	out.slowmo_points = level.slowmo_points.duplicate()
	for cp: SimLevel.Checkpoint in level.checkpoints:
		out.checkpoints.append(SimLevel.Checkpoint.new(cp.rect, cp.grants))
	for zone: SimLevel.GravitySpec in level.zones:
		out.zones.append(zone.duplicate_spec())
	for mover: SimLevel.MoverSpec in level.movers:
		out.movers.append(mover.duplicate_spec())
	for magnet: SimLevel.MagnetSpec in level.fixed_magnets:
		out.fixed_magnets.append(magnet.duplicate_spec())
	for magnet: SimLevel.MagnetSpec in level.par_placements:
		out.par_placements.append(magnet.duplicate_spec())
	for entry: Array in level.par_holds:
		out.par_holds.append(entry.duplicate())
	out.flip_enabled = level.flip_enabled
	out.paths_enabled = level.paths_enabled
	out.min_flip_window = level.min_flip_window
	out.min_timing_window = level.min_timing_window
	out.magnet_strength = level.magnet_strength
	out.field_strength = level.field_strength
	out.slowmo_ticks = level.slowmo_ticks
	out.max_ticks = level.max_ticks
	out.twin_of = level.twin_of
	out.budget = level.budget
	out.charge_seconds = level.charge_seconds
	return out


## [param r] moved onto [param anchor]'s line, keeping its size.
##
## [param vertical] means one column — the x matches. Otherwise one height — the y
## matches, which is the alignment a board wants most, because a platform's top
## edge is where the ball lands. [param by_centre] lines up middles instead of
## edges.
##
## Here rather than in the build screen because it is arithmetic, and the screen is
## the one part of this the test runner cannot instantiate. A rule that can be
## checked should live where it can be checked.
static func align_to(r: Rect2, anchor: Rect2, vertical: bool, by_centre: bool) -> Rect2:
	var at := r.position
	if vertical:
		at.x = anchor.get_center().x - r.size.x * 0.5 if by_centre else anchor.position.x
	else:
		at.y = anchor.get_center().y - r.size.y * 0.5 if by_centre else anchor.position.y
	return Rect2(at, r.size)


## [param r] turned a quarter turn about its own middle, staying on a [param step]
## lattice.
##
## **Ninety degrees, because a box stays a box.** [SimWorld] finds the nearest
## point on a solid with one clamp per axis, and a box turned to any other angle
## would stop being something that query can answer.
##
## That is the whole of the limit. An earlier version of this comment said a free
## angle would mean a different collision model and every replay re-derived, and it
## was wrong: the bounce is already written along an arbitrary normal. A slope would
## be a shape of its own — a segment given by its end points, never by an angle —
## with its own nearest-point query, and boards without one would not change.
##
## The middle is kept, not the corner, so the shape turns in place instead of
## jumping — and what gets written is an *offset*, not a position. That is the part
## that keeps a board on its grid.
##
## A quarter turn moves a corner by half the difference of the sides, and sides are
## multiples of ten, so that half is a multiple of *five*: a 200×30 wall at x=100
## lands at 185, and every number taken off it afterwards is off the grid. Rounding
## the resulting *position* would fix that and break something better — the half
## always rounds the same way, so four turns walk the shape twenty pixels across the
## board. Rounding the *offset* symmetrically about zero gives both: the second turn
## subtracts exactly what the first added, so two turns are the identity and four
## are as well. It also leaves a shape put somewhere unround on purpose exactly as
## unround as it was, because what is added is always a whole number of steps.
static func rotated(r: Rect2, step: float) -> Rect2:
	var half := (r.size - Vector2(r.size.y, r.size.x)) * 0.5
	return Rect2(r.position + on_lattice(half, step), Vector2(r.size.y, r.size.x))


## [param v] rounded to the nearest multiple of [param step]; zero or less rounds to
## whole pixels.
##
## **Symmetric about zero**, which [method @GlobalScope.snappedf] is not — it rounds
## halves upward, so +85 becomes +90 while −85 becomes −80. Anything that adds an
## offset and later takes it back would drift one step every time.
static func on_lattice(v: Vector2, step: float) -> Vector2:
	if step <= 0.0:
		return Vector2(roundf(v.x), roundf(v.y))
	return Vector2(roundf(v.x / step) * step, roundf(v.y / step) * step)


## [param points] turned a quarter turn anticlockwise, exactly as [method rotated]
## turns a box.
##
## Built on the box on purpose. The outline's bounding box goes through [method
## rotated] — and so inherits everything that function had to get right: it stays
## on the grid, and four turns land where they started — and each corner is then
## placed inside the turned box by a pure quarter turn of its offset, which is exact
## on whole pixels. Turning about the polygon's own middle directly would have been
## shorter and would have walked, for the reason [method rotated] explains.
static func rotated_polygon(points: PackedVector2Array, step: float) -> PackedVector2Array:
	var box := SimLevel.polygon_bounds(points)
	var turned_box := rotated(box, step)
	var out := PackedVector2Array()
	for point: Vector2 in points:
		out.append(turned_box.position + Vector2(
			point.y - box.position.y, box.size.x - (point.x - box.position.x)
		))
	return out


## [param points] moved by [param by].
static func translated(points: PackedVector2Array, by: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for point: Vector2 in points:
		out.append(point + by)
	return out


## Why [param points] cannot be a wall, as a sentence for the build mode's hint
## line — or an empty string if it can.
##
## "Inside" only means something for a *simple* polygon: no edge crossing another,
## no corner visited twice, some area enclosed. A bow-tie has two insides that the
## crossing count calls one, and the simulation would push the ball out of whichever
## edge was nearest — sometimes the wrong way. So these are refused at the point of
## drawing, where fixing them is one keypress, rather than discovered in a run.
##
## Exact on whole-pixel corners: every test is a cross product or a comparison, and
## the cross products of coordinates this size are integers a double holds exactly.
## The crossing test compares *signs* rather than multiplying two cross products,
## because that product would not be.
static func polygon_problem(points: PackedVector2Array) -> String:
	var count := points.size()
	if count < 3:
		return "Ein Polygon braucht mindestens drei Ecken."
	for i in count:
		if points[i] == points[(i + 1) % count]:
			return "Zwei Ecken liegen aufeinander."
	for i in count:
		var before := points[(i - 1 + count) % count]
		var here := points[i]
		var after := points[(i + 1) % count]
		# Three corners on a line with the middle one past the end: an edge that runs
		# back along itself. Zero width, and a crossing count cannot see it.
		if _orient(before, here, after) == 0.0 and (here - before).dot(after - here) < 0.0:
			return "Eine Kante läuft auf sich selbst zurück."
	for i in count:
		var a := points[i]
		var b := points[(i + 1) % count]
		for j in range(i + 1, count):
			# Neighbours share a corner and are allowed to touch there.
			if j == i + 1 or (i == 0 and j == count - 1):
				continue
			if _segments_meet(a, b, points[j], points[(j + 1) % count]):
				return "Zwei Kanten kreuzen sich."
	if SimWorld.winding(points) == 0.0:
		return "Das Polygon hat keine Fläche."
	return ""


## Which side of the line through [param a] and [param b] [param c] is on: positive,
## negative, or exactly on it.
static func _orient(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b - a).cross(c - a)


## Whether segments a–b and c–d share any point, touching included.
static func _segments_meet(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
	var d1 := _orient(c, d, a)
	var d2 := _orient(c, d, b)
	var d3 := _orient(a, b, c)
	var d4 := _orient(a, b, d)
	if d1 != 0.0 and d2 != 0.0 and d3 != 0.0 and d4 != 0.0:
		return (d1 > 0.0) != (d2 > 0.0) and (d3 > 0.0) != (d4 > 0.0)
	return (
		(d1 == 0.0 and _within(c, d, a)) or (d2 == 0.0 and _within(c, d, b))
		or (d3 == 0.0 and _within(a, b, c)) or (d4 == 0.0 and _within(a, b, d))
	)


## For a point already known to be on the line through [param a] and [param b]:
## whether it lies between them.
static func _within(a: Vector2, b: Vector2, point: Vector2) -> bool:
	return (
		minf(a.x, b.x) <= point.x and point.x <= maxf(a.x, b.x)
		and minf(a.y, b.y) <= point.y and point.y <= maxf(a.y, b.y)
	)


## [param v] turned a quarter turn anticlockwise, as the screen sees it.
##
## Screen axes, so y grows *downward*: a vector pointing down becomes one pointing
## right, and one pointing right becomes one pointing up. Getting that backwards is
## the easy mistake here, which is why it is written out.
##
## One direction only. Four presses come back round, so the other way is three
## presses away, and a modifier that silently reverses a key is worse than the
## three presses it saves.
##
## Platform paths and field paths turn with the thing they belong to; a lift that
## kept running up and down after its shaft was laid on its side would be a
## surprise, not a convenience. Length is preserved, so the period a path implies
## does not change.
static func turned(v: Vector2) -> Vector2:
	return Vector2(v.y, -v.x)


## A recorded run's per-tick masks turned back into a hold schedule.
##
## **This is what makes a hand-built level cheap to ship.** The expensive half of
## the level pipeline is proving a board can be won; for a board you built and then
## beat, the proof is the run you just made, and [member PlayScreen.recording]
## already holds it. No search, no solver — the author *is* the verification.
##
## The open holds are tracked in an [Array] indexed by bit rather than a
## [Dictionary], so the output order is the written one. Same reason the simulation
## never iterates a dictionary, applied to a tool that has to produce the same text
## twice.
static func holds_from(recording: Array) -> Array:
	var slots := SimWorld.HOLD_KEYS + 1  # the magnets, then the invert bit
	var opened: Array[int] = []
	for _s in slots:
		opened.append(-1)
	var out: Array = []

	for t in recording.size():
		var mask := int(recording[t])
		for slot in slots:
			var bit := slot if slot < SimWorld.HOLD_KEYS else SimWorld.INVERT_INPUT
			var held := (mask & (1 << bit)) != 0
			if held and opened[slot] < 0:
				opened[slot] = t
			elif not held and opened[slot] >= 0:
				out.append([bit, opened[slot], t])
				opened[slot] = -1

	for slot in slots:
		if opened[slot] >= 0:
			var bit := slot if slot < SimWorld.HOLD_KEYS else SimWorld.INVERT_INPUT
			out.append([bit, opened[slot], recording.size()])

	out.sort_custom(func(a: Array, b: Array) -> bool:
		if int(a[1]) != int(b[1]):
			return int(a[1]) < int(b[1])
		return int(a[0]) < int(b[0])
	)
	return out


## The level as a `levels.gd` builder function, ready to paste.
##
## Only fields that differ from their default are written. A draft that never
## touched slowed time should not ship a line claiming it did — the definitions in
## `levels.gd` are read as documentation, and a wall of zeroes hides the two
## numbers that matter.
static func to_gdscript(level: SimLevel, fn_name: String) -> String:
	var out: Array[String] = []
	out.append("## TODO: Lektion und Feature eintragen, bevor das hier in die Kampagne geht.")
	out.append("static func %s() -> SimLevel:" % fn_name)
	out.append("\tvar level := _make(%d, \"%s\", \"%s\")" % [level.id, level.title, level.lesson])
	out.append("\tlevel.feature = \"%s\"" % level.feature)
	if not level.theme.is_empty():
		out.append("\tlevel.theme = \"%s\"" % level.theme)
	out.append("\tlevel.arena = %s" % _rect(level.arena))
	if level.max_ticks > 0:
		out.append("\tlevel.max_ticks = %d" % level.max_ticks)
	if level.magnet_strength > 0.0:
		out.append("\tlevel.magnet_strength = %s" % _num(level.magnet_strength))
	if level.field_strength > 0.0:
		out.append("\tlevel.field_strength = %s" % _num(level.field_strength))

	if not level.solids.is_empty():
		out.append("\tlevel.solids = [")
		for solid: Rect2 in level.solids:
			out.append("\t\t%s," % _rect(solid))
		out.append("\t]")

	if not level.polygons.is_empty():
		out.append("\tlevel.polygons = [")
		for points: PackedVector2Array in level.polygons:
			var corners := PackedStringArray()
			for point: Vector2 in points:
				corners.append(_point(point))
			out.append("\t\tPackedVector2Array([%s])," % ", ".join(corners))
		out.append("\t]")

	if not level.hazards.is_empty():
		out.append("\tlevel.hazards = [")
		for hazard: Rect2 in level.hazards:
			out.append("\t\t%s," % _rect(hazard))
		out.append("\t]")

	if not level.springs.is_empty():
		out.append("\tlevel.springs = [")
		for spring: SimLevel.BounceSpec in level.springs:
			out.append("\t\tSimLevel.BounceSpec.new(%s, %s)," % [
				_rect(spring.rect), _vec(spring.push)
			])
		out.append("\t]")

	if not level.movers.is_empty():
		out.append("\tlevel.movers = [")
		for mover: SimLevel.MoverSpec in level.movers:
			out.append("\t\tSimLevel.MoverSpec.new(%s, %s, %s%s)," % [
				_rect(mover.rect), _vec(mover.travel),
				_period(mover.travel, mover.period),
				"" if mover.phase == 0 else ", %d" % mover.phase,
			])
		out.append("\t]")

	if not level.zones.is_empty():
		out.append("\tlevel.zones = [")
		for zone: SimLevel.GravitySpec in level.zones:
			out.append("\t\tSimLevel.GravitySpec.new(%s, %d%s)," % [
				_rect(zone.rect), zone.period,
				"" if zone.phase == 0 else ", %d" % zone.phase,
			])
		out.append("\t]")

	if not level.fixed_magnets.is_empty():
		out.append("\tlevel.fixed_magnets = [")
		for magnet: SimLevel.MagnetSpec in level.fixed_magnets:
			out.append("\t\t%s," % _magnet(magnet))
		out.append("\t]")

	out.append("\tlevel.start = %s" % _vec(level.start))
	out.append("\tlevel.target = %s" % _rect(level.target))

	if not level.checkpoints.is_empty():
		out.append("\tlevel.checkpoints = [")
		for cp: SimLevel.Checkpoint in level.checkpoints:
			out.append("\t\tSimLevel.Checkpoint.new(%s, %d)," % [_rect(cp.rect), cp.grants])
		out.append("\t]")

	if not level.slowmo_points.is_empty():
		if level.slowmo_ticks > 0:
			out.append("\tlevel.slowmo_ticks = %d" % level.slowmo_ticks)
		out.append("\tlevel.slowmo_points = [")
		for rect: Rect2 in level.slowmo_points:
			out.append("\t\t%s," % _rect(rect))
		out.append("\t]")

	out.append("\tlevel.budget = %d" % level.budget)
	out.append("\tlevel.charge_seconds = %s" % _seconds(level.charge_seconds))

	if level.par_placements.is_empty():
		out.append("\t# Kein bewiesener Lauf: im Bau-Modus mit der Leertaste testen und")
		out.append("\t# gewinnen — der eigene Sieg wird hier zum Par.")
		out.append("\tlevel.par_placements = []")
		out.append("\tlevel.par_holds = []")
	else:
		out.append("\tlevel.par_placements = [")
		for magnet: SimLevel.MagnetSpec in level.par_placements:
			out.append("\t\t%s," % _magnet(magnet))
		out.append("\t]")
		var holds: Array[String] = []
		for entry: Array in level.par_holds:
			holds.append("[%d, %d, %d]" % [int(entry[0]), int(entry[1]), int(entry[2])])
		out.append("\tlevel.par_holds = [%s]" % ", ".join(holds))
	out.append("\treturn level")
	return "\n".join(out) + "\n"


## A magnet, written the way `levels.gd` writes them: the short two-argument form
## when nothing else is set, the full one otherwise.
static func _magnet(m: SimLevel.MagnetSpec) -> String:
	var plain := (
		not m.moves() and not m.always_on and m.spawn_tick == 0 and not m.fixed
	)
	if plain:
		return "SimLevel.MagnetSpec.new(%s, %s, %s, false)" % [
			_num(m.x), _num(m.y), "true" if m.attract else "false"
		]
	# The birth tick is only written when there is one. Every magnet placed before
	# the start carries 0, and a trailing `, 0` on a piece of field furniture reads
	# as a decision where there was none.
	return "SimLevel.MagnetSpec.new(%s, %s, %s, %s, %s, %s, %s%s)" % [
		_num(m.x), _num(m.y),
		"true" if m.attract else "false", "true" if m.fixed else "false",
		_vec(m.travel), _period(m.travel, m.period),
		"true" if m.always_on else "false",
		"" if m.spawn_tick == 0 else ", %d" % m.spawn_tick,
	]


## The period, as `SimWorld.sweep_ticks(...)` when that is what it is. A number
## that was derived should read as derived; a number someone chose should read as
## a number.
static func _period(travel: Vector2, period: int) -> String:
	if travel != Vector2.ZERO and SimWorld.sweep_ticks(travel) == period:
		return "SimWorld.sweep_ticks(%s)" % _vec(travel)
	return str(period)


static func _rect(r: Rect2) -> String:
	return "Rect2(%s, %s, %s, %s)" % [
		_num(r.position.x), _num(r.position.y), _num(r.size.x), _num(r.size.y)
	]


## A duration, always with a decimal point. `charge_seconds = 2` assigns an int to
## a float field — legal, and it reads as a count rather than as a span of time.
static func _seconds(value: float) -> String:
	var text := _num(value)
	return text if text.contains(".") else text + ".0"


## A corner, always spelled out. [method _vec] writes `Vector2.ZERO` for the origin,
## which is right for a path that goes nowhere and wrong for a corner that happens
## to sit in the top-left of the arena.
static func _point(v: Vector2) -> String:
	return "Vector2(%s, %s)" % [_num(v.x), _num(v.y)]


static func _vec(v: Vector2) -> String:
	if v == Vector2.ZERO:
		return "Vector2.ZERO"
	return "Vector2(%s, %s)" % [_num(v.x), _num(v.y)]


## Whole numbers without a decimal point, everything else with one. Level geometry
## is written in whole pixels throughout the campaign, and `Rect2(0, 1000, 700, 40)`
## reads as geometry where `Rect2(0.0, 1000.0, 700.0, 40.0)` reads as output.
static func _num(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(int(roundf(value)))
	var text := "%.2f" % value
	while text.ends_with("0"):
		text = text.substr(0, text.length() - 1)
	return text
