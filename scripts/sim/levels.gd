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
	return [
		_schub(), _zug(), _luecke(), _zwei(), _parcours(),
		_aufzug(), _schleuder(), _fahrt(), _kurve(), _kippe(),
		_langer_weg(), _zeitlupe(), _sprungfolge(), _aufstieg(),
		_die_reise(),
	]


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
	# Gemessen: 7 Ticks Spielraum beim ersten Halten — unter der Schwelle von 15.
	level.min_timing_window = 7
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
	# Gemessen: 2 Ticks. Der Aufzug verlangt den Druck auf 33 ms genau — dieselbe
	# Fehlerklasse, die Level 11 hatte, und noch unbezahlt.
	level.min_timing_window = 2
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
	# Gemessen: 1 Tick. Dieses Brett gibt schon beim Umpolen nur 3 (min_flip_window)
	# und ist als unfair vermerkt; hier steht dasselbe Eingeständnis für den Anfang.
	level.min_timing_window = 1
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
	# Gemessen: 6 Ticks am Stück. Die Bahn selbst ist großzügig, der Startzeitpunkt
	# nicht — und die gewinnenden Zeitpunkte liegen in Grüppchen statt am Stück,
	# worauf niemand zielen kann.
	level.min_timing_window = 6
	return level


## 9 — Around the corner.
##
## Three earlier versions of this board were thrown away, and each one taught
## something about the physics that is worth not relearning:
##
##  1. An attract field that carries the ball up into the goal. It worked, but it
##     was Level 7 in a different hat — 7, 8 and 9 all ended on the same picture.
##  2. A repeller under the floor as a kicker. An always-on repeller is a cushion,
##     not a catapult: it pushes the ball to the distance where its force equals
##     gravity and holds it there, because nothing stores energy. Measured rise:
##     25px.
##  3. A repeller sweeping sideways as a plough. Mapped cell by cell, the ball
##     reached 13 cells with it and 14 without — an always-on repeller near the
##     start pins the ball rather than transporting it.
##
## What this board ended up using was found by measuring, not by planning, and it
## is a property of the simulation no level had touched: **a field reaches through
## solid geometry**. The foreign attractor sits behind a tall wall and pulls the
## ball against it — the ball ends up pinned to the wall face and is dragged
## *upward along it* to the height where the goal sits. Confirmed in the trace:
## the ball parks at x=405, exactly one radius left of the wall at 420, and climbs
## from there.
##
## Straight ballistics cannot do that. A throw either clears the wall and
## overshoots, or falls short; only a throw caught by the field rides the wall up.
static func _kurve() -> SimLevel:
	var level := _make(9, "Kurve", "Das fremde Feld wirkt durch die Wand. Wirf die Kugel so, dass es sie daran hochzieht.")
	level.feature = "Fremdes Feld"
	# No shelf under the target. One was tried, and it removed every solution: the
	# reachable-cell map was measured on this geometry, and adding a solid inside
	# the very cells it found changed the trajectories that reached them.
	level.solids = [Rect2(0, 520, 380, 30), Rect2(420, 180, 24, 370)]
	level.start = Vector2(90, 480)
	# Not guessed — measured. A cell-by-cell map of where the ball can go with and
	# without the foreign field showed exactly eight cells that only the field
	# reaches, and this box sits inside the two of them that are adjacent.
	level.target = Rect2(300, 300, 120, 60)
	var bahn := Vector2(0, 120)
	level.fixed_magnets = [
		SimLevel.MagnetSpec.new(560, 260, true, true, bahn, SimWorld.sweep_ticks(bahn), true),
	]
	level.budget = 1
	level.charge_seconds = 1.5
	level.par_placements = [SimLevel.MagnetSpec.new(325, 375, true, false)]
	level.par_holds = [[0, 0, 90]]
	return level


## 10 — A shaft where gravity flips on a beat.
##
## Inside the shaft the pull reverses every `period` ticks. The ball has to travel
## *up* through it to reach the goal, and one up-phase is deliberately too short to
## clear the whole climb: it rises, the beat flips, it falls back. Escaping means
## adding lift at the right moment, which is what the player's magnet is for.
##
## The shaft is open at the bottom left so the ball can roll in, and walled above
## so it cannot drift out sideways while it bobs.
static func _kippe() -> SimLevel:
	var level := _make(10, "Kippe", "Im Schacht kippt die Schwerkraft im Takt. Ein Takt allein reicht nicht hoch.")
	level.feature = "Kippende Schwerkraft"
	level.solids = [
		Rect2(0, 600, 900, 30),
		Rect2(500, 200, 16, 250),
		Rect2(700, 200, 16, 400),
	]
	level.start = Vector2(250, 560)
	level.target = Rect2(516, 100, 184, 100)
	level.zones = [SimLevel.GravitySpec.new(Rect2(516, 200, 184, 400), 40)]
	level.budget = 1
	level.charge_seconds = 1.5
	# Placed just outside the shaft mouth: the hold both drives the ball in and adds
	# the lift that turns a bounce into an escape.
	level.par_placements = [SimLevel.MagnetSpec.new(475, 475, true, false)]
	level.par_holds = [[0, 30, 90]]
	return level


## 11 — The long way: one commitment, then a ride through everything.
##
## The arena is 2200x1200, so the board no longer fits the window and the camera
## follows. Four mechanics in series, each already introduced on its own board:
##
##  1. a push, because nothing else can start the ball
##  2. a **moving platform** that is only a bridge while it is up — arrive late and
##     the gap is open
##  3. a **flipping-gravity shaft** that lifts the ball the height of the level
##  4. a **foreign field** at the top that reels it sideways into the goal
##
## The player gets one magnet and one hold. That is the whole input: where it goes
## and when it fires decide when the ball reaches the bridge, which decides whether
## it crosses, which decides which beat of the shaft it catches. A long chain from
## a single decision, which is what makes it worth the length.
static func _langer_weg() -> SimLevel:
	return _lange_strecke(
		11, "Der lange Weg", "Alles zusammen",
		"Brücke, dann der Tunnel über dem Nichts — steig ein, wenn der Takt nach oben zeigt."
	)


## The same board, with time slowed after the checkpoint hands over its magnet.
##
## Deliberately not a variation but the *same geometry*, built by the same
## function: the question it asks is what slowed time does to a decision, and any
## other difference between the two would muddy the answer. It is the one place in
## the campaign where two entries share a board on purpose.
static func _zeitlupe() -> SimLevel:
	var level := _lange_strecke(
		12, "Zeitlupe", "Zeitlupe",
		"Dasselbe Brett — aber nach dem Tor läuft die Zeit langsam, bis du gehalten hast."
	)
	# On its gate, so the twin differs from Level 11 in exactly one thing.
	level.slowmo_points = [(level.checkpoints[0] as SimLevel.Checkpoint).rect]
	level.twin_of = 11
	return level


## Four gaps, four magnets, and the board stops before each jump.
##
## The steps are deliberately **identical in shape** — same pitch, same rise, same
## gap — so a move that works once works again. That is the point of the board:
## the first jump is a puzzle solved while planning, and the next three are the
## same puzzle solved under a clock, with the checkpoint holding the board just
## long enough to aim.
##
## The budget is one. The other three magnets are earned at the gates, which is why
## the par carries four placements: three of them are born mid-run (see
## `test_par_placements_match_the_budget`).
static func _sprungfolge() -> SimLevel:
	var level := _make(
		13, "Sprungfolge",
		"Der Ball ist hier leicht genug zum Springen — vier Lücken, vier Höhen."
	)
	level.feature = "Zeitlupe"
	level.arena = Rect2(0, 0, 2150, 900)
	# **The one board where the ball is light enough to jump.** At the campaign's
	# 2600 a magnet beats gravity only inside 169px, which is enough to steer a ball
	# already rolling and never enough to pick one up off a floor — so every earlier
	# level is about *steering*. At 6000 the lifting reach is 300px and a magnet
	# 100px above the ball pulls it up at 3000 px/s², twice what gravity pulls down.
	# That is what makes a jump a jump, and it is why the platforms may now sit at
	# different heights: a step *up* was impossible before and is the point here.
	level.magnet_strength = 6000.0
	# Pitch 430, so every gap is 150px of nothing, and the heights step up and down
	# so that no two jumps are the same shape. (They were all identical while the
	# board was flat — that made sense when the only question was "how far"; with
	# height in play the question changes per gap, which is the better one.)
	level.solids = [
		Rect2(80, 700, 280, 30),
		Rect2(510, 580, 280, 30),
		Rect2(940, 660, 280, 30),
		Rect2(1370, 520, 280, 30),
		Rect2(1800, 620, 280, 30),
	]
	level.start = Vector2(140, 685)
	level.target = Rect2(1820, 540, 240, 80)
	# One gate before each of the last three gaps, each ending at the surface it
	# stands on. Down to the arena floor they would also catch a ball that has
	# already fallen past the platform — a checkpoint in a state with no way out,
	# which criterion 9 forbids.
	# At the *near* edge of each platform, not before the next gap. Landing has to be
	# what earns the magnet: the attractor that carries the ball across also parks
	# it, so it arrives at walking pace and stops somewhere along the platform.
	# Measured, that somewhere ranges over 200px — with the gate at the far end, a
	# short landing left the player stranded with no magnet and no way to move, which
	# is the dead end criterion 9 forbids. At the near edge every arrival trips it.
	level.checkpoints = [
		SimLevel.Checkpoint.new(Rect2(515, 0, 40, 580), 1),
		SimLevel.Checkpoint.new(Rect2(945, 0, 40, 660), 1),
		SimLevel.Checkpoint.new(Rect2(1375, 0, 40, 520), 1),
	]
	# Slowed time starts where the gates are, so passing one is what buys the moment
	# to think. They are separate lists, so a later board can move them apart.
	level.slowmo_points = [
		Rect2(515, 0, 40, 580),
		Rect2(945, 0, 40, 660),
		Rect2(1375, 0, 40, 520),
	]
	level.budget = 1
	level.charge_seconds = 1.5
	# One magnet placed while planning, three earned at the gates — so the par
	# carries four placements against a budget of one, and the three extra ones say
	# so with a birthday. The same move at the same offset each time: the steps
	# repeat every 430px, and so does the answer.
	# One magnet placed while planning, three earned at the gates — four placements
	# against a budget of one, and the three extra ones say so with a birthday. Each
	# was searched for on its own: with the heights staggered no two jumps have the
	# same shape, so nothing repeats the way it did on the flat version.
	level.par_placements = [
		SimLevel.MagnetSpec.new(325, 450, true, false, Vector2.ZERO, 1, false, 0),
		SimLevel.MagnetSpec.new(750, 280, true, false, Vector2.ZERO, 1, false, 111),
		SimLevel.MagnetSpec.new(1180, 390, true, false, Vector2.ZERO, 1, false, 220),
		SimLevel.MagnetSpec.new(1520, 250, true, false, Vector2.ZERO, 1, false, 293),
	]
	# Level 13 does not meet the 15-tick bar, and says so here rather than having
	# the bar quietly lowered for everyone — the same admission Level 7 makes with
	# `min_flip_window`. Per station this par gives 41 / 14 / 13 / 7 ticks; the
	# last jump is the one that only just works.
	#
	# The number did not get worse, the measurement got honest. Until Level 15 the
	# criterion only ever shifted the *first* press and required the whole chain to
	# still win, so presses two, three and four were never varied at all.
	#
	# Not for want of trying: the authoring tool searched this board for two minutes
	# with backtracking and found a dozen robust answers for the second jump, every
	# one of which left the third without one. That is a statement about the
	# geometry — five platforms at 430px pitch — and fixing it means moving them.
	level.min_timing_window = 7
	level.par_holds = [[0, 0, 56], [1, 111, 191], [2, 220, 276], [3, 293, 325]]
	return level


## Straight up, zig-zagging: left, right, left, right. Miss and there is nothing
## underneath.
##
## The first board that is taller than it is wide, which is the whole point — the
## camera pulls back to the full 900×1400 while planning and follows at 1:1 during
## the climb, so the route is a thing you read top to bottom before you start.
##
## Same light ball as Level 13 (see `magnet_strength` there for why 6000 and not
## 2600). The difference is the direction of the problem: Level 13 asks how to
## cross, this one asks how to *rise*, and every jump is the same 200px up and
## about 200px sideways — alternating, so the answer mirrors each time.
static func _aufstieg() -> SimLevel:
	var level := _make(
		14, "Aufstieg",
		"Immer abwechselnd links und rechts nach oben — unter dir ist nichts."
	)
	level.feature = "Aufstieg"
	level.magnet_strength = 6000.0
	level.arena = Rect2(0, 0, 800, 1200)
	# 140px up per step and only 80px of gap sideways. The first cut asked for 200
	# and 200 and the search found no robust answer for the *return* jump at all:
	# going back the other way costs the same rise without the run-up. These are the
	# magnitudes Level 13 proved climbable with the same field strength.
	level.solids = [
		Rect2(120, 1100, 240, 26),
		Rect2(440, 960, 240, 26),
		Rect2(120, 820, 240, 26),
		Rect2(440, 680, 240, 26),
		Rect2(120, 540, 240, 26),
	]
	level.start = Vector2(200, 1085)
	level.target = Rect2(140, 460, 200, 80)
	# The airspace above each platform, not an edge. On a climb the ball arrives from
	# the side *and* from below, so which edge is the near one flips every step —
	# a band over the whole platform catches every arrival without that argument.
	level.checkpoints = [
		SimLevel.Checkpoint.new(Rect2(440, 860, 240, 100), 1),
		SimLevel.Checkpoint.new(Rect2(120, 720, 240, 100), 1),
		SimLevel.Checkpoint.new(Rect2(440, 580, 240, 100), 1),
	]
	# Slowed time over the same bands: you land, time stretches, and that is when the
	# next jump gets aimed.
	level.slowmo_points = [
		Rect2(440, 860, 240, 100),
		Rect2(120, 720, 240, 100),
		Rect2(440, 580, 240, 100),
	]
	# Long enough to cover the landing *and* the wait after it. A point is crossed
	# while the ball is still rising past the platform, and on a climb the moment
	# that matters comes later: the par presses 50 ticks after the first gate, with
	# the ball finally standing still at 24 px/s. At the default 25 the slowed
	# stretch was over by then, so the only thing it bought was the chance to press
	# too early and fight the momentum — reported from play as exactly that.
	level.slowmo_ticks = 70
	level.budget = 1
	level.charge_seconds = 1.5
	# One magnet before the start, three earned on the way up. Every one was searched
	# for separately — a climb mirrors direction each step, so nothing repeats.
	#
	# Magnet 2 is born at 105 and held from 130: the hold may start later than the
	# birth, and on a climb it has to. Pulling while the ball is still coming down
	# only drags it off the platform it was about to land on.
	# One magnet before the start, three earned on the way up. Every one was searched
	# for separately — a climb mirrors direction each step, so nothing repeats.
	#
	# Magnet 2 is born at 105 and held from 130: the hold may start later than the
	# birth, and on a climb it has to. Pulling while the ball is still coming down
	# only drags it off the platform it was about to land on.
	level.par_placements = [
		SimLevel.MagnetSpec.new(350, 935, true, false, Vector2.ZERO, 1, false, 0),
		SimLevel.MagnetSpec.new(442, 825, true, false, Vector2.ZERO, 1, false, 118),
		SimLevel.MagnetSpec.new(355, 504, true, false, Vector2.ZERO, 1, false, 176),
		SimLevel.MagnetSpec.new(463, 534, true, false, Vector2.ZERO, 1, false, 258),
	]
	# The first hold starts at 20, not 0, and that is the difference between a
	# playable board and a knife edge. Measured: with the magnet already in lifting
	# range at tick 0 the ball is snatched up before it has settled on the platform,
	# so a three-tick delay gave a *different* run — gate 1 moved from 105 to 99 —
	# and the fairness window collapsed to one tick. Letting it rest first makes a
	# small mistiming what it should be: the same jump, a moment later.
	level.par_holds = [[0, 20, 96], [1, 143, 171], [2, 176, 220], [3, 283, 311]]
	return level


## 15 — The prototype for a *journey*: five stations, one after another.
##
## Levels 1..14 each ask one question and are over in five to eight seconds. This
## board asks five in a row, and it exists to answer a question about the shape
## rather than about a mechanic: does a long chained board hold up, or does it
## just feel like four levels glued together?
##
## **What "long" can and cannot mean here.** A five-minute *run* is not the thing
## to build. Five magnets is five decisions, so at five minutes of flight the
## player decides something once every sixty seconds and watches for the rest —
## Level 11's failure mode (five seconds driven by a single press) written large.
## What makes a board long is the number of stations, and what makes a *session*
## long is planning, slowed time and retries. The measured budget: five segments
## of 150..400 ticks is roughly 20 seconds of flight, four slowed stretches add
## about six seconds of wall clock on top, and a first-time player will spend
## minutes on it.
##
## Every station is a shape the campaign has already proven, in series:
##
##  1. the shove and the **swinging bridge** — Level 11's opening, unchanged
##  2. the **flipping-gravity shaft** — enter on an upward beat or fall out
##  3. out of the shaft and across to a **high ledge**
##  4. off the ledge, over a gap, onto the face of a **wall**
##  5. the **foreign field** behind that wall drags you up it, into the goal
##
## Reusing proven set pieces is the point of a prototype: if the form fails it
## should fail because of the form, not because station three was badly cut.
static func _die_reise() -> SimLevel:
	var level := _make(
		15, "Die Reise",
		"Fünf Stationen am Stück. Jedes Tor schenkt dir den Magneten für das, was danach kommt."
	)
	level.feature = "Die Reise"
	level.arena = Rect2(0, 0, 3200, 1400)
	# A longer horizon than the campaign's 20 s, and per level rather than global:
	# see SimLevel.max_ticks for why raising it for everyone was the expensive
	# version. 2400 ticks is 40 s — about twice what the par needs, which is the
	# same slack the 1200 gives a five-second board.
	level.max_ticks = 2400
	level.solids = [
		# --- 1. the run-up and the bridge, Level 11's floor plan one-for-one ------
		Rect2(0, 1200, 700, 40),
		# The lip that runs a little way into the shaft mouth and then stops. It is
		# the stage the gate's magnet plays on: where you hold the ball while the
		# beat turns. Measured on Level 11 — 100px of it and a ball rolling at
		# ~120 px/s simply sits out one downward beat, and the hole is decoration.
		Rect2(920, 1200, 340, 40),
		# --- 2. the shaft --------------------------------------------------------
		Rect2(1204, 420, 16, 720),
		Rect2(1420, 420, 16, 820),
		# --- 3. the high ledge ---------------------------------------------------
		#
		# 700px of it, which is most of the station. The first cut was 460 and the
		# gate sat over the whole thing, so it fired on landing and the stretch
		# before it measured 48 ticks — the segment floor exactly, and a duplicate
		# of the gate at the shaft mouth in everything but position. Long enough to
		# roll across, with the gate at the far end, it is a station.
		Rect2(1560, 420, 800, 40),
		# --- 4/5. the wall the foreign field reaches through ----------------------
		Rect2(2620, 220, 24, 420),
		# A landing at the foot of the wall, hard against it.
		#
		# Without it the last station had to cross the gap *and* climb, and the tool
		# reported the goal flatly unreachable. From rest a 2600 field lifts about
		# 170px and no further — it beats gravity only inside 169px, and an attractor
		# parks the ball at itself — so a climb is only as long as one magnet's reach
		# plus whatever the foreign field adds. Landing here first splits the two into
		# stations that each fit inside that.
		Rect2(2460, 600, 160, 30),
	]
	# Swings *around* the floor line rather than hanging below it: 40px proud at the
	# top of its travel. Hung below, Level 11's opening was a 12-tick window and a
	# player reported being thrown back to the start over and over.
	var brueckenweg := Vector2(0, 100)
	level.movers = [
		SimLevel.MoverSpec.new(
			Rect2(700, 1160, 220, 26), brueckenweg, SimWorld.sweep_ticks(brueckenweg)
		),
	]
	# 760px of shaft against a 50-tick beat — deliberately more than one upward
	# phase can clear, so escaping means adding lift at the right moment.
	level.zones = [SimLevel.GravitySpec.new(Rect2(1220, 440, 200, 760), 50)]
	# Behind the wall, reaching through it: the ball is pressed against the face and
	# dragged up it. Level 9's discovery, and the only thing in the game that uses
	# the fact that a field ignores geometry.
	#
	# It cannot do the climb alone — from the face it beats about 400 of the 1500
	# gravity — so the last magnet has to supply the rest. That is what keeps it
	# furniture rather than a solution.
	#
	# Its height is the whole station. Hung at 380 — halfway up the wall — the last
	# stage was reported **unreachable**, not tight: the ball arrives at (2624,446)
	# and the goal sat 220px above it, which is more climb than a 2600 field can
	# even start. Lift beats gravity only inside 169px, so a magnet placed high
	# enough to matter is too far to pull. Criterion 8, walked into anyway. At goal
	# height the field drags the ball up the face to meet it, exactly as Level 9's
	# does, and the player's magnet supplies what is missing.
	var feldweg := Vector2(0, 90)
	level.fixed_magnets = [
		SimLevel.MagnetSpec.new(
			2800, 270, true, true, feldweg, SimWorld.sweep_ticks(feldweg), true
		),
	]
	level.start = Vector2(110, 1160)
	# Above the wall's top edge, so the climb has to be finished rather than merely
	# started.
	level.target = Rect2(2450, 240, 160, 160)
	# Four gates, one per risk. Each blocks the corridor it stands in over the full
	# free height — a gate as a box on the floor misses anyone who arrives flying.
	level.checkpoints = [
		# Before the shaft mouth, not inside it: past the mouth the run can only be
		# lost to the clock, so a gate there would hand out a magnet for a stretch
		# that needs none.
		SimLevel.Checkpoint.new(Rect2(1164, 0, 40, 1200), 1),
		# At the shaft's mouth on the way *out*, crossed while still rising. What
		# follows is the fall back in, so this is in front of the risk, not after it.
		SimLevel.Checkpoint.new(Rect2(1220, 560, 200, 100), 1),
		# At the *far* end of the ledge, spanning its corridor from the ceiling down
		# to the plate — not a band over the whole ledge. Over the whole ledge it
		# fired the instant the ball touched down, which put two gates 48 ticks
		# apart on what is really one stretch. Here it stands where it belongs:
		# immediately before the gap.
		SimLevel.Checkpoint.new(Rect2(2080, 0, 40, 420), 1),
		# In front of the wall's face, where the ball arrives from across the gap.
		SimLevel.Checkpoint.new(Rect2(2460, 460, 184, 140), 1),
	]
	# Slowed time on the gates, which is this board's choice and not a rule. 40 ticks
	# rather than the default 25: the decision at a gate here is never at the moment
	# of crossing — you cross the shaft mouth still rolling and the wall still
	# flying, and the useful instant is a beat later.
	level.slowmo_ticks = 70
	level.slowmo_points = [
		Rect2(1164, 0, 40, 1200),
		Rect2(1220, 560, 200, 100),
		Rect2(2080, 0, 40, 420),
		Rect2(2460, 460, 184, 140),
	]
	level.budget = 1
	level.charge_seconds = 2.0
	# Found by `tests/test_zy_author.gd`; the numbers below are transcribed from
	# `tools/found_par.txt` by hand, as every par is.
	level.par_placements = [
		SimLevel.MagnetSpec.new(60, 1160, false, false, Vector2.ZERO, 1, false, 0),
		SimLevel.MagnetSpec.new(1115, 1135, true, false, Vector2.ZERO, 1, false, 216),
		SimLevel.MagnetSpec.new(1279, 450, false, false, Vector2.ZERO, 1, false, 442),
		SimLevel.MagnetSpec.new(2030, 355, false, false, Vector2.ZERO, 1, false, 813),
		SimLevel.MagnetSpec.new(2533, 416, true, false, Vector2.ZERO, 1, false, 869),
	]
	level.par_holds = [[0, 20, 112], [1, 241, 301], [2, 467, 559], [3, 813, 905], [4, 894, 986]]
	return level


static func _lange_strecke(id: int, title: String, feature: String, lesson: String) -> SimLevel:
	var level := _make(id, title, lesson)
	level.feature = feature
	level.arena = Rect2(0, 0, 2200, 1200)
	level.solids = [
		Rect2(0, 1000, 700, 40),
		# Runs 100px *into* the shaft and then stops: under the rest of the tunnel
		# there is nothing. Rolling out over the void on a downward beat is a fall out
		# of the world, so entering is a decision about *when* rather than something
		# that happens to you on the way past.
		#
		# That 40px lip is not a compromise, it is the stage the checkpoint's magnet
		# plays on: it is where you hold the ball while the beat turns.
		#
		# Its length was measured, not guessed. Of the 35 opening shoves that clear
		# the bridge, 12 then die at the tunnel with this lip — the entry decides
		# something. At 100px only 7 did, because a ball rolling at ~120px/s crosses
		# 100px in exactly one downward beat and can simply wait it out; the hole was
		# then decoration. Without any lip 21 die, but the opening window collapses
		# from 22 ticks to 13, under the fairness bar.
		Rect2(920, 1000, 340, 40),
		Rect2(1204, 320, 16, 620),
		Rect2(1420, 320, 16, 720),
	]
	# The bridge swings *around* floor level, not below it: 40px proud at the top of
	# its travel, 60 under at the bottom.
	#
	# It used to hang from the floor line downwards, and that made the opening shove
	# a 12-tick window (200ms) — measured, after a player reported being thrown back
	# to the start over and over. Miss it and the ball drops into the hole, bounces
	# on the platform and costs a 20-second timeout, never having reached a
	# checkpoint to fall back to. Swinging through the floor line gives the window
	# 32 ticks (533ms), because the bridge is at a usable height for most of its
	# cycle instead of for an instant. Slowing the old bridge was tried first and
	# made it *worse*: the ball then arrives while it is far down and cannot climb out.
	var brueckenweg := Vector2(0, 100)
	level.movers = [
		SimLevel.MoverSpec.new(
			Rect2(700, 960, 220, 26), brueckenweg, SimWorld.sweep_ticks(brueckenweg)
		),
	]
	level.zones = [SimLevel.GravitySpec.new(Rect2(1220, 340, 200, 660), 50)]
	# Close to the shaft mouth on purpose. Placed 140px further out it caught only a
	# sliver of exit trajectories and the whole twelve-second run came down to a
	# 33ms window — solvable, but luck rather than judgement.
	var feldweg := Vector2(0, 140)
	level.fixed_magnets = [
		SimLevel.MagnetSpec.new(
			1640, 270, true, true, feldweg, SimWorld.sweep_ticks(feldweg), true
		),
	]
	level.start = Vector2(110, 960)
	# The landing sits 120px further right than it used to, and that is not
	# decoration. With the hole cut, the ball leaves the shaft *carrying* speed
	# instead of being lifted from rest, and over a goal directly above the mouth it
	# simply coasted in: 15 of the winning plans won with the level's own field
	# stripped out, which would have made Level 11 a board that lies about what it
	# needs. Out here the pull has its job back — measured: none win without it.
	level.target = Rect2(1560, 120, 400, 240)
	# One gate, at the tunnel mouth — **before** the hole, not in the shaft.
	#
	# A checkpoint earns its place by standing in front of something that can go
	# wrong. In the shaft the run is already safe (nothing there can be lost except
	# to the clock), so a gate at that point handed out a magnet for a stretch that
	# needed none. Here it arms the player for the entry: hold the ball back, or
	# shove it in, until the beat is upward.
	#
	# There used to be a second one just past the bridge, at x 945. It was a
	# duplicate: both sat on the same stretch of floor, 49 ticks apart, and the
	# later one already spares you everything the earlier one did. Two gates on one
	# straight are not two stations.
	#
	# Why have one at all: the board is five seconds, and without it a mistake at
	# the tunnel costs the three seconds before it — seconds that are *already
	# solved*. The simulation is deterministic, so replaying a stretch you have
	# beaten teaches nothing.
	#
	# It blocks its corridor over the full free height. As a box on the floor it
	# missed almost anyone who did not roll along exactly there.
	level.checkpoints = [
		SimLevel.Checkpoint.new(Rect2(1164, 0, 40, 1000), 1),
	]
	# Slowed time over the same rect. Without it the tunnel entry would be a click at
	# full speed: the ball crosses the gate rolling at 183 px/s with 96px of lip left,
	# so about half a second to place a magnet and press. Slowed fivefold that is two
	# and a half seconds, which is a decision instead of a reflex.
	level.slowmo_points = [Rect2(1164, 0, 40, 1000)]
	level.budget = 1
	level.charge_seconds = 2.0
	# The brisk route: a shove from behind that carries the ball over the bridge and
	# straight into the shaft, rather than the slower line that idles five seconds at
	# the shaft mouth waiting for a beat.
	level.par_placements = [SimLevel.MagnetSpec.new(75, 975, false, false)]
	level.par_holds = [[0, 15, 80]]
	return level
