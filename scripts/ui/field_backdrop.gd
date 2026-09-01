class_name FieldBackdrop
extends Control

## A slow dipole field drifting behind the menus.
##
## Two poles sit off the edges of the screen and the classic field lines arc
## between them, breathing in and out. It is the one image the whole game is
## about, and a title screen that is three buttons on black says "unfinished"
## louder than anything else on it.
##
## Deliberately cheap: polylines from a closed-form curve, no particles, no
## shader, no texture. It costs a few hundred line segments a frame and never
## competes with the foreground because everything is drawn at very low alpha.

## How many arcs per pole pair, and how finely each is sampled.
const ARC_COUNT := 9
const SAMPLES := 46

## Seconds for one full breath of the field.
const PERIOD := 26.0

var _time := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(true)


func _process(delta: float) -> void:
	_time += delta
	queue_redraw()


func _draw() -> void:
	var phase := TAU * _time / PERIOD
	# The poles drift on slow, mutually prime-ish cycles so the composition never
	# visibly repeats within a session.
	var plus_pole := Vector2(
		size.x * (0.16 + 0.05 * sin(phase * 0.7)),
		size.y * (0.30 + 0.07 * cos(phase * 0.5))
	)
	var minus_pole := Vector2(
		size.x * (0.86 + 0.05 * cos(phase * 0.6)),
		size.y * (0.74 + 0.07 * sin(phase * 0.8))
	)

	for i in ARC_COUNT:
		# -1 .. 1, so arcs bulge symmetrically above and below the axis.
		var spread := (float(i) / (ARC_COUNT - 1)) * 2.0 - 1.0
		var swell := 1.0 + 0.12 * sin(phase + i * 0.6)
		_draw_arc_between(plus_pole, minus_pole, spread * swell, i)


## One field line from [param from] to [param to], bowed sideways by
## [param bend]. Colour lerps along the curve so each line leaves the attracting
## pole red and arrives at the repelling one blue.
func _draw_arc_between(from: Vector2, to: Vector2, bend: float, index: int) -> void:
	var axis := to - from
	var normal := Vector2(-axis.y, axis.x).normalized()
	# A quadratic Bezier whose control point is pushed off the axis; the sine
	# envelope keeps both ends anchored on the poles.
	var control := from + axis * 0.5 + normal * axis.length() * 0.42 * bend

	var points := PackedVector2Array()
	points.resize(SAMPLES)
	for s in SAMPLES:
		var t := float(s) / (SAMPLES - 1)
		var inv := 1.0 - t
		points[s] = from * (inv * inv) + control * (2.0 * inv * t) + to * (t * t)

	# Fainter towards the outer arcs, so the bundle reads as volume.
	var strength := 1.0 - absf(bend) * 0.55
	var alpha := 0.055 * strength
	var width := maxf(1.0, size.y * 0.0018 * (0.6 + strength))

	# Two passes: a wide dim halo under a thin brighter core.
	draw_polyline_colors(
		points, _gradient(alpha * 0.5, points.size()), width * 3.5, true
	)
	draw_polyline_colors(points, _gradient(alpha, points.size()), width, true)

	# A drifting bright bead per line makes the field feel alive rather than
	# printed on the background.
	var bead := fmod(_time * 0.06 + index * 0.11, 1.0)
	var at := int(bead * (SAMPLES - 1))
	draw_circle(points[at], size.y * 0.0035, Color(PolarisTheme.INK, alpha * 3.5))


func _gradient(alpha: float, count: int) -> PackedColorArray:
	var colors := PackedColorArray()
	colors.resize(count)
	for i in count:
		var t := float(i) / (count - 1)
		colors[i] = Color(PolarisTheme.PLUS.lerp(PolarisTheme.MINUS, t), alpha)
	return colors
