@tool
extends McpTestSuite

## Authoring tool: finds a proven hold plan for a board with checkpoints.
##
## Not a test. It asserts almost nothing and exists to be *run on demand* while
## building a level, the way `test_zz_find_replays.gd` does for single-magnet
## boards. It lives under `tests/` for one reason: the editor is the only place
## project code runs at all (headless produces nothing here, see CLAUDE.md).
##
## [b]How to use it[/b]
##
##  1. Write the geometry in `levels.gd`, leave `par_placements`/`par_holds` empty.
##  2. Set [constant TARGET_LEVEL] below.
##  3. `test_run(suite="author")`.
##  4. Paste what lands in `tools/found_par.txt` into `levels.gd` and the
##     fingerprint line into `test_sim.gd`.
##
## It never writes source itself. Transcription stays by hand, the same as for the
## replay finder, so nothing reaches the campaign that a person has not looked at.
##
## [b]Why this exists[/b]
##
## Levels 13 and 14 were built by writing this search from scratch three times,
## and it was wrong three different ways. Each of those is now a rule the search
## obeys instead of a lesson to be relearned:
##
##  - **A win only counts on the last stage.** Accepting one earlier let a single
##    magnet fling the ball past two platforms, which made the later ones
##    decoration and broke criterion 1.
##  - **The first hit is usually the knife edge of its window.** Taking it gave a
##    par with a one-tick fairness window, twice. A move now has to survive its
##    hold being shifted by ±[constant SLACK].
##  - **A hold may start later than its magnet is born.** On a climb it must: the
##    ball is still coming down when it crosses a gate, and pulling then drags it
##    off the platform it was about to land on.
##  - **The segment rule belongs in the search.** A chain came out with a 39-tick
##    leg and was rejected afterwards; now a candidate that lands too soon is never
##    chosen.
##  - **The opening never starts at tick 0.** With a magnet already in lifting
##    range the ball is snatched up before it has settled, so a three-tick delay
##    produces a *different* run rather than a delayed one — measured on Level 14,
##    gate 1 moved from tick 105 to 99, and the fairness window collapsed to one.

## The level to search. Change this, then run the suite.
const TARGET_LEVEL := 15

const REPORT := "res://tools/found_par.txt"  # the pasteable plan and the verdict


## How far apart the tried magnet positions are, in pixels.
##
## 50 is the compromise the search actually needs: at 75 the opening of Level 14
## fell between two grid points and the search reported "impossible" for a board
## that was fine, and at 30 a single stage ran past the twenty seconds that drop
## the editor session.
const GRID_STEP := 50.0

## Floor for how many ticks a move has to tolerate being early or late.
##
## The real figure comes from [method _slack]: a candidate that survives being
## shifted by ±s has a window of at least 2s+1, so the board's own
## [member SimLevel.min_timing_window] decides how much slack is enough. At a flat
## 6 the search was free to accept a 13-tick window on a board asking for 15, and
## it did — twice, with the second attempt finding a 7 where the first had found
## a 13. A greedy search takes the first thing that passes, so the bar it passes
## has to be the bar that ships.
const SLACK := 6

## The opening waits this long before it may pull, so the ball is resting rather
## than mid-bounce. See the note above about tick 0.
const SETTLE := 20

## Bounds a stretch between two gates has to fall inside — the same numbers
## `test_the_par_passes_every_checkpoint_in_order` enforces, with a little margin
## on the low side so a plan does not scrape through by one tick.
const SEGMENT_MIN := 48
const SEGMENT_MAX := 470

## Hold offsets after the magnet is born, and hold lengths. Longest first: a
## slower, higher arc lands later, which keeps the stretch between two gates above
## the minimum. Shortest-first produced a 39-tick leg.
const WAITS: Array[int] = [0, 25, 50]
const LENGTHS: Array[int] = [92, 76, 60, 44, 28]

## Wall clock a single test method may spend. The runner services the editor only
## *between* tests, so a body past roughly twenty seconds takes the session with
## it — that happened twice while building Level 14. Hitting this budget is
## reported as an unfinished search, not as a failure of the board.
const BUDGET_MS := 14000

## The chain found so far: [x, y, attract, born, on, off] per magnet. A `static`
## so it survives from one test method to the next; the stages have to be separate
## methods to stay under the budget above.
static var PLAN: Array = []
static var NOTES: Array[String] = []

## Where the next slice picks up: which stage, and how far into its ring sweep.
##
## [member BORN] is the tick the stage's magnet is born on, −1 until the stage has
## been entered. [member STALLED] means a stage was searched out and diagnosed, so
## there is nothing left for later slices to do.
static var STAGE := 0
static var RING := 0
static var CELL := 0
static var BORN := -1
static var STALLED := false

## Where each solved stage's answer was found, so a later stage that runs out of
## room can send the search back to look for a different one.
static var TRAIL: Array = []


func suite_name() -> String:
	return "author"


# --- the run ----------------------------------------------------------------

func test_a_check_the_board() -> void:
	PLAN = []
	NOTES = []
	STAGE = 0
	RING = 0
	CELL = 0
	BORN = -1
	STALLED = false
	TRAIL = []
	var level := Levels.by_id(TARGET_LEVEL)
	if level == null:
		_finish(["Level %d gibt es nicht" % TARGET_LEVEL])
		return
	var pull := level.magnet_strength if level.magnet_strength > 0.0 else SimWorld.MAGNET_STRENGTH
	var field := level.field_strength if level.field_strength > 0.0 else pull
	NOTES.append("Level %d \"%s\" — %d Tore, Budget %d, Magnet %d, Fremdfeld %d"
		% [level.id, level.title, level.checkpoints.size(), level.budget,
			int(pull), int(field)])
	if level.budget != 1:
		NOTES.append("ABBRUCH: gesucht wird ein Magnet pro Stufe, dieses Brett hat Budget %d."
			% level.budget)
		NOTES.append("  Fuer Bretter ohne Tore ist test_zz_find_replays.gd zustaendig.")
		PLAN = [null]  # marks the chain as broken so the stages skip
	_write(NOTES)
	assert_true(true)


## Twenty slices of [constant BUDGET_MS], not one method per stage.
##
## The runner services the editor only *between* tests, so a body past roughly
## twenty seconds takes the session with it — that is what the budget is for. One
## method per stage then quietly caps a *stage* at fourteen seconds, and on a
## journey board that is not enough: Level 15's wall climb is born 600 ticks in,
## so every candidate replays those 600 ticks before it can say anything, and the
## stage ran out twice in a row having swept maybe half its rings. The report said
## "Zeitbudget aufgebraucht", which was true and useless.
##
## A slice resumes exactly where the last one stopped — same stage, same ring,
## same cell — so the budget belongs to the *search* and not to a stage. Twenty of
## them is 168 seconds against the runner's 300, and once the chain is complete
## the rest return immediately.
func test_b01_slice() -> void:
	_slice()


func test_b02_slice() -> void:
	_slice()


func test_b03_slice() -> void:
	_slice()


func test_b04_slice() -> void:
	_slice()


func test_b05_slice() -> void:
	_slice()


func test_b06_slice() -> void:
	_slice()


func test_b07_slice() -> void:
	_slice()


func test_b08_slice() -> void:
	_slice()


func test_b09_slice() -> void:
	_slice()


func test_b10_slice() -> void:
	_slice()


func test_b11_slice() -> void:
	_slice()


func test_b12_slice() -> void:
	_slice()


func test_b13_slice() -> void:
	_slice()


func test_b14_slice() -> void:
	_slice()


func test_b15_slice() -> void:
	_slice()


func test_b16_slice() -> void:
	_slice()


func test_b17_slice() -> void:
	_slice()


func test_b18_slice() -> void:
	_slice()


func test_b19_slice() -> void:
	_slice()


func test_b20_slice() -> void:
	_slice()



func test_f_verdict() -> void:
	var level := Levels.by_id(TARGET_LEVEL)
	if level == null or PLAN.is_empty() or PLAN[0] == null:
		NOTES.append("")
		NOTES.append("Kein Plan gefunden.")
		_write(NOTES)
		assert_true(true)
		return
	if PLAN.size() < level.checkpoints.size() + 1:
		NOTES.append("")
		NOTES.append("Kette unvollstaendig: %d von %d Stufen. Siehe Diagnose oben."
			% [PLAN.size(), level.checkpoints.size() + 1])
		_write(NOTES)
		assert_true(true)
		return

	var final := _run(level, PLAN, _horizon(level))
	NOTES.append("")
	NOTES.append("--- Urteil ---")
	NOTES.append("Lauf: %s nach %d Ticks, Hash %d, Tore %s"
		% [_outcome(final.outcome), final.tick_count, final.state_hash(),
			str(final.checkpoint_ticks)])

	var faults: Array[String] = []
	if final.outcome != SimWorld.Outcome.WON:
		faults.append("der Plan gewinnt nicht")

	# Criterion 1: every magnet has to carry something.
	for drop in PLAN.size():
		var thinned: Array = []
		for i in PLAN.size():
			var m: Array = (PLAN[i] as Array).duplicate()
			if i == drop:
				m[4] = 999999
				m[5] = 999999
			thinned.append(m)
		if _run(level, thinned, _horizon(level)).outcome == SimWorld.Outcome.WON:
			faults.append("Magnet %d traegt nichts — der Lauf gewinnt auch ohne ihn" % (drop + 1))

	# The stretches between gates.
	var previous := 0
	for i in final.checkpoint_ticks.size():
		var at: int = final.checkpoint_ticks[i]
		if at < 0:
			faults.append("Tor %d liegt nicht auf dem Weg" % (i + 1))
			continue
		var span := at - previous
		if span < SEGMENT_MIN or span > SEGMENT_MAX:
			faults.append("Abschnitt vor Tor %d dauert %d Ticks (erlaubt %d..%d)"
				% [i + 1, span, SEGMENT_MIN, SEGMENT_MAX])
		previous = at
	var tail := final.tick_count - previous
	if tail > SEGMENT_MAX:
		faults.append("letzter Abschnitt dauert %d Ticks" % tail)

	# Criterion 6, measured the way test_sim.gd measures it.
	# Per station, which is what a player on a gated board has to hit.
	var windows := _segment_windows(level)
	var worst := 9999
	var shown: Array[String] = []
	for k in windows.size():
		shown.append("%d:%d" % [k + 1, windows[k]])
		worst = mini(worst, windows[k])
	NOTES.append("Fairness je Station: %s — schwaechste %d (verlangt %d)"
		% [" ".join(shown), worst, level.min_timing_window])
	if worst < level.min_timing_window:
		faults.append("Station %d gibt nur %d Ticks (Schwelle %d)"
			% [windows.find(worst) + 1, worst, level.min_timing_window])

	# And end to end, which is what one clean run costs. Not a criterion on a
	# gated board — it is the product of the numbers above, and nobody has to hit
	# a product — but a useful difficulty reading.
	var window := _timing_window(level)
	NOTES.append("Fenster fuer einen Lauf ohne Rueckfall: %d Ticks" % window)
	for line: String in _window_profile(level):
		NOTES.append("  " + line)

	if faults.is_empty():
		NOTES.append("Alle Kriterien erfuellt.")
	else:
		NOTES.append("VERLETZT:")
		for fault: String in faults:
			NOTES.append("  - " + fault)

	NOTES.append("")
	NOTES.append("--- in levels.gd einfuegen ---")
	NOTES.append("\tlevel.par_placements = [")
	for m: Array in PLAN:
		NOTES.append("\t\tSimLevel.MagnetSpec.new(%d, %d, %s, false, Vector2.ZERO, 1, false, %d),"
			% [m[0], m[1], "true" if m[2] else "false", m[3]])
	NOTES.append("\t]")
	var holds: Array[String] = []
	for i in PLAN.size():
		var m: Array = PLAN[i]
		holds.append("[%d, %d, %d]" % [i, m[4], m[5]])
	NOTES.append("\tlevel.par_holds = [%s]" % ", ".join(holds))
	NOTES.append("")
	NOTES.append("--- in test_sim.gd, PAR_FINGERPRINTS ---")
	NOTES.append("\t[%d, %d, %d]," % [level.id, final.tick_count, final.state_hash()])
	_write(NOTES)
	assert_true(true)


# --- one stage --------------------------------------------------------------

## Advances the chain by up to [constant BUDGET_MS] of wall clock.
##
## Picks up at [member STAGE] / [member RING] / [member CELL], which is whatever
## the previous slice left behind. Three ways out: the stage is solved and the
## chain moves on, the slice runs out of time and the next one continues, or the
## whole sweep is exhausted — which is the only case worth a word in the report,
## and it gets a diagnosis rather than a shrug.
func _slice() -> void:
	var level := Levels.by_id(TARGET_LEVEL)
	if level == null or (not PLAN.is_empty() and PLAN[0] == null) or STALLED:
		assert_true(true)
		return
	if STAGE > level.checkpoints.size():
		assert_true(true)
		return

	if BORN < 0:
		BORN = 0
		if STAGE > 0:
			var probe := _run(level, PLAN, _horizon(level))
			BORN = probe.checkpoint_ticks[STAGE - 1]
			if BORN < 0:
				NOTES.append("Stufe %d: Tor %d wird nie durchquert (Kugel endete bei %d,%d)"
					% [STAGE + 1, STAGE, probe.ball_x, probe.ball_y])
				STALLED = true
				_write(NOTES)
				assert_true(true)
				return

	var deadline := Time.get_ticks_msec() + BUDGET_MS
	var result := _search(level, STAGE, BORN, RING, CELL, deadline, true)
	RING = int(result["ring"])
	CELL = int(result["cell"])

	var found: Array = result["found"]
	if not found.is_empty():
		PLAN.append(found)
		TRAIL.append([RING, CELL])
		NOTES.append("Stufe %d: (%d,%d) %s, geboren %d, halten %d..%d"
			% [STAGE + 1, found[0], found[1], "zieht" if found[2] else "stoesst",
				found[3], found[4], found[5]])
		STAGE += 1
		RING = 0
		CELL = 0
		BORN = -1
		_write(NOTES)
		assert_true(true)
		return

	if not bool(result["exhausted"]):
		# Out of slice, not out of answers. The next one carries on from here.
		assert_true(true)
		return

	# Out of positions. Before declaring the board at fault, take back the
	# previous stage's answer and keep looking for a different one.
	#
	# The search is greedy: it takes the nearest position that survives its own
	# shifts, and nearest is not the same as *leaving the run somewhere useful*.
	# Levels 13 and 14 both failed exactly here — a perfectly robust opening that
	# put the ball where the second station had no robust answer at all — and the
	# report blamed the geometry for what was a choice three lines earlier.
	if STAGE > 0:
		var previous: Array = PLAN.pop_back()
		var at: Array = TRAIL.pop_back()
		NOTES.append("Stufe %d: nichts Robustes von hier aus — Stufe %d wird neu gesucht"
			% [STAGE + 1, STAGE])
		NOTES.append("  (verworfen: (%d,%d) halten %d..%d)"
			% [previous[0], previous[1], previous[4], previous[5]])
		STAGE -= 1
		RING = int(at[0])
		CELL = int(at[1]) + 1
		BORN = -1
		_write(NOTES)
		assert_true(true)
		return

	# Stage one is out of positions, so there is nothing left to take back. Say
	# *why*, which is the whole point of the tool. There is time left for the
	# loose pass by definition: a sweep that used the budget would not have
	# finished.
	NOTES.append("Stufe %d: nichts gefunden (Magnet geboren bei %d)" % [STAGE + 1, BORN])
	var loose: Array = _search(level, STAGE, BORN, 0, 0, deadline, false)["found"]
	if loose.is_empty():
		NOTES.append("  Auch ohne Robustheits- und Abschnittsregel nichts: das Ziel ist von hier")
		NOTES.append("  aus **gar nicht erreichbar**. Die Geometrie ist schuld, nicht die Suche.")
		NOTES.append("  " + _how_close(level, STAGE, BORN))
	else:
		NOTES.append("  Erreichbar mit (%d,%d) %s halten %d..%d — aber die Loesung ist zu knapp:"
			% [loose[0], loose[1], "zieht" if loose[2] else "stoesst", loose[4], loose[5]])
		NOTES.append("  sie haelt die +-%d-Tick-Verschiebung oder die Abschnittslaenge nicht."
			% _slack(level))
		NOTES.append("  Das Brett ist loesbar, aber an dieser Stelle zu scharf geschnitten.")
	STALLED = true
	_write(NOTES)
	assert_true(true)


## Sweeps magnet positions around wherever the ball is when the stage begins,
## resuming at ring [param from_ring], cell [param from_cell].
##
## The box is one [constant SimWorld.MAGNET_RADIUS] in each direction: outside
## that a magnet does nothing at the moment it is born, so there is no point
## trying it. [param strict] turns the robustness and segment rules on; the loose
## pass exists only to tell an impossible board from a tight one.
##
## Returns `found` (empty if not), plus the `ring`/`cell` to resume at and whether
## the sweep is `exhausted`. The deadline is checked per *cell* rather than per
## ring: an outer ring is thirty-odd cells and on a long board one of those alone
## can outlast a slice.
func _search(level: SimLevel, stage: int, born: int, from_ring: int, from_cell: int,
		deadline: int, strict: bool) -> Dictionary:
	var probe := _run(level, PLAN, born if born > 0 else 1)
	var ball := Vector2(probe.ball_x, probe.ball_y)
	var steps := int(SimWorld.MAGNET_RADIUS / GRID_STEP)
	var waits: Array[int] = WAITS.duplicate()
	if stage == 0:
		# The opening lets the ball settle first; see the note at the top.
		waits = [SETTLE, SETTLE + 20, SETTLE + 45]

	# Ring by ring outwards from the ball, not row by row from a corner. A magnet
	# close to the ball is both the likelier answer and the more forgiving one, and
	# with a time budget the order decides what gets tried at all: scanning from the
	# corner spent the whole budget on positions 500px away and reported "nothing
	# found" for a stage that has answers.
	for ring in range(from_ring, steps + 1):
		var cells := _ring(ball, ring, steps)
		for c in range(from_cell if ring == from_ring else 0, cells.size()):
			if Time.get_ticks_msec() >= deadline:
				return {"found": [], "ring": ring, "cell": c, "exhausted": false}
			var at: Vector2 = cells[c]
			if _blocked(level, at):
				continue
			for pol in 2:
				for wait: int in waits:
					for length: int in LENGTHS:
						var on := born + wait
						if not _reaches(level, _with(at, pol == 0, born, on, length), stage, born, strict):
							continue
						var hit := {
							"found": [at.x, at.y, pol == 0, born, on, on + length],
							"ring": ring, "cell": c, "exhausted": true,
						}
						if not strict:
							return hit
						# A whole run of min_timing_window consecutive shifts
						# has to win, and every one of them has to be a shift a
						# player could actually make.
						#
						# Two ways this was wrong before. Testing only the two ends
						# let a comb through — Level 13 came back with a station of
						# 8 from a candidate that survived −7 and +7 and lost
						# several shifts in between, and nobody can aim at a comb.
						# And clamping a shift to the magnet's birth made the
						# negative half of the range a copy of shift zero, so a
						# hold that starts the tick its magnet appears was checked
						# forwards only: "survives ±7" meant "survives 0..+7",
						# which is exactly the 8 that came back.
						#
						# So the run starts as early as the birth allows and always
						# covers the full width.
						var lo: int = maxi(-_slack(level), born - on)
						var solid := true
						for shift: int in range(lo, lo + level.min_timing_window):
							if not _reaches(
								level, _with(at, pol == 0, born, on + shift, length),
								stage, born, true
							):
								solid = false
								break
						if solid:
							return hit
	return {"found": [], "ring": steps + 1, "cell": 0, "exhausted": true}


## Whether [param plan] gets the run to the end of stage [param stage].
##
## For every stage but the last that means crossing the next gate — and crossing
## it far enough after the previous one. Dying *after* the gate is fine and is
## exactly what a checkpoint is for; only the last stage has to win.
func _reaches(level: SimLevel, plan: Array, stage: int, born: int, strict: bool) -> bool:
	# Every stage is over within SEGMENT_MAX of its magnet's birth — a gate reached
	# later than that is rejected, and so is a win in a tail longer than that. The
	# ticks beyond it therefore teach the search nothing and cost it everything.
	#
	# Measured, on this board: without the cap the last stage burned all 14 s of
	# BUDGET_MS and found nothing. The reason is the foreign field — a candidate
	# that fails by parking the ball against the wall keeps it alive for the full
	# 2400-tick horizon, so every wrong answer cost forty times what a right one
	# does. On a five-second board with an open floor this never showed up, because
	# a wrong answer there falls out of the world in half a second.
	#
	# The loose pass keeps the full horizon: its whole job is telling "unreachable"
	# apart from "reachable, but too late to ship".
	var cap := _horizon(level)
	if strict:
		cap = mini(cap, born + SEGMENT_MAX + 1)
	var world := _run(level, plan, cap)
	if stage >= level.checkpoints.size():
		return world.outcome == SimWorld.Outcome.WON
	var gate: int = world.checkpoint_ticks[stage]
	if gate < 0:
		return false
	if not strict:
		return true
	var span := gate - born
	return span >= SEGMENT_MIN and span <= SEGMENT_MAX


## How far the ball got, for the report when a stage is impossible.
func _how_close(level: SimLevel, stage: int, born: int) -> String:
	var goal := "das Ziel"
	if stage < level.checkpoints.size():
		var rect: Rect2 = (level.checkpoints[stage] as SimLevel.Checkpoint).rect
		goal = "Tor %d bei (%d..%d, %d..%d)" % [
			stage + 1, rect.position.x, rect.end.x, rect.position.y, rect.end.y
		]
	else:
		goal = "das Ziel bei (%d..%d, %d..%d)" % [
			level.target.position.x, level.target.end.x,
			level.target.position.y, level.target.end.y
		]
	var probe := _run(level, PLAN, born if born > 0 else 1)
	return "Kugel steht zu Beginn der Stufe bei (%d,%d); zu erreichen waere %s."  % [
		probe.ball_x, probe.ball_y, goal
	]


# --- criteria the finished chain has to meet --------------------------------

## The leeway each station gives on its own hold, station by station.
##
## This is the number a player on a gated board actually has to hit. The
## whole-chain measure asks a shifted opening to carry all the way to the goal,
## and on five stations that reports the *product* of five tolerances — Level 15
## came out at 1 tick with no station worse than about half its range. Nobody has
## to hit that product: miss at the shaft and the gate before it hands the run
## back, so the unit that gets retried is the segment.
##
## Stages before the one being measured stay at par, which makes the run up to
## that point identical and keeps the magnet's birth tick valid. Stages after it
## are dropped entirely — a later magnet spawning mid-measurement would perturb
## the very stretch being measured.
func _segment_windows(level: SimLevel) -> Array[int]:
	var out: Array[int] = []
	for k in PLAN.size():
		var wins: Array[int] = []
		for d in range(-20, 21):
			var on: int = int((PLAN[k] as Array)[4]) + d
			if on < int((PLAN[k] as Array)[3]):
				continue
			var plan: Array = []
			for i in range(0, k + 1):
				plan.append((PLAN[i] as Array).duplicate())
			var length: int = int((PLAN[k] as Array)[5]) - int((PLAN[k] as Array)[4])
			(plan[k] as Array)[4] = on
			(plan[k] as Array)[5] = on + length
			var born: int = int((PLAN[k] as Array)[3])
			var world := _run(level, plan, mini(_horizon(level), born + SEGMENT_MAX + 1))
			var ok := false
			if k >= level.checkpoints.size():
				ok = world.outcome == SimWorld.Outcome.WON
			else:
				ok = world.checkpoint_ticks[k] >= 0
			if ok:
				wins.append(d)
		out.append(_longest_run(wins))
	return out


## Longest stretch of consecutive integers in [param values].
##
## Consecutive, because nobody can aim at a comb: Level 8 has 24 winning moments
## but in little clumps, only 6 of them in a row.
func _longest_run(values: Array[int]) -> int:
	var best := 0
	var run := 0
	var previous := -999
	for d: int in values:
		run = run + 1 if d == previous + 1 else 1
		previous = d
		if run > best:
			best = run
	return best


## Which stage the chain loses, shift by shift.
##
## The window is one number and a chained board needs two: a plan can have four
## forgiving stations and one that only works on the tick it was found on, and
## only this says which. Each row is a delay of the first hold and how far the run
## then got — so a column of "Stufe 2" points at the shaft, and a scatter points
## at the plan being lucky rather than robust.
func _window_profile(level: SimLevel) -> Array[String]:
	var rows: Array[String] = []
	var reached: Array[int] = []
	for d in range(-12, 13):
		if int((PLAN[0] as Array)[4]) + d < 0:
			continue
		var shifted := _rechain(level, d)
		var world := _run(level, shifted, _horizon(level))
		var got := 0
		for at: int in world.checkpoint_ticks:
			if at >= 0:
				got += 1
		if world.outcome == SimWorld.Outcome.WON:
			got = level.checkpoints.size() + 1
		reached.append(got)
	var counts: Dictionary = {}
	for got: int in reached:
		counts[got] = int(counts.get(got, 0)) + 1
	rows.append("Verschiebung -12..+12, wie weit der Lauf kommt:")
	for stage in range(0, level.checkpoints.size() + 2):
		if not counts.has(stage):
			continue
		var what := "gewinnt" if stage > level.checkpoints.size() else ("bis Tor %d" % stage)
		if stage == 0:
			what = "kein Tor"
		rows.append("  %2dx %s" % [int(counts[stage]), what])
	return rows


## The plan with its first hold delayed by [param d], and every later magnet reborn
## wherever its gate actually falls — the only version of the plan a player could
## have made.
func _rechain(level: SimLevel, d: int) -> Array:
	var shifted: Array = []
	for m: Array in PLAN:
		shifted.append(m.duplicate())
	(shifted[0] as Array)[4] = int((PLAN[0] as Array)[4]) + d
	(shifted[0] as Array)[5] = int((PLAN[0] as Array)[5]) + d
	for stage in range(1, shifted.size()):
		var probe := _run(level, shifted, _horizon(level))
		if stage - 1 >= probe.checkpoint_ticks.size():
			break
		var gate: int = probe.checkpoint_ticks[stage - 1]
		if gate < 0:
			break
		var original: Array = PLAN[stage]
		var offset: int = int(original[4]) - int(original[3])
		var length: int = int(original[5]) - int(original[4])
		var entry: Array = shifted[stage]
		entry[3] = gate
		entry[4] = gate + offset
		entry[5] = gate + offset + length
	return shifted


## The longest run of consecutive delays of the first hold that still wins.
##
## The same measurement `test_sim.gd` makes, repeated here on purpose: catching a
## knife-edge plan *before* it is pasted is the point of the tool. That file stays
## the authority — if the two ever disagree, believe the test.
func _timing_window(level: SimLevel) -> int:
	var wins: Array[int] = []
	for d in range(-20, 21):
		if int((PLAN[0] as Array)[4]) + d < 0:
			continue
		var shifted: Array = []
		for m: Array in PLAN:
			shifted.append(m.duplicate())
		# Everything moves together, and the magnets earned at gates are reborn
		# wherever their gate actually falls — a plan whose later births stayed put
		# is one no player could make.
		(shifted[0] as Array)[4] = int((PLAN[0] as Array)[4]) + d
		(shifted[0] as Array)[5] = int((PLAN[0] as Array)[5]) + d
		var ok := true
		for stage in range(1, shifted.size()):
			var probe := _run(level, shifted, _horizon(level))
			if stage - 1 >= probe.checkpoint_ticks.size():
				ok = false
				break
			var gate: int = probe.checkpoint_ticks[stage - 1]
			if gate < 0:
				ok = false
				break
			var original: Array = PLAN[stage]
			var offset: int = int(original[4]) - int(original[3])
			var length: int = int(original[5]) - int(original[4])
			var entry: Array = shifted[stage]
			entry[3] = gate
			entry[4] = gate + offset
			entry[5] = gate + offset + length
		if ok and _run(level, shifted, _horizon(level)).outcome == SimWorld.Outcome.WON:
			wins.append(d)
	var best := 0
	var run := 0
	var previous := -999
	for d: int in wins:
		run = run + 1 if d == previous + 1 else 1
		previous = d
		if run > best:
			best = run
	return best


# --- plumbing ---------------------------------------------------------------

## Ticks a move must tolerate on this board: enough that surviving ±s implies a
## window of at least [member SimLevel.min_timing_window].
func _slack(level: SimLevel) -> int:
	return maxi(SLACK, (level.min_timing_window - 1) / 2)


## The cells whose ring index is [param ring], nearest-first order. Corners beyond
## [constant SimWorld.MAGNET_RADIUS] are dropped: a magnet further away than that
## does nothing at the moment it is born, so trying it is spent budget.
func _ring(centre: Vector2, ring: int, steps: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	# Whole pixels, because the report prints whole pixels. The sweep is centred on
	# wherever the ball happens to be, which is a fraction, so the tried positions
	# were fractions and the pasted plan was a *different* plan — Level 15's par
	# reproduced at 688 ticks in the tool and ran out the clock in `test_sim.gd`,
	# one gate crossed a tick early. What is verified has to be what is written
	# down. The game rounds a dragged path endpoint for the same reason.
	centre = Vector2(round(centre.x), round(centre.y))
	for col in range(-ring, ring + 1):
		for row in range(-ring, ring + 1):
			if maxi(absi(col), absi(row)) != ring:
				continue
			var offset := Vector2(float(col) * GRID_STEP, float(row) * GRID_STEP)
			if offset.length() > SimWorld.MAGNET_RADIUS:
				continue
			out.append(centre + offset)
	return out


func _with(at: Vector2, pull: bool, born: int, on: int, length: int) -> Array:
	var trial: Array = []
	for m: Array in PLAN:
		trial.append(m.duplicate())
	trial.append([at.x, at.y, pull, born, on, on + length])
	return trial


## This board's run horizon — the one number the game, `test_sim.gd` and this
## search have to agree on. A journey board sets its own; see SimLevel.max_ticks.
func _horizon(level: SimLevel) -> int:
	return level.max_ticks if level.max_ticks > 0 else SimWorld.MAX_RUN_TICKS


func _run(level: SimLevel, plan: Array, ticks: int) -> SimWorld:
	var placed: Array = []
	for m: Array in plan:
		placed.append(SimLevel.MagnetSpec.new(
			m[0], m[1], m[2], false, Vector2.ZERO, 1, false, int(m[3])
		))
	var world := SimWorld.new()
	world.setup(level, placed)
	for t in ticks:
		var mask := 0
		for i in plan.size():
			var m: Array = plan[i]
			if t >= int(m[4]) and t < int(m[5]):
				mask |= 1 << i
		world.step(mask)
		if world.outcome != SimWorld.Outcome.RUNNING:
			break
	return world


func _blocked(level: SimLevel, at: Vector2) -> bool:
	if not level.arena.has_point(at):
		return true
	for solid: Rect2 in level.solids:
		if solid.grow(SimWorld.BALL_RADIUS + 6.0).has_point(at):
			return true
	for mover: SimLevel.MoverSpec in level.movers:
		if mover.swept_rect().grow(SimWorld.BALL_RADIUS + 6.0).has_point(at):
			return true
	return false


func _outcome(code: int) -> String:
	if code == SimWorld.Outcome.WON:
		return "gewonnen"
	if code == SimWorld.Outcome.LOST:
		return "verloren"
	return "Zeit abgelaufen"


func _finish(lines: Array) -> void:
	_write(lines)
	assert_true(true)


func _write(lines: Array) -> void:
	var file := FileAccess.open(REPORT, FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()
