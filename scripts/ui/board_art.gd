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

## Face of a solid. Deliberately lighter and warmer than the background so the
## geometry you can stand on separates from the geometry you cannot.
const FACE_TOP := Color("46516e")
const FACE_BOTTOM := Color("222a41")

# --- Background -------------------------------------------------------------

## The space behind the board: a vertical wash, a far layer of blocks that never
## move, and a soft floor glow. Drawn before anything else.
static func draw_background(ci: CanvasItem, arena: Rect2) -> void:
	var top := PolarisTheme.BG_DEEP
	var bottom := Color("0a1020")
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
				if not arena.encloses(cell):
					continue
				var shade := alpha * (0.5 + float(h % 13) * 0.05)
				ci.draw_rect(cell, Color(PolarisTheme.WALL, shade), true)
				ci.draw_rect(
					Rect2(cell.position, Vector2(cell.size.x, 1.0)),
					Color(PolarisTheme.WALL_EDGE, shade * 1.6),
					true
				)

	# A cool glow along the bottom edge, so the arena has a light source.
	var glow := Rect2(arena.position.x, arena.end.y - 180.0, arena.size.x, 180.0)
	_gradient(
		ci, glow,
		Color(PolarisTheme.MINUS, 0.0), Color(PolarisTheme.MINUS, 0.0),
		Color(PolarisTheme.MINUS, 0.07), Color(PolarisTheme.MINUS, 0.07)
	)


## The arena's own edges, drawn as built structure.
##
## [SimWorld] adds side walls to every level that the board never showed, so the
## ball bounced off nothing visible. This draws them — and leaves the bottom open,
## because there the simulation really has no floor: dropping out of the arena
## loses the run, and the warning band says so.
static func draw_frame(ci: CanvasItem, arena: Rect2) -> void:
	var t := 13.0
	draw_solid(ci, Rect2(arena.position.x - t, arena.position.y - t, t, arena.size.y + t * 2.0), PolarisTheme.WALL_EDGE)
	draw_solid(ci, Rect2(arena.end.x, arena.position.y - t, t, arena.size.y + t * 2.0), PolarisTheme.WALL_EDGE)
	draw_solid(ci, Rect2(arena.position.x - t, arena.position.y - t, arena.size.x + t * 2.0, t), PolarisTheme.WALL_EDGE)

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


# --- Solids -----------------------------------------------------------------

## A wall or platform, built up rather than filled flat.
##
## Order matters: shadow, body, brick seams, lit cap, dark underside, outline. The
## cap is what makes a platform read as something the ball lands *on* instead of a
## rectangle it happens to stop inside.
static func draw_solid(ci: CanvasItem, r: Rect2, edge_tint: Color) -> void:
	ci.draw_rect(Rect2(r.position + Vector2(0, 5), r.size), Color(0, 0, 0, 0.35), true)

	_gradient(ci, r, FACE_TOP, FACE_TOP, FACE_BOTTOM, FACE_BOTTOM)
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
	ci.draw_rect(arena, Color(PolarisTheme.WALL_EDGE, 0.8), false, 3.0)


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
