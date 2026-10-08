class_name WorldArt
extends RefCounted

## The scenery, and only the scenery.
##
## [BoardArt] draws everything that *means* something — a magnet's polarity, the
## goal, a gate, a hazard, the ball. This file draws the place those things stand
## in, and the split follows exactly the rule the worlds already had: **a world
## repaints the scenery, never the vocabulary.** With both in one file that rule
## was a paragraph somebody had to remember; with them apart it is a file boundary,
## and `test_scenery_never_borrows_a_meaning` reads this source to hold it.
##
## So nothing here may draw in [constant PolarisTheme.PLUS], [constant
## PolarisTheme.MINUS], [constant PolarisTheme.TARGET], [constant PolarisTheme.OK],
## [constant PolarisTheme.ACCENT] or [constant PolarisTheme.BALL]. Seven colours per
## world, and every motif in this file is made out of those.
##
## Three shapes are off limits as well, and for the same reason a colour is: the
## board already speaks them. No chevrons or arrows — a gravity zone points with
## those. No regular sawtooth — that is a hazard. No bright disc with a field
## flowing in or out of it — that is a magnet. A porthole is a ring with something
## dark behind it, drawn far back and dim, and that is a different sentence.
##
## Like [BoardArt] it may use `sin`, `Time` and per-frame animation, and like
## [BoardArt] no function here returns a value.


# --- What a band is ---------------------------------------------------------

## A world is a stack of horizontal bands, and **the band you are in is where you
## are.** A freighter is not a tint: under the waterline there are frames and
## portholes with the sea behind them, over that the hold, and above the deck the
## crane booms. Climbing the board walks you through them.
##
## This costs the simulation nothing and buys something a palette cannot. On a tall
## board the camera follows the ball at 1:1, so the scenery *changes during the
## run* — it says how far you have come without a word of text, and it says it
## while you are busy, which is when a HUD cannot.
##
## The shares live on [member PolarisTheme.World.bands].

## Alphas. All of it sits behind the board, so the whole range is low: the
## brightest piece of scenery still has to lose to the dimmest thing that carries
## meaning — those draw at 0.4 and up, in colours that are saturated where these
## are not.
##
## The first set was half of this and measured wrong. Filled area survives a low
## alpha, which is why the block layer reads at 0.16; a one-pixel line at the same
## number is nothing at all, and most of this file is lines. The portholes were the
## control: a rim at 0.24 over 2.4px was the only motif legible in the first pass.
const FAINT := 0.10
const SOFT := 0.18
const CLEAR := 0.27
const LIT := 0.40


## Draws the bands of the current world that the camera can actually see.
##
## [param seen] is the part of the board on screen. Everything is culled against
## it: at 2200x1200 an uncounted background is thousands of shapes a frame, nearly
## all of them behind the panel — the block layer made that mistake once already.
static func draw(ci: CanvasItem, arena: Rect2, seen: Rect2, t: float) -> void:
	var world: PolarisTheme.World = PolarisTheme.world()
	var y := arena.position.y
	for entry: Array in world.bands:
		var height := arena.size.y * float(entry[1])
		var band := Rect2(arena.position.x, y, arena.size.x, height)
		y += height
		var strip := band.intersection(seen)
		if strip.size.x <= 0.0 or strip.size.y <= 0.0:
			continue
		_motif(ci, String(entry[0]), band, strip, world, t)


## [param band] is the whole slice and is the motif's frame of reference — where a
## waterline sits, how tall a stack of crates is. [param strip] is the part of it on
## screen, and is what anything repeating must iterate instead.
static func _motif(
	ci: CanvasItem, name: String, band: Rect2, strip: Rect2,
	world: PolarisTheme.World, t: float
) -> void:
	match name:
		"sterne": _sterne(ci, band, strip, world, t)
		"huelle": _huelle(ci, band, strip, world)
		"decksplatten": _decksplatten(ci, band, strip, world)
		"kranausleger": _kranausleger(ci, band, strip, world, t)
		"laderaum": _laderaum(ci, band, strip, world)
		"unterdeck": _unterdeck(ci, band, strip, world, t)
		"schachtkopf": _schachtkopf(ci, band, strip, world)
		"gestein": _gestein(ci, band, strip, world, t)
		"sumpf": _sumpf(ci, band, strip, world, t)
		"galerie": _galerie(ci, band, strip, world, t)
		"kern": _kern(ci, band, strip, world, t)
		"kuehlkreis": _kuehlkreis(ci, band, strip, world, t)
		"offenes": _offenes(ci, band, strip, world, t)
		"truemmer": _truemmer(ci, band, strip, world, t)
		"rumpfbruch": _rumpfbruch(ci, band, strip, world)
		"einlauf": _einlauf(ci, band, strip, world)
		"sortierboden": _sortierboden(ci, band, strip, world)
		"schaechte": _schaechte(ci, band, strip, world)
		"himmel": _himmel(ci, band, strip, world, t)
		"takelage": _takelage(ci, band, strip, world)
		"aussenhaut": _aussenhaut(ci, band, strip, world)


# --- The parts every motif is built from ------------------------------------

## First and last lattice index that the range [param low]..[param high] touches.
##
## Every repeating motif starts here rather than walking the arena.
static func _span(low: float, high: float, pitch: float) -> Vector2i:
	return Vector2i(int(floor(low / pitch)), int(ceil(high / pitch)))


## Cheap deterministic scramble, the same one [BoardArt] uses.
##
## Deliberately not `randf()`: a value rolled per frame makes scenery shimmer, and
## shimmering scenery pulls the eye off the board. Hashed by lattice position, a
## rivet keeps its shade for the whole run.
static func _hash(value: int) -> int:
	var h := value * 374761393 + 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return absi(h ^ (h >> 16))


## A horizontal run of dots — rivets, bolts, ice.
static func _studs(
	ci: CanvasItem, strip: Rect2, y: float, pitch: float, tone: Color, size: float
) -> void:
	if y < strip.position.y - size or y > strip.end.y + size:
		return
	var cols := _span(strip.position.x, strip.end.x, pitch)
	for i in range(cols.x, cols.y + 1):
		ci.draw_circle(Vector2(float(i) * pitch, y), size, tone)


## Horizontal plating: a seam every [param pitch], lit on top and shadowed under,
## so a plate reads as something lying down rather than as a stripe.
static func _plates(
	ci: CanvasItem, strip: Rect2, pitch: float, world: PolarisTheme.World, alpha: float
) -> void:
	var rows := _span(strip.position.y, strip.end.y, pitch)
	for i in range(rows.x, rows.y + 1):
		var y := float(i) * pitch
		ci.draw_line(
			Vector2(strip.position.x, y), Vector2(strip.end.x, y),
			Color(world.wall_edge, alpha), 1.5
		)
		ci.draw_line(
			Vector2(strip.position.x, y + 2.5), Vector2(strip.end.x, y + 2.5),
			Color(world.deep, alpha * 0.9), 1.5
		)


## Upright bars — frames, posts, masts, dividers.
static func _uprights(
	ci: CanvasItem, top: float, bottom: float, strip: Rect2, pitch: float,
	width: float, world: PolarisTheme.World, alpha: float
) -> void:
	var cols := _span(strip.position.x, strip.end.x, pitch)
	for i in range(cols.x, cols.y + 1):
		var x := float(i) * pitch
		ci.draw_rect(Rect2(x, top, width, bottom - top), Color(world.wall, alpha), true)
		ci.draw_line(
			Vector2(x, top), Vector2(x, bottom), Color(world.wall_edge, alpha * 1.5), 1.6
		)


## A slack line between two points.
##
## Straight would read as a girder. The sag is what says *cable*, and it is the
## cheapest shape in this file that does.
static func _sag(
	ci: CanvasItem, from: Vector2, to: Vector2, drop: float, tone: Color, width: float
) -> void:
	var last := from
	for i in range(1, 9):
		var f := float(i) / 8.0
		var point := from.lerp(to, f)
		point.y += drop * sin(f * PI)
		ci.draw_line(last, point, tone, width)
		last = point


## Points of light on a coarse lattice.
##
## Each one twinkles on its own hashed phase. A shared phase would make the whole
## field pulse as one object, which is the single thing a sky must never do.
static func _starfield(
	ci: CanvasItem, strip: Rect2, world: PolarisTheme.World, t: float, alpha: float
) -> void:
	var pitch := 70.0
	var cols := _span(strip.position.x, strip.end.x, pitch)
	var rows := _span(strip.position.y, strip.end.y, pitch)
	for col in range(cols.x, cols.y + 1):
		for row in range(rows.x, rows.y + 1):
			var h := _hash(col * 73 + row * 149)
			if h % 5 == 0:
				continue
			var at := Vector2(
				float(col) * pitch + float(h % 53), float(row) * pitch + float((h >> 5) % 53)
			)
			var bright := 0.6 + 0.4 * sin(t * 0.7 + float(h % 628) * 0.01)
			ci.draw_circle(at, 0.8 + float(h % 3) * 0.4, Color(world.glow, alpha * bright))


# --- Polaris: a station, and the star it is named for -----------------------

## Deliberately the faintest set in the file. Fifteen campaign boards wear this
## world today, so its scenery has to change the mood without ever competing for
## the reading.
static func _sterne(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World, t: float
) -> void:
	_starfield(ci, strip, world, t, SOFT)

	# The pole star: the one fixed thing in a world named after it. Put at a share
	# of the band rather than at a pixel, so every board carries it in the same
	# place whatever size it is.
	var pole := Vector2(
		band.position.x + band.size.x * 0.78, band.position.y + band.size.y * 0.3
	)
	if not strip.has_point(pole):
		return
	ci.draw_circle(pole, 2.6, Color(world.glow, LIT))
	for arm: Vector2 in [Vector2(11.0, 0.0), Vector2(0.0, 11.0)]:
		ci.draw_line(pole - arm, pole + arm, Color(world.glow, SOFT), 1.0)


## Hull panelling: seams across, joints up, bolts along the seams.
static func _huelle(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World
) -> void:
	_plates(ci, strip, 96.0, world, FAINT)
	var cols := _span(strip.position.x, strip.end.x, 164.0)
	var rows := _span(strip.position.y, strip.end.y, 96.0)
	for row in range(rows.x, rows.y + 1):
		var top := maxf(float(row) * 96.0, band.position.y)
		var bottom := minf(float(row) * 96.0 + 96.0, band.end.y)
		if bottom <= top:
			continue
		for col in range(cols.x, cols.y + 1):
			# Staggered by row. Joints stacked in one column read as a grid, and a
			# hull is built in courses.
			var x := float(col) * 164.0 + (82.0 if row % 2 == 1 else 0.0)
			ci.draw_line(
				Vector2(x, top), Vector2(x, bottom), Color(world.wall_edge, FAINT), 1.4
			)
		_studs(ci, strip, float(row) * 96.0 + 8.0, 41.0, Color(world.wall_edge, FAINT), 1.1)


## Deck plating, heavier and tighter than the hull above it, with a keel strake
## along the top of the band to part the two.
static func _decksplatten(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World
) -> void:
	ci.draw_rect(
		Rect2(strip.position.x, band.position.y, strip.size.x, 6.0),
		Color(world.wall, CLEAR), true
	)
	_plates(ci, strip, 68.0, world, SOFT)
	var rows := _span(strip.position.y, strip.end.y, 68.0)
	for row in range(rows.x, rows.y + 1):
		_studs(
			ci, strip, float(row) * 68.0 + 7.0, 58.0, Color(world.wall_edge, FAINT * 0.8), 1.2
		)


# --- Werft: a freighter you climb out of ------------------------------------

## Crane booms over the deck, and a hook on a slack cable.
static func _kranausleger(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World, t: float
) -> void:
	for i in 2:
		var y := band.position.y + band.size.y * (0.28 if i == 0 else 0.64)
		var depth := 22.0 if i == 0 else 16.0
		var alpha := CLEAR if i == 0 else SOFT
		ci.draw_rect(Rect2(strip.position.x, y, strip.size.x, 5.0), Color(world.wall, alpha), true)
		ci.draw_rect(
			Rect2(strip.position.x, y + depth, strip.size.x, 4.0), Color(world.wall, alpha), true
		)
		# Bracing between the two chords, flipping direction each bay. That zigzag is
		# what makes a pair of parallel bars read as a truss instead of two pipes —
		# and it leans, so it never lines up into the row of points a hazard has.
		var pitch := 34.0
		var cols := _span(strip.position.x, strip.end.x, pitch)
		for col in range(cols.x, cols.y + 1):
			var x := float(col) * pitch
			var high := Vector2(x if col % 2 == 0 else x + pitch, y + 5.0)
			var low := Vector2(x + pitch if col % 2 == 0 else x, y + depth)
			ci.draw_line(high, low, Color(world.wall_edge, alpha * 0.8), 1.2)

	# One hook, hung off the upper boom on a cable that sways. It is the only moving
	# thing up here, which is what keeps the yard from reading as a photograph.
	var from := Vector2(
		band.position.x + band.size.x * 0.36, band.position.y + band.size.y * 0.28 + 22.0
	)
	var hook := from + Vector2(sin(t * 0.35) * 26.0, band.size.y * 0.5)
	if not strip.intersects(
		Rect2(minf(from.x, hook.x) - 20.0, from.y, 72.0, hook.y - from.y + 30.0)
	):
		return
	ci.draw_line(from, hook, Color(world.wall_edge, CLEAR), 1.4)
	ci.draw_arc(hook + Vector2(0.0, 9.0), 9.0, PI * 0.15, PI * 1.5, 12, Color(world.wall_edge, LIT), 2.0)


## The hold: crates stacked to the deckhead, chains in the gaps between them.
static func _laderaum(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World
) -> void:
	var wide := 124.0
	var tall := 76.0
	var cols := _span(strip.position.x, strip.end.x, wide)
	var rows := _span(strip.position.y, strip.end.y, tall)
	for col in range(cols.x, cols.y + 1):
		for row in range(rows.x, rows.y + 1):
			var h := _hash(col * 97 + row * 211 + 5)
			if h % 7 == 0:
				continue
			var top := float(row) * tall
			if top < band.position.y or top + tall > band.end.y:
				continue
			var box := Rect2(float(col) * wide + 5.0, top + 4.0, wide - 10.0, tall - 8.0)
			ci.draw_rect(box, Color(world.wall, SOFT + float(h % 4) * 0.012), true)
			# A lit top edge, the same trick a platform uses — it is what makes a box
			# read as something stacked rather than as a painted rectangle.
			ci.draw_rect(
				Rect2(box.position, Vector2(box.size.x, 1.5)), Color(world.wall_edge, CLEAR), true
			)
			ci.draw_rect(box, Color(world.wall_edge, FAINT), false, 1.0)
			for rib in 2:
				var x := box.position.x + box.size.x * (0.3 if rib == 0 else 0.7)
				ci.draw_line(
					Vector2(x, box.position.y + 3.0), Vector2(x, box.end.y - 3.0),
					Color(world.deep, SOFT), 1.4
				)
			if h % 5 != 0:
				continue
			var cx := box.position.x + box.size.x * 0.5
			for link in 5:
				ci.draw_circle(
					Vector2(cx, box.end.y + 4.0 + float(link) * 6.0), 1.6,
					Color(world.wall_edge, SOFT)
				)


## Below the waterline: frames, rivets, and portholes with the sea behind them.
##
## The sea is the world's own *deep* colour and not a blue of its own. A new hue
## here would be a colour the player has to learn, and [constant
## PolarisTheme.MINUS] already owns blue. A dim disc behind a lit ring says
## "outside" without borrowing anything.
static func _unterdeck(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World, t: float
) -> void:
	_uprights(ci, band.position.y, band.end.y, strip, 152.0, 13.0, world, SOFT)
	for row in 3:
		_studs(
			ci, strip, band.position.y + band.size.y * (0.12 + float(row) * 0.33), 26.0,
			Color(world.wall_edge, SOFT), 1.3
		)

	var pitch := 304.0
	var eye := band.position.y + band.size.y * 0.42
	var cols := _span(strip.position.x, strip.end.x, pitch)
	for col in range(cols.x, cols.y + 1):
		var at := Vector2(float(col) * pitch + 76.0, eye)
		var r := 26.0
		if not strip.intersects(Rect2(at - Vector2(r, r) * 1.3, Vector2(r, r) * 2.6)):
			continue
		ci.draw_circle(at, r, Color(world.deep, 0.5))
		ci.draw_arc(at, r, 0.0, TAU, 28, Color(world.wall_edge, LIT), 2.4)
		ci.draw_arc(at, r - 5.0, PI * 1.1, PI * 1.7, 12, Color(world.wall_edge, SOFT), 1.4)
		_studs(ci, strip, at.y - r - 5.0, 9.0, Color(world.wall_edge, FAINT), 0.9)

		var h := _hash(col * 313 + 77)
		if h % 3 != 0:
			continue
		# A fish crosses this one. The swim is a wrap of the clock, so it leaves one
		# side of the glass and comes back the other — a porthole somebody watches
		# for a whole run should not be empty.
		var travel := fmod(t * 0.14 + float(h % 100) * 0.01, 1.0)
		var fish := Vector2(at.x - r + travel * r * 2.0, at.y + sin(travel * TAU) * 7.0)
		if fish.distance_to(at) > r - 6.0:
			continue
		var tone := Color(world.wall, 0.55)
		ci.draw_colored_polygon(
			PackedVector2Array([
				fish + Vector2(6.0, 0.0), fish + Vector2(-3.0, -3.0), fish + Vector2(-3.0, 3.0),
			]), tone
		)
		ci.draw_colored_polygon(
			PackedVector2Array([
				fish + Vector2(-3.0, 0.0), fish + Vector2(-8.0, -4.0), fish + Vector2(-8.0, 4.0),
			]), tone
		)


# --- Schacht: the one story that runs the other way -------------------------

## The head frame, and the ladder somebody came down. This band is the *way out*,
## so it is the brightest thing in the world — which is the point of a shaft.
static func _schachtkopf(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World
) -> void:
	_uprights(ci, band.position.y, band.end.y, strip, 214.0, 16.0, world, SOFT)
	for i in 2:
		var y := band.position.y + band.size.y * (0.26 if i == 0 else 0.64)
		ci.draw_rect(Rect2(strip.position.x, y, strip.size.x, 9.0), Color(world.wall, CLEAR), true)
		ci.draw_line(
			Vector2(strip.position.x, y), Vector2(strip.end.x, y),
			Color(world.wall_edge, LIT), 1.2
		)

	var rail := band.position.x + band.size.x * 0.58
	if not strip.intersects(Rect2(rail - 4.0, band.position.y, 34.0, band.size.y)):
		return
	for side in 2:
		var x := rail + (0.0 if side == 0 else 26.0)
		ci.draw_line(
			Vector2(x, band.position.y), Vector2(x, band.end.y), Color(world.wall_edge, CLEAR), 2.0
		)
	var rungs := _span(strip.position.y, strip.end.y, 22.0)
	for i in range(rungs.x, rungs.y + 1):
		var y := float(i) * 22.0
		if y < band.position.y or y > band.end.y:
			continue
		ci.draw_line(Vector2(rail, y), Vector2(rail + 26.0, y), Color(world.wall_edge, SOFT), 1.4)


## Rock, in layers. The wobble is the whole motif — a straight line here is
## masonry, and masonry is something somebody built.
static func _gestein(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World, t: float
) -> void:
	var pitch := 54.0
	var rows := _span(strip.position.y - band.position.y, strip.end.y - band.position.y, pitch)
	for i in range(rows.x, rows.y + 1):
		var base := band.position.y + float(i) * pitch
		var h := _hash(i * 401)
		var points := PackedVector2Array()
		var x := strip.position.x - 40.0
		while x < strip.end.x + 40.0:
			points.append(
				Vector2(x, base + sin(x * 0.0121 + float(h % 628) * 0.01) * 7.0)
			)
			x += 40.0
		if points.size() < 2:
			continue
		ci.draw_polyline(points, Color(world.wall_edge, SOFT + float(h % 5) * 0.016), 1.6)

		# Seepage: a streak under a seam, with a bead running down it. Water is what
		# a shaft has instead of weather.
		if h % 4 != 0:
			continue
		var sx := float(int(band.position.x) + int(h % 1600))
		if sx < strip.position.x - 10.0 or sx > strip.end.x + 10.0:
			continue
		ci.draw_line(
			Vector2(sx, base), Vector2(sx, base + pitch), Color(world.glow, FAINT), 1.0
		)
		var bead := fmod(t * 0.3 + float(h % 97) * 0.01, 1.0)
		ci.draw_circle(Vector2(sx, base + bead * pitch), 1.6, Color(world.glow, SOFT))


## Standing water at the bottom of the shaft, with drowned pipework under it.
static func _sumpf(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World, t: float
) -> void:
	var line := band.position.y + band.size.y * 0.22
	if line < strip.end.y:
		ci.draw_rect(
			Rect2(
				strip.position.x, maxf(line, strip.position.y),
				strip.size.x, strip.end.y - maxf(line, strip.position.y)
			),
			Color(world.deep, 0.42), true
		)
	for depth in 3:
		var y := band.position.y + band.size.y * (0.42 + float(depth) * 0.19)
		if y < strip.position.y - 8.0 or y > strip.end.y + 8.0:
			continue
		ci.draw_rect(
			Rect2(strip.position.x, y, strip.size.x, 7.0), Color(world.wall, FAINT), true
		)

	# The surface, out of two waves of different length so it never repeats on the
	# eye. Drawn last, over the wash, because a waterline is a horizon.
	var points := PackedVector2Array()
	var x := strip.position.x - 30.0
	while x < strip.end.x + 30.0:
		points.append(
			Vector2(x, line + sin(x * 0.017 + t * 0.6) * 3.0 + sin(x * 0.0043 - t * 0.35) * 5.0)
		)
		x += 22.0
	if points.size() >= 2:
		ci.draw_polyline(points, Color(world.glow, CLEAR), 1.6)


# --- Reaktor: everything on the beat ----------------------------------------

## A gallery over the core, with lamps that run along it.
##
## The one world whose lights share a phase on purpose. Its ban is *no rest*, and a
## running light is that said in scenery — everywhere else a shared phase would be
## the mistake.
static func _galerie(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World, t: float
) -> void:
	var deck := band.position.y + band.size.y * 0.62
	ci.draw_rect(Rect2(strip.position.x, deck, strip.size.x, 8.0), Color(world.wall, CLEAR), true)
	ci.draw_line(
		Vector2(strip.position.x, deck), Vector2(strip.end.x, deck), Color(world.wall_edge, LIT), 1.2
	)
	var rail := deck - 30.0
	ci.draw_line(
		Vector2(strip.position.x, rail), Vector2(strip.end.x, rail), Color(world.wall_edge, SOFT), 1.2
	)
	var posts := _span(strip.position.x, strip.end.x, 42.0)
	for i in range(posts.x, posts.y + 1):
		var x := float(i) * 42.0
		ci.draw_line(Vector2(x, rail), Vector2(x, deck), Color(world.wall_edge, SOFT), 1.0)

	var lamps := _span(strip.position.x, strip.end.x, 168.0)
	for i in range(lamps.x, lamps.y + 1):
		var x := float(i) * 168.0
		var beat := fmod(t * 0.8 - float(i) * 0.18, 1.0)
		if beat > 0.22:
			continue
		var fade := 1.0 - beat / 0.22
		ci.draw_circle(Vector2(x, rail - 7.0), 3.0 + 2.0 * fade, Color(world.glow, LIT * fade))


## The core: a vessel with light in it, control rods hanging into it, one slow
## breath.
##
## **The first cut was concentric rings around a lit disc, and that was the shape
## this file is not allowed to make.** It is how [method BoardArt.draw_magnet]
## draws a field — rings running in or out of a bright centre — so the scenery was
## quietly putting a second magnet on every board, big and dim and in the middle of
## the screen. The colour was never the problem; the *shape* was. A vessel is
## upright, banded and rectangular, and shares nothing with a disc.
static func _kern(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World, t: float
) -> void:
	var middle := Vector2(
		band.position.x + band.size.x * 0.5, band.position.y + band.size.y * 0.58
	)
	var half := Vector2(minf(band.size.x * 0.095, 120.0), band.size.y * 0.33)
	var vessel := Rect2(middle - half, half * 2.0)
	if strip.intersects(vessel):
		var breath := 0.5 + 0.5 * sin(t * 1.3)
		ci.draw_rect(vessel, Color(world.deep, 0.45), true)
		ci.draw_rect(vessel, Color(world.wall_edge, LIT), false, 2.6)
		# A filament with a halo, not a filled panel.
		#
		# The first version painted the whole inside of the vessel at up to 0.45 of
		# a saturated yellow-green, and at that size it beat the board it was behind
		# — the alphas in this file are calibrated on *line* work and thin shapes,
		# and a large fill at the same number is a different quantity of light. Two
		# narrow rects say "lit from within" for a fraction of the ink.
		for layer in 2:
			var wide := half.x * (0.5 if layer == 0 else 0.16)
			var alpha := (0.05 + 0.05 * breath) if layer == 0 else (0.10 + 0.12 * breath)
			ci.draw_rect(
				Rect2(
					middle.x - wide, vessel.position.y + 16.0,
					wide * 2.0, vessel.size.y - 32.0
				),
				Color(world.glow, alpha), true
			)
		var seams := _span(vessel.position.y, vessel.end.y, 32.0)
		for i in range(seams.x, seams.y + 1):
			var y := float(i) * 32.0
			if y <= vessel.position.y or y >= vessel.end.y:
				continue
			ci.draw_line(
				Vector2(vessel.position.x, y), Vector2(vessel.end.x, y),
				Color(world.wall_edge, SOFT), 1.8
			)

	# Rods, hanging into the core from the shielding above it.
	var rods := _span(strip.position.x, strip.end.x, 58.0)
	for i in range(rods.x, rods.y + 1):
		var x := float(i) * 58.0
		var drop := band.position.y + band.size.y * (0.16 + float(_hash(i * 619) % 5) * 0.03)
		if drop < strip.position.y and band.position.y > strip.end.y:
			continue
		ci.draw_rect(
			Rect2(x, band.position.y, 7.0, drop - band.position.y), Color(world.wall, SOFT), true
		)
		ci.draw_circle(Vector2(x + 3.5, drop), 4.0, Color(world.wall_edge, CLEAR))


## The coolant loop, with a pulse running along each pipe.
static func _kuehlkreis(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World, t: float
) -> void:
	for i in 3:
		var y := band.position.y + band.size.y * (0.2 + float(i) * 0.27)
		if y < strip.position.y - 24.0 or y > strip.end.y + 24.0:
			continue
		ci.draw_rect(Rect2(strip.position.x, y, strip.size.x, 17.0), Color(world.wall, SOFT), true)
		ci.draw_line(
			Vector2(strip.position.x, y + 1.0), Vector2(strip.end.x, y + 1.0),
			Color(world.wall_edge, CLEAR), 1.2
		)
		var flanges := _span(strip.position.x, strip.end.x, 128.0)
		for f in range(flanges.x, flanges.y + 1):
			ci.draw_rect(
				Rect2(float(f) * 128.0, y - 3.0, 9.0, 23.0), Color(world.wall_edge, SOFT), true
			)

		# The pulse wraps the whole band, not the visible strip, so it keeps its
		# place on the pipe while the camera moves.
		var at := band.position.x + fmod(
			t * 150.0 + float(i) * band.size.x * 0.31, band.size.x
		)
		if at < strip.position.x - 60.0 or at > strip.end.x + 60.0:
			continue
		ci.draw_rect(Rect2(at - 26.0, y + 4.0, 52.0, 9.0), Color(world.glow, SOFT), true)


# --- Wrack: no floor, and the top says so -----------------------------------

## Open space, with the edge of something large in it.
##
## The only world whose top band is empty. That is its ban — *no floor* — put where
## the player looks when they are about to fall off the board.
static func _offenes(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World, t: float
) -> void:
	_starfield(ci, strip, world, t, CLEAR)
	var middle := Vector2(band.position.x - band.size.x * 0.25, band.end.y + band.size.y * 1.1)
	var reach := band.size.y * 1.7
	if not strip.intersects(Rect2(middle - Vector2(reach, reach), Vector2(reach, reach) * 2.0)):
		return
	ci.draw_arc(middle, reach, PI * 1.62, PI * 1.98, 64, Color(world.wall_edge, CLEAR), 2.4)
	ci.draw_arc(middle, reach - 13.0, PI * 1.68, PI * 1.92, 48, Color(world.glow, FAINT), 9.0)


## A debris field, adrift.
##
## The shapes are irregular quadrilaterals on purpose. Anything regular and pointed
## here would read as a hazard, which is the one sentence this file may not say.
static func _truemmer(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World, t: float
) -> void:
	var pitch := 156.0
	var cols := _span(strip.position.x - pitch, strip.end.x + pitch, pitch)
	var rows := _span(strip.position.y - pitch, strip.end.y + pitch, pitch)
	for col in range(cols.x, cols.y + 1):
		for row in range(rows.x, rows.y + 1):
			var h := _hash(col * 131 + row * 283 + 19)
			if h % 4 == 0:
				continue
			var slow := t * (0.05 + float(h % 7) * 0.012)
			var at := Vector2(
				float(col) * pitch + float(h % 90) + sin(slow) * 14.0,
				float(row) * pitch + float((h >> 7) % 90) + cos(slow * 0.8) * 10.0
			)
			if not band.has_point(at) or not strip.has_point(at):
				continue
			var size := 9.0 + float(h % 26)
			var spin := slow * 0.5
			var points := PackedVector2Array()
			for corner in 4:
				var angle := spin + float(corner) * TAU / 4.0 + float((h >> corner) % 40) * 0.01
				var out := size * (0.6 + float((h >> (corner * 3)) % 9) * 0.06)
				points.append(at + Vector2(cos(angle), sin(angle)) * out)
			ci.draw_colored_polygon(points, Color(world.wall, CLEAR + float(h % 5) * 0.012))
			ci.draw_polyline(points, Color(world.wall_edge, SOFT), 1.2)


## Where the hull tore. Plating above, a ragged break, bare frames under it.
static func _rumpfbruch(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World
) -> void:
	var tear := band.position.y + band.size.y * 0.4
	_plates(ci, Rect2(
		strip.position.x, strip.position.y, strip.size.x,
		maxf(0.0, minf(tear, strip.end.y) - strip.position.y)
	), 38.0, world, SOFT)
	_uprights(ci, tear, band.end.y, strip, 96.0, 8.0, world, FAINT)

	# The break, stepped by a hash rather than by a wave: a tear is not periodic,
	# and a periodic one would be a row of teeth.
	var points := PackedVector2Array()
	var steps := _span(strip.position.x - 40.0, strip.end.x + 40.0, 40.0)
	for i in range(steps.x, steps.y + 1):
		var h := _hash(i * 787 + 3)
		points.append(Vector2(float(i) * 40.0, tear + float(h % 27) - 13.0))
	if points.size() >= 2:
		ci.draw_polyline(points, Color(world.wall_edge, LIT), 2.0)


# --- Sortieranlage: no free path --------------------------------------------

## Hoppers, feeding the floor below.
static func _einlauf(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World
) -> void:
	var pitch := 246.0
	var top := band.position.y + band.size.y * 0.15
	var mouth := band.end.y - 14.0
	var cols := _span(strip.position.x - pitch, strip.end.x, pitch)
	for i in range(cols.x, cols.y + 1):
		var x := float(i) * pitch
		ci.draw_colored_polygon(
			PackedVector2Array([
				Vector2(x, top), Vector2(x + 196.0, top),
				Vector2(x + 132.0, mouth), Vector2(x + 64.0, mouth),
			]),
			Color(world.wall, SOFT)
		)
		ci.draw_polyline(
			PackedVector2Array([
				Vector2(x, top), Vector2(x + 64.0, mouth),
				Vector2(x + 132.0, mouth), Vector2(x + 196.0, top),
			]),
			Color(world.wall_edge, CLEAR), 1.4
		)
		ci.draw_rect(Rect2(x + 64.0, mouth, 68.0, 14.0), Color(world.deep, CLEAR), true)


## The sorting floor: belts, rollers, and bays marked by pips.
##
## Pips rather than arrows. An arrow here would be the shape a gravity zone uses to
## say which way it pulls, and a board that has both would be a board where the
## player has to work out which arrow is real.
static func _sortierboden(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World
) -> void:
	for i in 3:
		var y := band.position.y + band.size.y * (0.14 + float(i) * 0.3)
		if y < strip.position.y - 30.0 or y > strip.end.y + 30.0:
			continue
		ci.draw_rect(Rect2(strip.position.x, y, strip.size.x, 21.0), Color(world.wall, SOFT), true)
		ci.draw_line(
			Vector2(strip.position.x, y), Vector2(strip.end.x, y), Color(world.wall_edge, CLEAR), 1.2
		)
		var rollers := _span(strip.position.x, strip.end.x, 24.0)
		for r in range(rollers.x, rollers.y + 1):
			var x := float(r) * 24.0
			ci.draw_line(Vector2(x, y + 3.0), Vector2(x, y + 18.0), Color(world.deep, SOFT), 1.0)

		var bays := _span(strip.position.x, strip.end.x, 252.0)
		for b in range(bays.x, bays.y + 1):
			var bx := float(b) * 252.0
			var count := 1 + _hash(b * 457 + i * 13) % 4
			for pip in count:
				ci.draw_circle(
					Vector2(bx + float(pip) * 9.0, y + 29.0), 2.4, Color(world.glow, SOFT)
				)


## The bins under the floor, each filled to its own level.
static func _schaechte(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World
) -> void:
	var pitch := 132.0
	var cols := _span(strip.position.x - pitch, strip.end.x, pitch)
	for i in range(cols.x, cols.y + 1):
		var x := float(i) * pitch
		ci.draw_rect(
			Rect2(x, band.position.y, 10.0, band.size.y), Color(world.wall, SOFT), true
		)
		var fill := band.end.y - band.size.y * (0.12 + float(_hash(i * 911) % 46) * 0.01)
		ci.draw_rect(
			Rect2(x + 10.0, fill, pitch - 10.0, band.end.y - fill), Color(world.wall, FAINT), true
		)
		ci.draw_line(
			Vector2(x + 10.0, fill), Vector2(x + pitch, fill), Color(world.wall_edge, SOFT), 1.2
		)


# --- Sturm: the outside of the hull -----------------------------------------

## Driven cloud, and once in a while a sheet of light behind it.
##
## The flash is kept to a sixteenth of its band's alpha and to a fifth of a second.
## A full-strength strobe across the board would be both a nuisance and a hazard to
## somebody it is a hazard to; a sky that brightens is enough to say storm.
static func _himmel(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World, t: float
) -> void:
	for i in 4:
		var y := band.position.y + band.size.y * (0.1 + float(i) * 0.24)
		var depth := 20.0 + float(i) * 9.0
		if y + depth < strip.position.y or y > strip.end.y:
			continue
		var drift := fmod(t * (8.0 + float(i) * 5.0), 260.0)
		var cols := _span(strip.position.x - 260.0, strip.end.x, 260.0)
		for c in range(cols.x, cols.y + 1):
			var h := _hash(c * 353 + i * 71)
			ci.draw_rect(
				Rect2(float(c) * 260.0 + drift, y + float(h % 11), 170.0 + float(h % 70), depth),
				Color(world.wall, SOFT), true
			)

	var strike := fmod(t, 7.3)
	if strike > 0.2:
		return
	# Capped at 0.04 across the band. This is the one shape in the file that covers
	# the whole screen, and a bright one would be a strobe — an annoyance to
	# everyone and a hazard to some. A sky that *lifts* for a fifth of a second
	# reads as storm; it does not have to flash to do it.
	ci.draw_rect(strip, Color(world.glow, 0.04 * (1.0 - strike / 0.2)), true)


## Rigging: masts, guys, and the ice that collects on them.
static func _takelage(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World
) -> void:
	var pitch := 326.0
	_uprights(ci, band.position.y, band.end.y, strip, pitch, 11.0, world, SOFT)
	var cols := _span(strip.position.x - pitch, strip.end.x, pitch)
	for i in range(cols.x, cols.y + 1):
		var x := float(i) * pitch
		var from := Vector2(x + 5.0, band.position.y + band.size.y * 0.18)
		var to := Vector2(x + pitch + 5.0, band.position.y + band.size.y * 0.34)
		_sag(ci, from, to, band.size.y * 0.16, Color(world.wall_edge, SOFT), 1.2)
		var low := Vector2(x + pitch + 5.0, band.position.y + band.size.y * 0.72)
		_sag(ci, from, low, band.size.y * 0.1, Color(world.wall_edge, FAINT), 1.0)
		# Ice, where the wire sags deepest and the water runs to.
		var hang := from.lerp(to, 0.5) + Vector2(0.0, band.size.y * 0.16)
		for bead in 3:
			ci.draw_circle(
				hang + Vector2(float(bead - 1) * 11.0, float(_hash(i * 233 + bead) % 5)),
				1.8 + float(_hash(i * 97 + bead) % 3), Color(world.glow, SOFT)
			)


## The hull skin itself, with ice built up along its weather edge.
static func _aussenhaut(
	ci: CanvasItem, band: Rect2, strip: Rect2, world: PolarisTheme.World
) -> void:
	_plates(ci, strip, 52.0, world, SOFT)
	var cols := _span(strip.position.x, strip.end.x, 19.0)
	for i in range(cols.x, cols.y + 1):
		var h := _hash(i * 617 + 11)
		ci.draw_circle(
			Vector2(float(i) * 19.0, band.position.y + float(h % 9)),
			2.0 + float(h % 7) * 0.7, Color(world.glow, FAINT + float(h % 4) * 0.012)
		)

	# Wind, as streaks that are longer than anything else in the world. Nothing here
	# moves: the ban is *no friction*, and a still picture of speed is the joke.
	var rows := _span(strip.position.y, strip.end.y, 43.0)
	for i in range(rows.x, rows.y + 1):
		var h := _hash(i * 743)
		var y := float(i) * 43.0 + float(h % 21)
		var from := band.position.x + float(h % int(maxf(1.0, band.size.x)))
		if from > strip.end.x or from + 260.0 < strip.position.x:
			continue
		ci.draw_line(
			Vector2(from, y), Vector2(from + 190.0 + float(h % 120), y),
			Color(world.wall_edge, FAINT), 1.0
		)
