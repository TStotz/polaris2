class_name BoardArt
extends RefCounted

## How the board looks. Nothing here may influence what happens on it.
##
## Split out of [PlayScreen] on purpose: that file decides *when* to step the
## simulation and what a run means, and this one only decides which pixels come
## out. Keeping them apart is the same discipline that keeps [SimWorld] engine
## free — presentation is allowed things the simulation is not, and the boundary
## is where that permission changes.
##
## In particular this file may use `sin`, `Time`, and per-frame animation, none of
## which are allowed anywhere near the physics. What it must never do is feed a
## number back: every function takes what it draws as arguments and returns
## nothing.
##
## Variation across tiles is derived from tile coordinates through [method _hash],
## not from [method @GlobalScope.randf]. A random value drawn per frame would make
## the walls crawl; a hash of the position is stable, so the same brick keeps the
## same shade for the whole run.

## Small on purpose: most platforms in this campaign are 24-30px thick, and a
## tile larger than the block it sits in produces no visible texture at all.
const TILE := 15.0

## Face of a solid: lighter and warmer than the background, so the geometry you
## can stand on separates from the geometry you cannot.
##
## It comes from the active world rather than a constant here. That contrast is the
## one thing a theme must not lose, whatever colours it is made of — see
## [PolarisTheme.World].

# --- Background -------------------------------------------------------------

## The space behind the board: a vertical wash, a far layer of blocks that never
## move, the world's own scenery, and a soft floor glow. Drawn before anything else.
## [param seen] is the part of the board actually on screen. Everything is culled
## against it: a large arena has thousands of background cells, and drawing the
## ones behind the panel costs the same as drawing the ones you can see.
static func draw_background(ci: CanvasItem, arena: Rect2, seen: Rect2, t: float) -> void:
	var top: Color = PolarisTheme.world().deep
	var bottom: Color = PolarisTheme.world().low
	_gradient(ci, arena, top, top, bottom, bottom)

	# Two layers of far blocks at different sizes. One layer alone read as a grid;
	# the second, offset and larger, breaks the rhythm and gives the wall a depth.
	for layer in 2:
		var step := 58.0 if layer == 0 else 137.0
		var alpha := 0.16 if layer == 0 else 0.10
		var seed_mix := 11 if layer == 0 else 29
		var rows := int(arena.size.y / step) + 1
		var cols := int(arena.size.x / step) + 1
		for row in rows:
			for col in cols:
				var h := _hash(col * 31 + row * 17 + seed_mix * 977)
				if h % 3 == 0:
					continue
				var inset := 3.0 + float(h % 5)
				var cell := Rect2(
					arena.position.x + col * step + inset,
					arena.position.y + row * step + inset,
					step - inset * 2.0,
					step - inset * 2.0
				)
				if not arena.encloses(cell) or not seen.intersects(cell):
					continue
				var shade := alpha * (0.5 + float(h % 13) * 0.05)
				ci.draw_rect(cell, Color(PolarisTheme.world().wall, shade), true)
				ci.draw_rect(
					Rect2(cell.position, Vector2(cell.size.x, 1.0)),
					Color(PolarisTheme.world().wall_edge, shade * 1.6),
					true
				)

	# The world's own scenery, over the blocks and under the floor light. The blocks
	# stay because they are the *depth* — a hull, a stack of containers and a slab of
	# shielding are all square, so they make a substrate the motifs sit on rather
	# than something the motifs have to fight. What band you are in is [WorldArt]'s
	# question; this file only says how far back it all is.
	WorldArt.draw(ci, arena, seen, t)

	# A glow along the bottom edge, so the arena has a light source. Its hue is the
	# world's, not the repel magnet's — it was [constant PolarisTheme.MINUS] only
	# because that read well against the default palette, and a light source is
	# scenery rather than something the player can change.
	var lit: Color = PolarisTheme.world().glow
	var glow := Rect2(arena.position.x, arena.end.y - 180.0, arena.size.x, 180.0)
	_gradient(
		ci, glow,
		Color(lit, 0.0), Color(lit, 0.0), Color(lit, 0.07), Color(lit, 0.07)
	)


## The arena's own edges, drawn as built structure.
##
## [SimWorld] adds side walls to every level that the board never showed, so the
## ball bounced off nothing visible. This draws them — and leaves the bottom open,
## because there the simulation really has no floor: dropping out of the arena
## loses the run, and the warning band says so.
static func draw_frame(ci: CanvasItem, arena: Rect2) -> void:
	var t := 13.0
	draw_solid(ci, Rect2(arena.position.x - t, arena.position.y - t, t, arena.size.y + t * 2.0), PolarisTheme.world().wall_edge)
	draw_solid(ci, Rect2(arena.end.x, arena.position.y - t, t, arena.size.y + t * 2.0), PolarisTheme.world().wall_edge)
	draw_solid(ci, Rect2(arena.position.x - t, arena.position.y - t, arena.size.x + t * 2.0, t), PolarisTheme.world().wall_edge)

	# Below the arena there is nothing to land on. Warm the edge so the drop reads
	# as a hazard rather than as more empty room.
	var band := Rect2(arena.position.x, arena.end.y - 70.0, arena.size.x, 70.0)
	_gradient(
		ci, band,
		Color(PolarisTheme.PLUS, 0.0), Color(PolarisTheme.PLUS, 0.0),
		Color(PolarisTheme.PLUS, 0.16), Color(PolarisTheme.PLUS, 0.16)
	)
	var step := 26.0
	var x := arena.position.x
	while x < arena.end.x:
		ci.draw_line(
			Vector2(x, arena.end.y),
			Vector2(minf(x + 14.0, arena.end.x), arena.end.y - 14.0),
			Color(PolarisTheme.PLUS, 0.22), 3.0
		)
		x += step


# --- Gravity zones ----------------------------------------------------------

## Vertical spacing of the chevron rows drifting through a zone.
## Row pitch of the flow. Deliberately airy: at a 40-tick beat every chevron
## reverses 1.5 times a second, so a dense field means a hundred triangles turning
## at once, which reads as a glitch however smooth each one is.
const ZONE_ROW := 44.0

## How far the flow travels across one half cycle, in pixels.
const ZONE_SWING := 58.0


## A region where gravity flips on a beat.
##
## Three jobs, in order of importance:
##  1. **Which way is down right now.** Chevrons point that way and the whole zone
##     takes the matching hue.
##  2. **When does it flip.** [param progress] runs 0 to 1 through the current half
##     cycle and drives a bar down the zone's edge plus a quickening of the drift.
##     Without it the board would be guesswork, which is the difference between a
##     hard level and an unfair one.
##  3. **It just flipped.** A bright ring snaps outward for the first few percent
##     of a cycle, so the change is felt and not merely inferred.
## A region where gravity flips on a beat.
##
## The hard part here is not showing the direction, it is showing it **without
## strobing**. The beat is 40 ticks — the whole zone changes state 1.5 times a
## second — and the first two versions let the entire rectangle swap colour on
## every flip, fired a flash ring each time, and drove the drift from a value that
## reset every phase. A large area doing that reads as broken, not as rhythmic.
##
## So the body stays one steady colour and never flashes. Direction is carried by
## the small things: which way the chevrons point, which edge is lit, and which way
## the flow runs. Those change at the beat; the field does not.
##
## The flow's offset comes from [method zone_offset], which is continuous across
## the flip — see the note there for why that took three attempts.
static func draw_gravity_zone(
	ci: CanvasItem, r: Rect2, up: bool, progress: float
) -> void:
	var pull: float = -1.0 if up else 1.0
	var body := PolarisTheme.ZONE_BODY
	var accent: Color = PolarisTheme.ZONE_UP if up else PolarisTheme.ZONE_DOWN

	# One steady body. No per-phase colour swap: that was the strobe.
	_gradient(
		ci, r,
		Color(body, 0.16), Color(body, 0.16),
		Color(body, 0.09), Color(body, 0.09)
	)

	var drift := zone_offset(up, progress)
	var rows := int(r.size.y / ZONE_ROW) + 3
	for i in rows:
		var row := i - 1
		var y: float = r.position.y + float(row) * ZONE_ROW + drift
		if y < r.position.y or y > r.end.y:
			continue
		var fade := 1.0
		if y < r.position.y + 34.0:
			fade = clampf((y - r.position.y) / 34.0, 0.0, 1.0)
		elif y > r.end.y - 34.0:
			fade = clampf((r.end.y - y) / 34.0, 0.0, 1.0)
		if fade <= 0.0:
			continue
		var weight := 0.55 if posmod(row, 2) == 0 else 0.30
		var step := 54.0
		var x := r.position.x + 20.0 + (0.0 if posmod(row, 2) == 0 else 27.0)
		while x < r.end.x - 8.0:
			_chevron(ci, Vector2(x, y), pull, Color(accent, weight * fade))
			x += step

	# The lit edge: the side the pull leads to. Small, so moving it is a cue and
	# not a flash.
	var band := 7.0
	if up:
		ci.draw_rect(Rect2(r.position, Vector2(r.size.x, band)), Color(accent, 0.75), true)
	else:
		ci.draw_rect(Rect2(r.position.x, r.end.y - band, r.size.x, band), Color(accent, 0.75), true)
	ci.draw_rect(r, Color(body, 0.40), false, 2.0)

	# The countdown, on a thin rail beside the zone. This is the only element that
	# announces the flip, and it is small enough to do so without shouting.
	var rail := Rect2(r.position.x - 7.0, r.position.y, 4.0, r.size.y)
	ci.draw_rect(rail, Color(body, 0.25), true)
	var run := r.size.y * progress
	var from_top: bool = not up
	var filled := (
		Rect2(rail.position, Vector2(rail.size.x, run)) if from_top
		else Rect2(rail.position.x, rail.end.y - run, rail.size.x, run)
	)
	ci.draw_rect(filled, Color(accent, 0.9), true)


## Where the flow sits within its cycle, in pixels, signed.
##
## This is the piece that kept looking broken, and the reason is worth stating
## plainly. The obvious construction — a positive drift multiplied by the
## direction's sign — **teleports**: when the sign flips, the offset jumps from
## `-drift` straight to `+drift`, so every chevron moves twice the drift in a
## single frame. Measured on the old code that was a 62px jump, 1.5 times a second.
## Two attempts at fixing this changed how the drift was computed and left the sign
## multiplication in place, so neither helped.
##
## What works is treating the offset as the *integral* of a signed velocity. A
## raised cosine does it in closed form: zero at the start of the cycle, full swing
## at the flip, back to zero at the end — and its slope is zero exactly where the
## direction reverses, so the flow eases to a stop, turns, and eases away. Measured
## per-tick movement drops from 62px to about 2px.
##
## `test_the_zone_flow_never_jumps` pins this.
static func zone_offset(up: bool, progress: float) -> float:
	# Position within the full two-phase cycle, 0 to 1.
	var cycle: float = progress * 0.5 if up else 0.5 + progress * 0.5
	return -ZONE_SWING * 0.5 * (1.0 - cos(TAU * cycle))


## One arrowhead pointing the way gravity currently pulls.
static func _chevron(ci: CanvasItem, at: Vector2, pull: float, tone: Color) -> void:
	var w := 7.0
	var h := 6.0 * pull
	ci.draw_colored_polygon(
		PackedVector2Array([
			at + Vector2(0.0, h),
			at + Vector2(-w, -h * 0.4),
			at + Vector2(w, -h * 0.4),
		]),
		tone
	)


# --- Solids -----------------------------------------------------------------

## Pitch of the teeth in a hazard band, and how far a tooth stands proud of its
## base. Small enough that a 60px strip still reads as a row rather than as two
## big triangles.
const SPIKE_PITCH := 22.0


## A band that ends the run on contact.
##
## **The whole rectangle kills, so the whole rectangle has to look like it.** Teeth
## alone would promise safety in the gaps between them — the ball dies there too —
## so the band carries a warm wash across its full area and the teeth sit on top as
## the icon that says *what kind* of danger this is.
##
## Teeth rise from the band's long edge: up from the bottom on a wide strip, in from
## the left on a tall one. A hazard is almost always a floor or a wall, and this
## picks the right one without the level having to say.
##
## Red, because red already means "this ends your run" on every board — it is the
## colour of the warning band under the open bottom edge. The teeth themselves stay
## steel so they read as objects rather than as more wash.
static func draw_hazard(ci: CanvasItem, r: Rect2, t: float) -> void:
	var wide := r.size.x >= r.size.y
	ci.draw_rect(r, Color(PolarisTheme.PLUS, 0.13), true)
	ci.draw_rect(r, Color(PolarisTheme.PLUS, 0.4), false, 1.5)

	# The plate the teeth stand on, along the edge they grow from.
	var base := 5.0
	var plate := (
		Rect2(r.position.x, r.end.y - base, r.size.x, base) if wide
		else Rect2(r.position.x, r.position.y, base, r.size.y)
	)
	ci.draw_rect(plate, Color(PolarisTheme.WALL_EDGE, 0.9), true)

	var span := r.size.x if wide else r.size.y
	var reach := (r.size.y - base) if wide else (r.size.x - base)
	if reach <= 1.0 or span <= 1.0:
		return
	var count := maxi(1, int(span / SPIKE_PITCH))
	var pitch := span / float(count)

	for i in count:
		var low := (r.position.x if wide else r.position.y) + float(i) * pitch
		var mid := low + pitch * 0.5
		var tip: Vector2
		var left: Vector2
		var right: Vector2
		if wide:
			tip = Vector2(mid, r.position.y)
			left = Vector2(low, r.end.y - base)
			right = Vector2(low + pitch, r.end.y - base)
		else:
			tip = Vector2(r.end.x, mid)
			left = Vector2(r.position.x + base, low)
			right = Vector2(r.position.x + base, low + pitch)
		ci.draw_colored_polygon(
			PackedVector2Array([tip, left, right]), Color(PolarisTheme.WALL_EDGE, 0.95)
		)
		# A lit edge on one side of every tooth, so a row of them reads as points and
		# not as a zigzag ribbon.
		ci.draw_line(left, tip, Color(PolarisTheme.INK_DIM, 0.55), 1.5)

		# One tooth at a time catches the light, travelling along the row. It is the
		# only moving thing on a hazard, which is what makes the band read as active
		# rather than as scenery.
		var phase := fmod(t * 0.55 + float(i) / float(count), 1.0)
		if phase < 0.12:
			var glint := 1.0 - phase / 0.12
			ci.draw_circle(tip, 2.5 + 2.0 * glint, Color(PolarisTheme.PLUS_LIGHT, glint))


## A plate that throws the ball, drawn as a coil that fires along [param push].
##
## **Blue, and that is not a free choice.** The player learned in Level 1 that blue
## pushes — it is the repel magnet's colour — so a blue plate says what it does
## before anything explains it. That the plate is *not* a magnet is carried by the
## shape instead: a magnet is a disc with a field flowing in or out of it, this is a
## flat coil with a barrel and a direction. Red and amber and mint were unavailable
## anyway; they already mean pull, goal and checkpoint.
##
## Drawn in the plate's own frame — [param push] gives the axis — so a plate turned
## on its side needs no second code path. Its rings stack along the barrel and its
## chevrons point out of the mouth.
static func draw_spring(ci: CanvasItem, r: Rect2, push: Vector2, t: float) -> void:
	var reach := sqrt(push.x * push.x + push.y * push.y)
	if reach <= 0.0:
		return
	# Out of the mouth, and across it.
	var out := Vector2(push.x / reach, push.y / reach)
	var side := Vector2(-out.y, out.x)
	var centre := r.get_center()
	# How far the plate reaches along each of its own axes.
	var depth := absf(r.size.x * out.x) + absf(r.size.y * out.y)
	var width := absf(r.size.x * side.x) + absf(r.size.y * side.y)
	if depth <= 8.0 or width <= 8.0:
		return
	var back := centre - out * depth * 0.5

	ci.draw_rect(r, Color(PolarisTheme.MINUS, 0.1), true)

	# The anvil: the thing the ball is thrown off. Bright, because it is the part
	# that has to read as solid — the rest is light.
	var plate := 4.0
	ci.draw_colored_polygon(
		PackedVector2Array([
			back + side * width * 0.5,
			back - side * width * 0.5,
			back - side * width * 0.5 + out * plate,
			back + side * width * 0.5 + out * plate,
		]),
		Color(PolarisTheme.INK_DIM, 0.9)
	)

	# Chevrons filling the barrel, each in its own slot so none can spill out of the
	# mouth, and lit in turn from the anvil outwards.
	#
	# An earlier version drew coil windings *across* the barrel as well. At the
	# depth a springboard actually has — twenty to forty pixels — three lines across
	# it are stripes, not windings, and with chevrons on top of them the whole plate
	# read as scribble. Two shapes were one too many.
	# How many chevrons fit depends on the depth, and a thin plate gets *one*. Two
	# in a thirty-pixel barrel are thirteen pixels tall each, which is not an arrow,
	# it is a dash — and a springboard is usually thin.
	var count := 1 if depth < 34.0 else (2 if depth < 64.0 else 3)
	var slot := (depth - plate) / float(count)
	var pulse := fmod(t * 1.6, 1.0)
	# Held to the slot as well as to the width: a chevron wider than it is deep
	# points sideways however carefully it was aimed.
	var half := minf(width * 0.36, slot * 1.5)
	for i in count:
		var low := plate + float(i) * slot
		var foot := back + out * (low + slot * 0.12)
		var tip := back + out * (low + slot * 0.92)
		var lit: float = maxf(0.0, 1.0 - absf(pulse - (float(i) + 0.5) / float(count)) * 3.2)
		var tone: Color = Color(PolarisTheme.MINUS_LIGHT, 0.4 + 0.6 * lit)
		var thick := 2.0 + 1.5 * lit
		ci.draw_line(foot - side * half, tip, tone, thick)
		ci.draw_line(foot + side * half, tip, tone, thick)

	ci.draw_rect(r, Color(PolarisTheme.MINUS, 0.45), false, 1.5)


## How long the ball takes to come apart, in seconds of wall clock.
const BOOM_SECONDS := 0.8


## The ball coming apart, [param progress] running 0 to 1.
##
## Wall clock, not ticks, and that is the point: the run is already over when this
## plays, so it can afford everything the simulation may not have — `sin`, `cos`,
## a clock. Nothing here is ever read back.
##
## Fragment directions come from [method _hash] of the fragment's index, not from
## [method @GlobalScope.randf]. A value drawn per frame would make the pieces
## scatter anew sixty times a second instead of flying.
static func draw_explosion(ci: CanvasItem, at: Vector2, progress: float) -> void:
	var p := clampf(progress, 0.0, 1.0)
	var fade := 1.0 - p
	var out := 1.0 - (1.0 - p) * (1.0 - p)

	# Two rings at different speeds. The slow one is the wave, the fast one is the
	# punch — one alone reads as a ripple, which is a thing spreading rather than a
	# thing breaking.
	ci.draw_arc(
		at, 14.0 + 230.0 * out, 0.0, TAU, 56,
		Color(PolarisTheme.PLUS, 0.5 * fade * fade), 1.0 + 3.0 * fade
	)
	if p < 0.45:
		var q := p / 0.45
		ci.draw_arc(
			at, 10.0 + 96.0 * q, 0.0, TAU, 40,
			Color(PolarisTheme.PLUS_LIGHT, 0.55 * (1.0 - q)), 2.0 + 4.0 * (1.0 - q)
		)

	# The flash: bright, and gone in a seventh of a second.
	#
	# It was three times as long at first, and that is not a flash — white at low
	# alpha over a dark board is grey, so what it actually drew was a dull disc
	# lying where the ball used to be. Short and bright, or not at all.
	if p < 0.14:
		var f := 1.0 - p / 0.14
		ci.draw_circle(at, 8.0 + 46.0 * f * f, Color(1.0, 1.0, 1.0, 0.95 * f))

	# The pieces, each with a short tail behind it. Without the tail they are dots
	# that happen to be somewhere; with it they are moving.
	for i in 18:
		var h := _hash(i * 7919 + 13)
		var angle := float(h % 3600) * 0.0017453293
		var speed := 130.0 + float(h % 150)
		var size := (2.0 + float(h % 4)) * (0.35 + 0.65 * fade)
		var tone: Color = PolarisTheme.BALL if h % 3 else PolarisTheme.PLUS_LIGHT
		var here := _shard(at, angle, speed, p)
		var was := _shard(at, angle, speed, maxf(0.0, p - 0.07))
		ci.draw_line(was, here, Color(tone, 0.45 * fade), size * 0.8)
		ci.draw_circle(here, size, Color(tone, fade))


## Where one fragment is at [param p].
##
## Eased outward so it leaves fast and slows, plus a droop that grows with the
## square of time — the difference between debris and a firework.
static func _shard(at: Vector2, angle: float, speed: float, p: float) -> Vector2:
	var ease := 1.0 - (1.0 - p) * (1.0 - p)
	return at + Vector2(cos(angle), sin(angle)) * speed * ease + Vector2(0.0, 420.0 * p * p)


## A wall or platform, built up rather than filled flat.
##
## Order matters: shadow, body, brick seams, lit cap, dark underside, outline. The
## cap is what makes a platform read as something the ball lands *on* instead of a
## rectangle it happens to stop inside.
static func draw_solid(ci: CanvasItem, r: Rect2, edge_tint: Color) -> void:
	ci.draw_rect(Rect2(r.position + Vector2(0, 5), r.size), Color(0, 0, 0, 0.35), true)

	var face_top: Color = PolarisTheme.world().face_top
	var face_low: Color = PolarisTheme.world().face_bottom
	_gradient(ci, r, face_top, face_top, face_low, face_low)
	_bricks(ci, r)

	var cap := minf(7.0, r.size.y * 0.34)
	ci.draw_rect(Rect2(r.position, Vector2(r.size.x, cap)), edge_tint.darkened(0.15), true)
	ci.draw_rect(Rect2(r.position, Vector2(r.size.x, 2.0)), edge_tint.lightened(0.55), true)
	ci.draw_rect(
		Rect2(r.position.x, r.end.y - 3.0, r.size.x, 3.0),
		Color(0, 0, 0, 0.45),
		true
	)
	ci.draw_rect(r, Color(0, 0, 0, 0.7), false, 2.0)


## A wall of any shape, built up the way [method draw_solid] builds a box.
##
## Shadow, body, courses, lit cap, dark underside, outline — same order, same
## reasons. What changes is where the cap goes. A box has one top edge; a polygon
## has as many as it has edges that face upward, and every one of them is somewhere
## the ball can land. So each edge takes its light from the way it faces: full on a
## floor, fading as it tilts into a slope, none on a wall, and the underside's
## shade on anything that faces down.
##
## The facing comes from the edge itself — `(ey, -ex)` over its length, turned by
## [method SimWorld.winding] — so no angle is ever computed, and the side that gets
## lit is by construction the side the simulation pushes the ball out of.
static func draw_polygon_wall(
	ci: CanvasItem, points: PackedVector2Array, edge_tint: Color
) -> void:
	if points.size() < 3:
		return
	# An outline that crosses itself cannot be filled: the triangulation gives up and
	# says so, every frame, for as long as it is on screen. That only ever happens in
	# the build mode, halfway through dragging a corner somewhere it is about to be
	# refused — measured at 412 errors in one drag. The outline is all there is to
	# draw then. [method Geometry2D.triangulate_polygon] fails silently where
	# [method CanvasItem.draw_polygon] complains, so asking it first costs nothing
	# but the triangulation `draw_polygon` would have done anyway.
	if Geometry2D.triangulate_polygon(points).is_empty():
		var ring := points.duplicate()
		ring.append(points[0])
		ci.draw_polyline(ring, Color(0, 0, 0, 0.7), 2.0)
		return
	var shadow := PackedVector2Array()
	for point: Vector2 in points:
		shadow.append(point + Vector2(0, 5))
	ci.draw_colored_polygon(shadow, Color(0, 0, 0, 0.35))

	# The same top-to-bottom shading a box gets, per corner, so a tall polygon darkens
	# toward its foot exactly as a tall box does.
	var bounds := SimLevel.polygon_bounds(points)
	var face_top: Color = PolarisTheme.world().face_top
	var face_low: Color = PolarisTheme.world().face_bottom
	var shades := PackedColorArray()
	for point: Vector2 in points:
		var depth := 0.0 if bounds.size.y <= 0.0 else (point.y - bounds.position.y) / bounds.size.y
		shades.append(face_top.lerp(face_low, depth))
	ci.draw_polygon(points, shades)

	# Courses: the brick seams of a box, as horizontal lines cut to the outline. Only
	# the horizontals — the upright joints would each need their own clipping, and at
	# this depth the courses alone read as masonry.
	var row := bounds.position.y + TILE
	while row < bounds.end.y:
		var seam := PackedVector2Array([
			Vector2(bounds.position.x - 1.0, row), Vector2(bounds.end.x + 1.0, row)
		])
		for piece: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(seam, points):
			ci.draw_polyline(piece, Color(0, 0, 0, 0.22), 1.0)
		row += TILE

	var turn := 1.0 if SimWorld.winding(points) > 0.0 else -1.0
	var last := points.size() - 1
	for i in points.size():
		var a := points[last]
		var b := points[i]
		last = i
		var edge := b - a
		var length := edge.length()
		if length <= 0.0:
			continue
		var outward := Vector2(edge.y, -edge.x) / length * turn
		var inward := -outward
		if outward.y < -0.2:
			var lift := -outward.y
			ci.draw_line(
				a + inward * 3.5, b + inward * 3.5,
				Color(edge_tint.darkened(0.15), lift), 7.0
			)
			ci.draw_line(a + inward, b + inward, Color(edge_tint.lightened(0.55), lift), 2.0)
		elif outward.y > 0.2:
			ci.draw_line(
				a + inward * 1.5, b + inward * 1.5, Color(0, 0, 0, 0.45 * outward.y), 3.0
			)

	var ring := points.duplicate()
	ring.append(points[0])
	ci.draw_polyline(ring, Color(0, 0, 0, 0.7), 2.0)


## Seams inside a block, clipped to it. Each tile gets a fixed shade from its own
## coordinates, so the pattern is stable frame to frame.
static func _bricks(ci: CanvasItem, r: Rect2) -> void:
	var rows := int(r.size.y / TILE) + 1
	var cols := int(r.size.x / TILE) + 2
	for row in rows:
		var y := r.position.y + row * TILE
		if y > r.end.y:
			break
		var offset := 0.0 if row % 2 == 0 else TILE * 0.5
		for col in cols:
			var x := r.position.x + col * TILE - offset
			var w := minf(TILE, r.end.x - x)
			var h := minf(TILE, r.end.y - y)
			if w <= 1.0 or h <= 1.0 or x >= r.end.x:
				continue
			if x < r.position.x:
				w -= r.position.x - x
				x = r.position.x
			if w <= 1.0:
				continue
			var h2 := _hash(int(x) * 7 + int(y) * 13)
			ci.draw_rect(
				Rect2(x, y, w, h),
				Color(1, 1, 1, 0.018 + float(h2 % 5) * 0.012),
				true
			)
			ci.draw_rect(Rect2(x, y, w, h), Color(0, 0, 0, 0.22), false, 1.0)


# --- Target -----------------------------------------------------------------

## The goal: a lit recess with a pulsing rim and corner brackets.
##
## [param t] is wall-clock seconds and drives the pulse. It reaches only this
## file — the simulation never sees a clock.
static func draw_target(ci: CanvasItem, r: Rect2, t: float) -> void:
	var pulse := 0.5 + 0.5 * sin(t * 2.4)

	for i in 3:
		var grow := 6.0 + i * 7.0
		ci.draw_rect(r.grow(grow), Color(PolarisTheme.TARGET, 0.05 - i * 0.014), true)

	_gradient(
		ci, r,
		Color(PolarisTheme.TARGET, 0.05), Color(PolarisTheme.TARGET, 0.05),
		Color(PolarisTheme.TARGET, 0.20), Color(PolarisTheme.TARGET, 0.20)
	)

	# Diagonal hatching, so the goal has a surface instead of being a hole.
	var span := r.size.x + r.size.y
	var step := 22.0
	var i := 0.0
	while i < span:
		var a := Vector2(r.position.x + i, r.position.y)
		var b := Vector2(r.position.x + i - r.size.y, r.end.y)
		a.x = clampf(a.x, r.position.x, r.end.x)
		b.x = clampf(b.x, r.position.x, r.end.x)
		ci.draw_line(a, b, Color(PolarisTheme.TARGET, 0.06), 2.0)
		i += step

	ci.draw_rect(r, Color(PolarisTheme.TARGET, 0.55 + 0.35 * pulse), false, 2.0)

	var arm := minf(26.0, minf(r.size.x, r.size.y) * 0.4)
	var lit := Color(PolarisTheme.TARGET, 0.9)
	for corner in 4:
		var cx: float = r.position.x if corner % 2 == 0 else r.end.x
		var cy: float = r.position.y if corner < 2 else r.end.y
		var sx: float = 1.0 if corner % 2 == 0 else -1.0
		var sy: float = 1.0 if corner < 2 else -1.0
		ci.draw_line(Vector2(cx, cy), Vector2(cx + arm * sx, cy), lit, 3.0)
		ci.draw_line(Vector2(cx, cy), Vector2(cx, cy + arm * sy), lit, 3.0)


## A checkpoint gate: two posts, a soft band between them, and a pennant that
## rises once the ball has passed through.
##
## Drawn as a *gate* rather than a marked patch of floor because that is what it
## is — a line across the path, not a place to stand. The pennant is the state:
## drooping means "not yet", flying means "this is where R puts you back".
##
## [param view_scale] is how far the camera has pulled back. Strokes are divided by
## it so they keep their width *on screen*: a gate is a small thing on a 2200px
## board, and at the planning zoom a 3px post would come out at barely one pixel —
## invisible exactly when the player is deciding where to aim.
static func draw_checkpoint(
	ci: CanvasItem, r: Rect2, reached: bool, t: float, view_scale: float = 1.0
) -> void:
	# One colour for both states. Mint *means* checkpoint here; what separates
	# reached from pending is brightness and the pennant, not hue — a grey gate
	# read as scenery, and the one that mattered most was the one not yet reached.
	var tone: Color = PolarisTheme.OK
	var lit := 1.0 if reached else 0.55
	# Capped, so pulling back on a huge board thickens the gate rather than turning
	# it into a blob.
	var pen := clampf(1.0 / maxf(view_scale, 0.05), 1.0, 3.0)

	_gradient(
		ci, r,
		Color(tone, 0.02 * lit), Color(tone, 0.02 * lit),
		Color(tone, 0.16 * lit), Color(tone, 0.16 * lit)
	)

	# Rungs across the gap, so a tall gate reads as a curtain to pass through
	# rather than two unrelated posts.
	var y := r.position.y + 12.0
	while y < r.end.y:
		ci.draw_line(
			Vector2(r.position.x + 3.0, y), Vector2(r.end.x - 3.0, y),
			Color(tone, 0.16 * lit), 1.0
		)
		y += 16.0

	# One doorway, not two poles.
	#
	# Drawn as two equal posts it read as *two checkpoints* standing next to each
	# other — reported from play, on a gate 40px wide. A frame fixes it: the near
	# edge is the gate, the far edge is thin, and a lintel and sill tie them
	# together into a single thing you pass through.
	var near := r.position.x
	var far := r.end.x
	ci.draw_line(
		Vector2(near, r.position.y), Vector2(near, r.end.y), Color(tone, 0.8 * lit), 3.5 * pen
	)
	ci.draw_line(
		Vector2(far, r.position.y), Vector2(far, r.end.y), Color(tone, 0.28 * lit), 1.5 * pen
	)
	for edge: float in [r.position.y, r.end.y]:
		ci.draw_line(Vector2(near, edge), Vector2(far, edge), Color(tone, 0.7 * lit), 2.5 * pen)
	ci.draw_circle(Vector2(near, r.position.y), 4.5 * pen, Color(tone, 0.95 * lit))
	ci.draw_circle(Vector2(near, r.end.y), 4.5 * pen, Color(tone, 0.95 * lit))

	# The pennant. Reached, it flies and ripples; pending, it hangs.
	var post := Vector2(r.position.x, r.position.y)
	var wave: float = sin(t * 3.2) * 5.0 if reached else 0.0
	var flag := (
		Vector2(30.0, 8.0 + wave) if reached else Vector2(7.0, 26.0)
	) * pen
	var mid := post + (
		Vector2(16.0, 20.0 - wave * 0.5) if reached else Vector2(3.0, 20.0)
	) * pen
	var tip := post + flag
	ci.draw_colored_polygon(
		PackedVector2Array([post, tip, mid]), Color(tone, 0.85 * lit)
	)

	if reached:
		# A halo, so the checkpoint you would restart from is findable at a glance on
		# a board too large to take in at once.
		for i in 3:
			ci.draw_rect(
				r.grow((4.0 + i * 6.0) * pen),
				Color(PolarisTheme.OK, 0.06 - i * 0.018), false, 2.0 * pen
			)


## The window a checkpoint opens: where the magnet would land, and how long the
## board will stay slow.
##
## The ghost is drawn at the cursor with **both** rings, reach and lift, because
## this is the one moment the player has no time to think about the difference —
## the same reason the planning view draws them (see criterion 8).
static func draw_placement_window(
	ci: CanvasItem, ball: Vector2, cursor: Vector2, attract: bool,
	left: float, reach: float, lift: float, t: float, held: bool = false
) -> void:
	var tone: Color = PolarisTheme.PLUS if attract else PolarisTheme.MINUS

	# The ghost magnet.
	ci.draw_circle(cursor, 26.0, Color(tone, 0.16))
	ci.draw_arc(cursor, 26.0, 0.0, TAU, 40, Color(tone, 0.85), 2.0)
	_dashed_ring(ci, cursor, lift, Color(tone, 0.7), t * 0.6)
	# Faint on purpose: at 1:1 the reach ring is 400px across and would otherwise
	# read as stray arcs cutting through the board. The lift ring is the one that
	# decides whether the ball can be picked up at all.
	_dashed_ring(ci, cursor, reach, Color(tone, 0.10), -t * 0.35)

	# A line to the ball, so the distance that decides everything is a thing you
	# can see rather than estimate.
	var away := ball - cursor
	var span := away.length()
	if span > 1.0:
		var toward := away / span
		ci.draw_line(
			cursor + toward * 26.0, ball - toward * 18.0,
			Color(tone, 0.30 if span > lift else 0.7), 1.0
		)

	# How much of the window is left, drawn on the ball because that is where the
	# eye already is.
	ci.draw_arc(
		ball, 34.0, -PI / 2.0, -PI / 2.0 + TAU * left, 40,
		Color(PolarisTheme.ACCENT, 0.9), 3.0
	)
	ci.draw_arc(ball, 34.0, 0.0, TAU, 40, Color(PolarisTheme.ACCENT, 0.15), 3.0)
	if held:
		# Two bars, the universal "paused" — the board is not lagging, it is waiting.
		var pulse := 0.55 + 0.45 * sin(t * 4.0)
		for side in 2:
			var bx: float = ball.x - 5.0 + float(side) * 10.0
			ci.draw_line(
				Vector2(bx, ball.y - 48.0), Vector2(bx, ball.y - 60.0),
				Color(PolarisTheme.ACCENT, pulse), 3.0
			)


static func _dashed_ring(
	ci: CanvasItem, at: Vector2, radius: float, tone: Color, spin: float
) -> void:
	var steps := 44
	for i in steps:
		if i % 2 == 1:
			continue
		var a := TAU * float(i) / float(steps) + spin
		var b := TAU * float(i + 1) / float(steps) + spin
		ci.draw_line(
			at + Vector2(cos(a), sin(a)) * radius,
			at + Vector2(cos(b), sin(b)) * radius,
			tone, 1.5
		)


## Says, on the board itself, that time is not running normally.
##
## Drawn in *screen* space over the whole view, not in the world: a state of the
## clock belongs to the frame around the game, the way a pause overlay does, and
## anything painted into the world would be mistaken for a thing on the board.
##
## A word in the panel is not enough — the eye is on the ball, and the panel is
## 900px away from it. So the view gets a border that could not be there for any
## other reason, and a bar that drains so the state has a visible *end*.
##
## The two states read differently on purpose: [param held] is a steady frame with
## corner brackets and a full bar (nothing is running, nothing is running out),
## while slowed time breathes and drains.
static func draw_time_state(
	ci: CanvasItem, view: Rect2, left: float, held: bool, t: float
) -> void:
	var tone: Color = PolarisTheme.ACCENT
	var pulse := 1.0 if held else 0.75 + 0.25 * sin(t * 3.0)
	var depth := 54.0
	var edge := Color(tone, 0.17 * pulse)
	var none := Color(tone, 0.0)

	_gradient(ci, Rect2(view.position, Vector2(view.size.x, depth)), edge, edge, none, none)
	_gradient(
		ci, Rect2(view.position.x, view.end.y - depth, view.size.x, depth),
		none, none, edge, edge
	)
	# The corners go clockwise from the top left, so a band that fades sideways
	# needs its two lit corners on the same *edge*, not on the same diagonal.
	_gradient(ci, Rect2(view.position, Vector2(depth, view.size.y)), edge, none, none, edge)
	_gradient(
		ci, Rect2(view.end.x - depth, view.position.y, depth, view.size.y),
		none, edge, edge, none
	)

	# A hairline all the way round, so the border is a decision and not a smudge.
	ci.draw_rect(view, Color(tone, 0.5 * pulse), false, 2.0)

	# How much of the state is left. Full and still while the board is held.
	var bar := view.size.x * clampf(left, 0.0, 1.0)
	ci.draw_rect(Rect2(view.position.x, view.position.y, bar, 4.0), Color(tone, 0.9), true)

	if not held:
		return
	# Brackets, the visual grammar of "stopped".
	var arm := 34.0
	for corner in 4:
		var cx: float = view.position.x if corner % 2 == 0 else view.end.x
		var cy: float = view.position.y if corner < 2 else view.end.y
		var sx: float = 1.0 if corner % 2 == 0 else -1.0
		var sy: float = 1.0 if corner < 2 else -1.0
		ci.draw_line(Vector2(cx, cy), Vector2(cx + arm * sx, cy), Color(tone, 0.95), 4.0)
		ci.draw_line(Vector2(cx, cy), Vector2(cx, cy + arm * sy), Color(tone, 0.95), 4.0)


# --- Magnets ----------------------------------------------------------------

## How many field rings travel through a magnet's reach at once.
const FIELD_RINGS := 3

## Motes riding the field. Their angles come from a hash so they keep their places
## instead of scattering anew every frame.
const FIELD_MOTES := 14


## A magnet, with a field that shows which way it pulls.
##
## Colour alone said *what* a magnet is but not *what it does*: red and blue are
## a convention the player has to be taught. Rings and motes travelling **inward**
## for attract and **outward** for repel say it without a legend, and they follow
## the acting polarity, so holding Shift visibly reverses the flow.
##
## [param attract] is the polarity acting right now, already inverted if the
## reverse key is down — not the one the magnet was placed with.
static func draw_magnet(
	ci: CanvasItem, pos: Vector2, attract: bool, held: bool, spent: bool,
	t: float, reach: float, lift: float
) -> void:
	var tint: Color = PolarisTheme.PLUS if attract else PolarisTheme.MINUS
	if spent:
		tint = tint.darkened(0.45)

	ci.draw_arc(pos, reach, 0.0, TAU, 64, Color(tint, 0.11 if held else 0.05), 2.0)
	# The inner ring is where the field beats gravity. Without it the outer circle
	# reads as "this is what I can do", and a magnet meant to lift fails silently.
	ci.draw_arc(pos, lift, 0.0, TAU, 48, Color(tint, 0.24 if held else 0.13), 1.0)

	if not spent:
		_field_flow(ci, pos, attract, held, t, reach)
	_magnet_body(ci, pos, tint, attract, held, t)


## Rings and motes sweeping through the field, inward or outward.
##
## One phase drives both, so a ring and the motes on it always agree. Reversing
## polarity just runs the phase backwards.
static func _field_flow(
	ci: CanvasItem, pos: Vector2, attract: bool, held: bool, t: float, reach: float
) -> void:
	var speed := 0.42 if held else 0.16
	var strength := 1.0 if held else 0.32
	var tint: Color = PolarisTheme.PLUS if attract else PolarisTheme.MINUS

	for ring in FIELD_RINGS:
		var phase := fmod(t * speed + float(ring) / float(FIELD_RINGS), 1.0)
		# Attract sweeps from the rim to the core, repel the other way.
		var travel: float = 1.0 - phase if attract else phase
		var radius: float = 26.0 + travel * (reach - 26.0)
		# Faint at both ends so rings appear and vanish instead of popping.
		var fade: float = sin(phase * PI)
		ci.draw_arc(pos, radius, 0.0, TAU, 48, Color(tint, 0.12 * fade * strength), 1.5)

		for mote in FIELD_MOTES:
			var h := _hash(mote * 89 + ring * 613)
			var angle := float(h % 3600) / 3600.0 * TAU
			var out := Vector2(cos(angle), sin(angle))
			var at := pos + out * radius
			# A short streak along the direction of travel, not a dot: it shows the
			# way the field is going even in a single frame.
			var tail := at + out * (7.0 if attract else -7.0)
			ci.draw_line(at, tail, Color(tint, 0.75 * fade * strength), 2.5)
			ci.draw_circle(at, 2.2 + 1.6 * fade, Color(tint, 0.9 * fade * strength))


## The magnet itself: a lit core with chevrons that point the way the field goes.
static func _magnet_body(
	ci: CanvasItem, pos: Vector2, tint: Color, attract: bool, held: bool, t: float
) -> void:
	var r := 22.0
	if held:
		# A slow breath while active, so an activated magnet is obvious in motion
		# even when the field itself is off screen.
		r += 2.5 * sin(t * 9.0)
		ci.draw_circle(pos, r + 12.0, Color(tint, 0.16))
		ci.draw_circle(pos, r + 6.0, Color(tint, 0.22))

	ci.draw_circle(pos + Vector2(0, 3), r, Color(0, 0, 0, 0.45))
	ci.draw_circle(pos, r, tint.darkened(0.3))
	ci.draw_circle(pos - Vector2(r * 0.16, r * 0.2), r * 0.82, tint)
	ci.draw_circle(pos - Vector2(r * 0.3, r * 0.34), r * 0.3, Color(1, 1, 1, 0.35))
	ci.draw_arc(pos, r, 0.0, TAU, 32, Color(0, 0, 0, 0.55), 2.0, true)

	# Four chevrons on the rim. Pointing in means "comes to me", out means "goes
	# away" — the one piece of the picture that survives being colour blind.
	var ink := Color(1, 1, 1, 0.9 if held else 0.6)
	for i in 4:
		var angle := float(i) * TAU / 4.0 + PI / 4.0
		var dir := Vector2(cos(angle), sin(angle))
		var side := Vector2(-dir.y, dir.x)
		var base: float = r + 13.0 if attract else r + 4.0
		var tip: float = r + 3.0 if attract else r + 14.0
		ci.draw_colored_polygon(
			PackedVector2Array([
				pos + dir * tip,
				pos + dir * base + side * 5.5,
				pos + dir * base - side * 5.5,
			]),
			ink
		)


## The link between an active magnet and the ball it is working on.
##
## Drawn only while the field actually reaches the ball, so it doubles as the
## answer to "why is nothing happening?" — no beam means out of range.
static func draw_pull(
	ci: CanvasItem, magnet: Vector2, ball: Vector2, attract: bool, t: float
) -> void:
	var tint: Color = PolarisTheme.PLUS if attract else PolarisTheme.MINUS
	var span := ball - magnet
	var distance := span.length()
	if distance < 1.0:
		return
	var dir := span / distance

	ci.draw_line(magnet, ball, Color(tint, 0.24), 4.0)

	# Dashes running along the link, toward the magnet when it pulls.
	var gap := 26.0
	var drift := fmod(t * 190.0, gap)
	var travel: float = distance - drift if attract else drift
	while travel > 0.0 and travel < distance:
		var head := magnet + dir * travel
		var tail := head - dir * (9.0 if attract else -9.0)
		ci.draw_line(head, tail, Color(tint, 0.95), 3.5)
		travel += gap if not attract else -gap
		if attract and travel <= 0.0:
			break
		if not attract and travel >= distance:
			break


# --- Ball -------------------------------------------------------------------

## The ball, with the trail behind it.
##
## [param trail] is the recent positions, oldest first. It lives in the view layer
## and is rebuilt from the simulation's state each tick, never fed back into it.
static func draw_ball(ci: CanvasItem, pos: Vector2, radius: float, trail: Array) -> void:
	for i in trail.size():
		var f := float(i + 1) / float(trail.size() + 1)
		ci.draw_circle(trail[i], radius * (0.30 + 0.55 * f), Color(PolarisTheme.BALL, 0.05 + 0.10 * f))

	ci.draw_circle(pos + Vector2(0, 4), radius * 0.95, Color(0, 0, 0, 0.4))
	ci.draw_circle(pos, radius + 3.0, Color(PolarisTheme.BALL, 0.12))
	ci.draw_circle(pos, radius, PolarisTheme.BALL.darkened(0.15))
	# Lit from above-left, matching the cap highlights on the platforms.
	ci.draw_circle(pos - Vector2(radius * 0.22, radius * 0.26), radius * 0.72, PolarisTheme.BALL)
	ci.draw_circle(pos - Vector2(radius * 0.34, radius * 0.38), radius * 0.30, Color(1, 1, 1, 0.95))
	ci.draw_arc(pos, radius, 0.0, TAU, 28, Color(PolarisTheme.BALL_EDGE, 0.9), 2.0, true)


# --- Overlay ----------------------------------------------------------------

## Darkens the arena's edges. Last thing drawn over the board, before the panel.
static func draw_vignette(ci: CanvasItem, arena: Rect2) -> void:
	var depth := 130.0
	var clear := Color(0, 0, 0, 0.0)
	var dark := Color(0, 0, 0, 0.6)
	_gradient(
		ci, Rect2(arena.position, Vector2(arena.size.x, depth)),
		dark, dark, clear, clear
	)
	_gradient(
		ci, Rect2(arena.position.x, arena.end.y - depth, arena.size.x, depth),
		clear, clear, dark, dark
	)
	_gradient(
		ci, Rect2(arena.position, Vector2(depth, arena.size.y)),
		dark, clear, clear, dark
	)
	_gradient(
		ci, Rect2(arena.end.x - depth, arena.position.y, depth, arena.size.y),
		clear, dark, dark, clear
	)
	ci.draw_rect(arena, Color(PolarisTheme.world().wall_edge, 0.8), false, 3.0)


# --- Helpers ----------------------------------------------------------------

## A rectangle with a colour per corner. [method CanvasItem.draw_rect] takes one
## colour, so every gradient in this file goes through here.
static func _gradient(
	ci: CanvasItem, r: Rect2, tl: Color, tr: Color, br: Color, bl: Color
) -> void:
	ci.draw_polygon(
		PackedVector2Array([
			r.position,
			Vector2(r.end.x, r.position.y),
			r.end,
			Vector2(r.position.x, r.end.y),
		]),
		PackedColorArray([tl, tr, br, bl])
	)


## Cheap deterministic scramble. Only ever decides shades, never anything a run
## depends on, but it is stable so the board does not shimmer.
static func _hash(value: int) -> int:
	var h := value * 374761393 + 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return absi(h ^ (h >> 16))
