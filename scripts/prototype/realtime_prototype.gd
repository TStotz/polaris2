class_name RealtimePrototype
extends Node2D

## Throwaway prototype: the magnet game as a dexterity game.
##
## [b]This is not production code and does not share the campaign's rules.[/b] It
## exists to answer one question that arguing cannot: does steering a physically
## rolling ball with magnets feel good? Everything here is deliberately crude —
## one hand-drawn parcours, no levels, no saving, no solver.
##
## The loop, "plan the placement, play the timing":
##  1. [b]Place[/b] up to [constant MAGNET_BUDGET] magnets anywhere in open space.
##     This is the puzzle half, and it survives from the grid game.
##  2. [b]Run[/b]: the ball falls under real gravity. Holding a magnet's number
##     key pulls (or pushes) the ball for as long as you hold it.
##  3. Each magnet carries [constant MAGNET_CHARGE] seconds of activation and no
##     more. Duration is therefore a resource you spend, not a free input — which
##     is the whole point of the experiment. Holding everything down forever is
##     not a strategy.
##
## Why physics and not the grid: the campaign's difficulty turned out to be
## artificial, propped up by hiding what a move would do. Execution difficulty
## cannot be looked up, so it needs no hiding. The cost is that the solver, the
## generator and the differential fixtures do not survive the jump — none of them
## are used here.

enum Phase { PLACING, RUNNING, WON, LOST }

const MAGNET_BUDGET := 4
const MAGNET_CHARGE := 1.5  ## seconds of hold per magnet

## Reach has to span a ledge. At 260 it took two magnets just to cross one shelf,
## and the budget is four for the whole parcours.
const MAGNET_RADIUS := 400.0  ## beyond this a magnet does nothing

## Peak force, at the magnet's centre. Gravity here is 980, so this tops out at
## roughly 1.6 g: enough to lift the ball and steer it, not enough to fire it
## across the screen. The first pass used 4200 and a close repel launched the
## ball at 1188 px/s straight through a wall.
const MAGNET_STRENGTH := 1600.0

## Hard speed cap. Godot integrates in discrete steps, so a fast enough body
## simply steps past a thin ledge; the cap plus continuous collision keeps the
## parcours solid.
const MAX_SPEED := 900.0
const BALL_RADIUS := 15.0

## Keys 1..4 activate the magnets in placement order. Number keys rather than
## clicking them: both hands stay busy, and you can hold two at once, which is
## where the skill ceiling lives.
const ACTIVATION_KEYS := [KEY_1, KEY_2, KEY_3, KEY_4]

const ARENA := Rect2(0, 0, 900, 660)
const START := Vector2(110, 55)
## The goal is a zone the ball falls *through*, not a shelf — there is no floor,
## so missing it means falling out of the world.
const TARGET := Rect2(30, 600, 200, 52)

## The parcours: alternating ledges with a gap at one end, so the ball has to be
## nudged sideways on every drop or it just lands back on the same shelf.
const LEDGES: Array[Rect2] = [
	Rect2(0, 160, 620, 24),
	Rect2(260, 310, 640, 24),
	Rect2(0, 460, 620, 24),
	Rect2(260, 600, 640, 24),
]

## Left edge of the HUD column, in arena-local pixels.
const HUD_X := 930.0

var phase: Phase = Phase.PLACING

## Placed magnets: `{"pos": Vector2, "attract": bool, "charge": float}`.
var magnets: Array = []
var attract_tool := true

var _ball: RigidBody2D
var _hint := ""
var _elapsed := 0.0
var _best := 0.0


func _ready() -> void:
	_build_arena()
	_build_ball()
	set_process(true)
	set_physics_process(true)
	_reset_run()


func _build_arena() -> void:
	var body := StaticBody2D.new()
	add_child(body)
	# Ledges plus the two side walls; the floor is deliberately missing so a
	# botched run ends by falling out of the world.
	var solids := LEDGES.duplicate()
	solids.append(Rect2(-40, 0, 40, ARENA.size.y))
	solids.append(Rect2(ARENA.size.x, 0, 40, ARENA.size.y))
	for rect: Rect2 in solids:
		var shape := CollisionShape2D.new()
		var box := RectangleShape2D.new()
		box.size = rect.size
		shape.shape = box
		shape.position = rect.get_center()
		body.add_child(shape)


func _build_ball() -> void:
	_ball = RigidBody2D.new()
	_ball.gravity_scale = 1.0
	_ball.mass = 1.0
	# A little bounce and low friction so it rolls off ledges instead of sticking.
	var physics := PhysicsMaterial.new()
	physics.bounce = 0.18
	physics.friction = 0.25
	_ball.physics_material_override = physics
	# The ledges are 24px thin — without shape casting a fast ball tunnels them.
	_ball.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE

	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = BALL_RADIUS
	shape.shape = circle
	_ball.add_child(shape)
	add_child(_ball)


# --- Phases -----------------------------------------------------------------

func _reset_run() -> void:
	phase = Phase.PLACING
	_elapsed = 0.0
	_ball.freeze = true
	_ball.position = START
	_ball.linear_velocity = Vector2.ZERO
	_ball.angular_velocity = 0.0
	for magnet: Dictionary in magnets:
		magnet["charge"] = MAGNET_CHARGE
	_hint = "Setze bis zu %d Magnete." % MAGNET_BUDGET
	queue_redraw()


func _start_run() -> void:
	if magnets.is_empty():
		_hint = "Erst mindestens einen Magneten setzen."
		return
	phase = Phase.RUNNING
	_elapsed = 0.0
	_ball.freeze = false
	_hint = "Halte 1–%d!" % magnets.size()


func _finish(won: bool) -> void:
	phase = Phase.WON if won else Phase.LOST
	_ball.freeze = true
	if won:
		if _best <= 0.0 or _elapsed < _best:
			_best = _elapsed
		_hint = "Geschafft in %.2f s!" % _elapsed
	else:
		_hint = "Danebengegangen."


# --- Input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var button := event as InputEventMouseButton
		if phase != Phase.PLACING:
			return
		if button.button_index == MOUSE_BUTTON_LEFT:
			_place_magnet(get_local_mouse_position())
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			_erase_magnet(get_local_mouse_position())
		return

	if not (event is InputEventKey and event.pressed and not event.is_echo()):
		return
	match (event as InputEventKey).keycode:
		KEY_SPACE:
			if phase == Phase.PLACING:
				_start_run()
		KEY_R:
			_reset_run()
		KEY_C:
			magnets.clear()
			_reset_run()
		KEY_TAB:
			attract_tool = not attract_tool
			queue_redraw()
		KEY_ESCAPE:
			get_tree().change_scene_to_file("res://scenes/main.tscn")


func _place_magnet(at: Vector2) -> void:
	if magnets.size() >= MAGNET_BUDGET:
		_hint = "Budget voll — Rechtsklick entfernt einen."
		return
	if not ARENA.has_point(at):
		return
	for ledge: Rect2 in LEDGES:
		if ledge.grow(BALL_RADIUS).has_point(at):
			_hint = "Nicht in eine Wand."
			return
	magnets.append({"pos": at, "attract": attract_tool, "charge": MAGNET_CHARGE})
	queue_redraw()


func _erase_magnet(at: Vector2) -> void:
	for i in range(magnets.size() - 1, -1, -1):
		if (magnets[i]["pos"] as Vector2).distance_to(at) < 34.0:
			magnets.remove_at(i)
			queue_redraw()
			return


# --- Simulation -------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if phase != Phase.RUNNING:
		return
	_elapsed += delta

	var force := Vector2.ZERO
	for i in magnets.size():
		var magnet: Dictionary = magnets[i]
		if not _is_held(i) or magnet["charge"] <= 0.0:
			continue
		magnet["charge"] = maxf(0.0, magnet["charge"] - delta)
		force += _force_from(magnet)
	_ball.apply_central_force(force)
	if _ball.linear_velocity.length() > MAX_SPEED:
		_ball.linear_velocity = _ball.linear_velocity.normalized() * MAX_SPEED

	if TARGET.has_point(_ball.position):
		_finish(true)
	elif not ARENA.grow(220.0).has_point(_ball.position):
		_finish(false)


func _is_held(index: int) -> bool:
	return index < ACTIVATION_KEYS.size() and Input.is_key_pressed(ACTIVATION_KEYS[index])


## Force one active magnet applies to the ball.
##
## Falloff is linear to zero at [constant MAGNET_RADIUS], not the physical
## inverse square: a real 1/r² spikes to infinity at contact, so the ball snaps to
## the magnet and the input stops reading as steering. A bounded field is the
## controllable one.
func _force_from(magnet: Dictionary) -> Vector2:
	var to_ball: Vector2 = _ball.position - magnet["pos"]
	var distance := maxf(to_ball.length(), 12.0)
	if distance >= MAGNET_RADIUS:
		return Vector2.ZERO
	# Linear, not quadratic. Quadratic left the outer two thirds of the drawn
	# circle too weak to do anything, so the reach the player was shown was a lie.
	var falloff := 1.0 - distance / MAGNET_RADIUS
	var direction := to_ball / distance
	if magnet["attract"]:
		direction = -direction
	return direction * MAGNET_STRENGTH * falloff


func _process(_delta: float) -> void:
	queue_redraw()


# --- Drawing ----------------------------------------------------------------

func _draw() -> void:
	# Cover the whole window, not just the arena — this node is the only thing
	# drawing, so anything left unpainted shows the engine's clear colour.
	draw_rect(Rect2(-4000, -4000, 8000, 8000), PolarisTheme.BG, true)
	draw_rect(ARENA.grow(6.0), Color(PolarisTheme.MINUS, 0.05), true)
	draw_rect(ARENA, PolarisTheme.BG_DEEP, true)
	_draw_target()
	for ledge: Rect2 in LEDGES:
		draw_rect(ledge, PolarisTheme.WALL, true)
		draw_rect(
			Rect2(ledge.position, Vector2(ledge.size.x, 3)),
			Color(PolarisTheme.WALL_EDGE, 0.8),
			true
		)
	_draw_magnets()
	_draw_ball()
	_draw_hud()


func _draw_target() -> void:
	var pulse := 1.0 + 0.05 * sin(Time.get_ticks_msec() / 400.0)
	draw_rect(TARGET, Color(PolarisTheme.TARGET, 0.12), true)
	draw_rect(TARGET.grow(2.0 * pulse), Color(PolarisTheme.TARGET, 0.8), false, 3.0)


func _draw_magnets() -> void:
	for i in magnets.size():
		var magnet: Dictionary = magnets[i]
		var pos: Vector2 = magnet["pos"]
		var tint: Color = PolarisTheme.PLUS if magnet["attract"] else PolarisTheme.MINUS
		var charge: float = magnet["charge"]
		var held := phase == Phase.RUNNING and _is_held(i) and charge > 0.0

		# The reach circle is the contract with the player: outside it, nothing.
		draw_arc(pos, MAGNET_RADIUS, 0, TAU, 64, Color(tint, 0.10 if held else 0.05), 2.0)
		if held:
			for ring in 3:
				var t := (ring + 1) / 3.0
				draw_circle(pos, MAGNET_RADIUS * t, Color(tint, 0.05 * (1.0 - t)))

		draw_circle(pos, 22.0, Color(tint, 0.35 if charge <= 0.0 else 1.0))
		draw_circle(pos - Vector2(6, 7), 10.0, Color(Color.WHITE, 0.25))

		# Charge ring: how much hold time this magnet has left.
		if charge > 0.0:
			draw_arc(
				pos, 29.0, -PI / 2.0, -PI / 2.0 + TAU * (charge / MAGNET_CHARGE),
				32, PolarisTheme.ACCENT, 4.0, true
			)
		_label(str(i + 1), pos + Vector2(0, 5), PolarisTheme.BG if charge > 0.0 else PolarisTheme.INK_DIM, 18)


func _draw_ball() -> void:
	var pos := _ball.position
	draw_circle(pos + Vector2(0, 3), BALL_RADIUS, Color(0, 0, 0, 0.35))
	draw_circle(pos, BALL_RADIUS, PolarisTheme.BALL)
	draw_arc(pos, BALL_RADIUS, 0, TAU, 24, Color(PolarisTheme.BALL_EDGE, 0.9), 2.0, true)
	draw_circle(pos - Vector2(5, 6), BALL_RADIUS * 0.34, Color(1, 1, 1, 0.8))


func _draw_hud() -> void:
	var tool_name := "Anziehen" if attract_tool else "Abstoßen"
	var tool_color: Color = PolarisTheme.PLUS if attract_tool else PolarisTheme.MINUS
	_label("PROTOTYP · ECHTZEIT", Vector2(HUD_X, 46), PolarisTheme.INK_DIM, 13)
	_label(_hint, Vector2(HUD_X, 84), PolarisTheme.INK, 15)
	_label("Werkzeug: %s  (Tab)" % tool_name, Vector2(HUD_X, 130), tool_color, 15)
	var keys := [
		"Linksklick  Magnet setzen",
		"Rechtsklick  entfernen",
		"Tab  Polarität",
		"Leertaste  Lauf starten",
		"1–4 halten  Magnet wirkt",
		"R  neuer Versuch",
		"C  Brett leeren",
		"Esc  zurück zum Menü",
	]
	for i in keys.size():
		_label(keys[i], Vector2(HUD_X, 168 + i * 22), PolarisTheme.INK_DIM, 13)
	if phase == Phase.RUNNING:
		_label("%.2f s" % _elapsed, Vector2(HUD_X, 400), PolarisTheme.ACCENT, 30)
	if _best > 0.0:
		_label("Bestzeit %.2f s" % _best, Vector2(HUD_X, 436), PolarisTheme.OK, 14)


func _label(text: String, at: Vector2, color: Color, size: int) -> void:
	draw_string(
		ThemeDB.fallback_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color
	)
