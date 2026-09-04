@tool
class_name Levels
extends RefCounted

## The campaign. Five boards, each teaching exactly one thing.
##
## Levels are code rather than a baked JSON pack because there is no generator any
## more: a parcours is authored geometry, so the expensive offline pipeline the
## grid game needed is simply gone. What survives is the contract — every level
## ships a hold schedule that has been *proven* to win it, and
## `test_sim_levels.gd` replays all of them on every test run.
##
## The teaching order:
##  1. holding a magnet applies force, and force runs out
##  2. attract pulls the ball *to* the magnet, so it parks there
##  3. placing your own magnet
##  4. two magnets: push to launch, pull to catch
##  5. the full parcours

## No level builds a magnet in for the player.
##
## [member SimLevel.fixed_magnets] still exists, and the idea backlog has a use
## for it — always-on field furniture that a level makes you navigate around — but
## it must stay empty for any magnet the player would otherwise place. Choosing
## where the magnet goes is the decision the game is made of; handing it over
## turns a board into a rhythm exercise. Levels 1, 2 and 7 shipped with fixed
## magnets once, on the reasoning that an introduction should teach one thing at a
## time. That reasoning was wrong: it took away the thing being introduced.
const ARENA := Rect2(0, 0, 900, 660)


static func all() -> Array:
	return [_schub(), _zug(), _luecke(), _zwei(), _parcours(), _aufzug(), _schleuder(), _fahrt()]


static func by_id(id: int) -> SimLevel:
	for level: SimLevel in all():
		if level.id == id:
			return level
	return null


static func _make(id: int, title: String, lesson: String) -> SimLevel:
	var level := SimLevel.new()
	level.id = id
	level.title = title
	level.lesson = lesson
	level.arena = ARENA
	return level


## 1 — One repel magnet, a floor, and a long way to roll.
##
## No way to fail except running out of charge short of the goal, which is the
## whole lesson: the magnet is a budget, not a button.
static func _schub() -> SimLevel:
	var level := _make(1, "Schub", "Setze einen Abstoßer hinter die Kugel und halte 1. Die Ladung ist endlich.")
	level.feature = "Grundlagen"
	level.solids = [Rect2(0, 420, 900, 40)]
	level.start = Vector2(110, 300)
	level.target = Rect2(720, 330, 180, 90)
	level.budget = 1
	level.charge_seconds = 1.5
	level.par_placements = [SimLevel.MagnetSpec.new(75, 325, false, false)]
	level.par_holds = [[0, 5, 75]]
	return level


## 2 — A long fall: steering in the air, where Level 1 was rolling on the floor.
##
## This board used to ship an attract magnet and teach the property that surprises
## everyone — that attract parks the ball at the magnet instead of flinging it
## past. That lesson only held while the level *forced* the polarity on the
## player. With the magnet placed freely a repel from above wins easily, so the
## board would have been claiming to teach something its own par contradicts.
## The attract surprise now lives on Level 7, where the mechanic requires it.
static func _zug() -> SimLevel:
	var level := _make(2, "Flug", "Ein langer Fall. Lenke die Kugel unterwegs, statt sie zu rollen.")
	level.feature = "Grundlagen"
	level.solids = [Rect2(0, 600, 900, 60)]
	level.start = Vector2(300, 60)
	level.target = Rect2(560, 520, 220, 80)
	level.budget = 1
	level.charge_seconds = 1.5
	level.par_placements = [SimLevel.MagnetSpec.new(175, 25, false, false)]
	level.par_holds = [[0, 0, 50]]
	return level


## 3 — First placement: a gap in the floor, and one magnet to spend.
static func _luecke() -> SimLevel:
	var level := _make(3, "Lücke", "Die Lücke im Boden ist der Weg, nicht das Hindernis.")
	level.feature = "Grundlagen"
	level.solids = [Rect2(0, 430, 360, 30), Rect2(560, 430, 340, 30)]
	level.start = Vector2(110, 330)
	level.target = Rect2(370, 560, 180, 100)
	level.budget = 1
	level.charge_seconds = 1.5
	level.par_placements = [SimLevel.MagnetSpec.new(25, 375, false, false)]
	level.par_holds = [[0, 5, 20]]
	return level


## 4 — The relay: a pit too wide for one field to span.
##
## The forcing constraint is reach, not height. Start and goal lie 530px apart
## while a field reaches 400, so no single magnet can act on the ball where it
## starts *and* where it has to arrive — the ball has to be handed over.
##
## Two earlier drafts failed differently, and both failures are worth keeping in
## mind when adding levels:
##  - the first put both ledges inside one field, and the found replay won with
##    one magnet while the other sat idle. `test_every_placed_magnet_is_load_bearing`
##    now rejects that outright — the same rule the grid game applied to deflectors.
##  - the second added a 205px climb on top of the distance. Correct, but 2000
##    random schedules could not solve it, which is a fair proxy for a player on
##    their fourth board. Difficulty here is supposed to come from the handover,
##    not from the launch angle.
static func _zwei() -> SimLevel:
	var level := _make(4, "Zwei", "Ein Feld reicht 400 Pixel weit. Der Weg ist länger — also übergib.")
	level.feature = "Grundlagen"
	level.solids = [Rect2(0, 520, 380, 30), Rect2(620, 520, 280, 30)]
	level.start = Vector2(90, 480)
	level.target = Rect2(620, 440, 280, 80)
	level.budget = 2
	level.charge_seconds = 1.4
	# Repel from under the start edge, then attract from high above the far side:
	# the ball is thrown, then caught. Do not "tidy" the late start ticks by sliding
	# the whole plan forward — that was tried, and it loses. The ball is still
	# settling on the floor at tick 100, so the timings are not relative to a ball at
	# rest; they are relative to this run.
	level.par_placements = [
		SimLevel.MagnetSpec.new(75, 575, false, false),
		SimLevel.MagnetSpec.new(425, 125, true, false),
	]
	level.par_holds = [[0, 120, 175], [1, 140, 220]]
	return level


## 5 — The parcours from the prototype: four staggered ledges, gaps alternating.
static func _parcours() -> SimLevel:
	var level := _make(5, "Parcours", "Zwei Kanten, zwei Lücken — jede auf der anderen Seite.")
	level.feature = "Grundlagen"
	level.solids = [
		Rect2(0, 220, 560, 24),
		Rect2(340, 430, 560, 24),
	]
	level.start = Vector2(110, 80)
	level.target = Rect2(60, 550, 220, 90)
	level.budget = 2
	level.charge_seconds = 1.5
	level.par_placements = [SimLevel.MagnetSpec.new(275, 175, true, false), SimLevel.MagnetSpec.new(475, 525, true, false)]
	level.par_holds = [[0, 5, 25], [1, 45, 135]]
	return level


## 6 — First moving platform: a lift that carries the ball up.
##
## Vertical on purpose. A platform sliding *sideways* would barely drag the ball
## along: [constant SimWorld.FRICTION] is 0.015 per tick, deliberately low so
## rolling does not feel like sand, which means a ball resting on a horizontal
## platform reaches only about three quarters of its speed over a whole leg and
## slides off the back. A lift needs no friction at all — the contact normal
## carries the ball directly. Sideways platforms need a fix in the contact model,
## not a level that half works.
##
## The lift starts at the bottom and leaves immediately, so the ball cannot catch
## the first departure. Missing the platform drops it past the arena and loses the
## run. Waiting for the lift to come back *is* the lesson.
static func _aufzug() -> SimLevel:
	var level := _make(6, "Aufzug", "Der Aufzug trägt dich. Steig auf, wenn er unten ist — und warte, bis er es wieder ist.")
	level.feature = "Bewegte Plattformen"
	# The ledge ends where the lift's low position begins, and the target sits
	# exactly where the lift's high position delivers — so riding it *is* the
	# solution. The first draft also asked for a second push to hop off at the top;
	# two timing windows in the level that introduces timing was one too many, and
	# 3000 random plans found nothing.
	#
	# The slab over the start is there to stop a magnet simply launching the ball
	# up the outside and skipping the mechanic.
	level.solids = [Rect2(0, 480, 300, 26), Rect2(0, 300, 240, 24)]
	level.movers = [SimLevel.MoverSpec.new(Rect2(310, 480, 160, 20), Vector2(0, -260), 100)]
	level.start = Vector2(80, 430)
	level.target = Rect2(300, 130, 260, 90)
	level.budget = 1
	level.charge_seconds = 1.5
	# Boards the lift on its *second* visit to the bottom (t=200): the push at 155
	# starts the roll, the ball arrives as the platform does. Other slices found
	# 8.25s solutions that waited a further full cycle — this one is the same idea,
	# one cycle earlier, which is what the level is trying to teach.
	level.par_placements = [SimLevel.MagnetSpec.new(25, 575, false, false)]
	level.par_holds = [[0, 155, 185]]
	return level


## 7 — The reverse key: gather, then eject.
##
## Forcing a flip is harder than it looks, and the first two attempts failed the
## same way. A repel magnet placed next to the ball is a free launcher — direction
## chosen by where you put it, speed by how long you hold — so on an open board a
## single ballistic arc reaches almost any target. An exhaustive sweep of the
## earlier layout found **204** wins that never touched the reverse key.
##
## What makes the flip necessary here is the block the ball starts on. It is
## solid all the way down, so there is nowhere below or beside the ball to put a
## magnet: every placeable spot is *above* it, and repelling from above only
## presses the ball down into the block or rolls it off the edge. Nothing can
## throw it upward in one go.
##
## Attract alone cannot finish either. Lifting needs the magnet inside
## SimWorld.LIFT_RADIUS, so it sits close; from there the ball orbits, and an
## orbit carries it roughly back out to the distance it fell in from. The target
## is 580px away and 245px higher — out of that range.
##
## Attract to gather the speed, then reverse to eject it up and out. That is the
## only way, and the no-flip sweep in `test_sim.gd` keeps it that way.
static func _schleuder() -> SimLevel:
	var level := _make(7, "Schleuder", "Anziehen sammelt Schwung, Shift wirft ihn ab. Ein Stoß allein kommt hier nicht hoch.")
	level.feature = "Polarität umkehren"
	level.flip_enabled = true
	# One solid block, not a thin ledge. The thickness is the whole mechanism: it
	# denies the magnet every position from which a straight push would aim at the
	# target.
	# The block, plus a shelf with a back wall on the far side. The shelf is a
	# fairness fix, not decoration: with a bare rectangle floating on the arc, only
	# two flip timings out of the whole run landed inside it — 33 ms. A shelf catches
	# every arc that reaches it, so the window becomes a range instead of a point.
	# Open on the left, because that is where the arc comes in: a first version had
	# a wall there and the ball simply bounced off it, killing every solution.
	level.solids = [Rect2(0, 500, 260, 160)]
	level.start = Vector2(90, 440)
	# Placed by measurement, not by eye: a sweep of the whole placement grid mapped
	# which cells the ball can reach with and without reversing, and this box sits
	# inside the band only the slingshot arc passes through.
	level.target = Rect2(305, 305, 165, 50)
	level.budget = 1
	level.charge_seconds = 2.0
	# ACHTUNG, offene Schwaeche: nur 3 Ticks (50 ms) treffen, statt der geforderten
	# 15. Das ist strukturell und nicht durch Feinjustage zu beheben — alles, was
	# eine einzelne Polaritaet erreicht, ist als Ziel verboten, also bleibt nur der
	# Rand der Reichweite, und dorthin kommen ausschliesslich nahezu optimale Wuerfe.
	# Vier Zielpositionen wurden probiert; entweder war das Brett auch ohne Umpolen
	# zu gewinnen oder das Fenster blieb unter 50 ms.
	#
	# Bleibt so, weil "ohne Umpolen geht es nicht" die ausdrueckliche Vorgabe war.
	# Ein wirklich fairer Umpol-Zwang braucht vermutlich einen zweiten beweglichen
	# Teil (Plattform oder zweiter Magnet), damit die Notwendigkeit aus der Richtung
	# statt aus der Energie kommt.
	level.min_flip_window = 3
	level.par_placements = [SimLevel.MagnetSpec.new(75, 375, true, false)]
	level.par_holds = [[0, 0, 60], [SimWorld.INVERT_INPUT, 30, 60]]
	return level


## 8 — The planned path: one magnet that has to be in two places.
##
## Why the path is unavoidable here, in numbers. A magnet can only start a resting
## ball from inside MAGNET_RADIUS (400px), and can only lift it against gravity
## from inside LIFT_RADIUS (169px). The ball rests at x=90 and the climb happens at
## x=760, which is 670px apart — more than 400 + 169 = 569. **No single point in
## the arena satisfies both**, so a magnet that stands still cannot solve this
## board no matter where it is put or how long it is held.
##
## A magnet that travels can: hold it and the ball is gathered and towed along the
## path, up onto the far shelf. That is the whole level.
##
## Ballistics do not offer a way out either. Reaching the shelf from the start in
## one throw needs about 1130 px/s, and MAX_SPEED is 1100.
static func _fahrt() -> SimLevel:
	var level := _make(8, "Fahrt", "Zieh dem Magneten vor dem Start eine Bahn. Er schleppt die Kugel mit.")
	level.feature = "Geplante Magnetbahn"
	level.paths_enabled = true
	level.solids = [Rect2(0, 560, 720, 30), Rect2(760, 300, 140, 26)]
	level.start = Vector2(90, 520)
	level.target = Rect2(760, 220, 140, 80)
	level.budget = 1
	# Long, because the tow itself takes most of four seconds at MAGNET_SWEEP_SPEED.
	level.charge_seconds = 4.5
	# Start low-left, path up to above the shelf. `period` is derived, never typed:
	# a hand-written number that disagreed with SimWorld.sweep_ticks would make the
	# par unreproducible by a player drawing the same line.
	var bahn := Vector2(720, -260)
	level.par_placements = [
		SimLevel.MagnetSpec.new(60, 500, true, false, bahn, SimWorld.sweep_ticks(bahn)),
	]
	level.par_holds = [[0, 0, 220]]
	return level
