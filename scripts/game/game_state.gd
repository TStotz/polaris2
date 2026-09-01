class_name GameState
extends Node

## Live, mutable state of one played level, and the driver of the simulation.
##
## All movement goes through [Movement] — the same functions the [Solver] and the
## offline pipeline use — so what the player watches and what the solver proved
## are the same run. This class owns *when* things move; it never decides *where*.
##
## [b]The loop is step-by-step.[/b] Clicking a placed magnet fires it immediately
## and the balls move; [method undo] takes the move back. There is no queue to
## assemble and no attempt limit. The earlier build collected an activation order
## and played it back on a keypress, which meant every interesting decision
## happened in the player's head with the game showing nothing until they
## committed — and then rationed those commits five per level. Firing on click
## turns the same puzzle into a conversation with the board, and the sequence is
## still the thing being solved.
##
## [b]Placement resets the run.[/b] The rules treat magnets as solid blockers for
## the whole run, and that is the board the shipped solutions were verified on. So
## adding or removing one rewinds the balls to their starts rather than letting
## the player smuggle a magnet in mid-sequence and play on a board no solver ever
## checked.

## Emitted whenever board state changed and the view should redraw.
signal changed

## Emitted when the status line changed. [param kind] is a [enum MessageKind].
signal message_changed(text: String, kind: MessageKind)

## Emitted the moment the level is won.
signal solved_level

## Emitted for each activation as it fires, so the view can punch up the magnet.
signal activation_started(cell: Vector2i)

## Emitted when a ball finishes a leg, so the view can thump on impact.
signal ball_landed(cell: Vector2i, travelled: int)

## Emitted when plates flipped gates. [param channels] is the bitmask that just
## changed, so the view can animate exactly those gates.
signal gates_toggled(channels: int)

## The currently selected placement tool.
enum Tool { PLUS, MINUS, ERASE }

## Tone of the status message, used by the UI to colour it.
enum MessageKind { NORMAL, WIN, FAIL }

## Milliseconds per straight leg of a slide.
const STEP_MS := 150

## Pause for an activation that moves nothing — without it the step would be
## invisible and the player could not tell a dud magnet from a skipped one.
const IDLE_MS := 180

const FLASH_MS := 1600

var puzzle: Puzzle

## Minimal magnet count the offline solver proved for this board — the par the
## star rating is scored against. 0 when unknown (a hand-made board).
var par: int = 0

## Placed magnets, keyed by cell (cell -> [enum Magnet.Type]).
var magnets: Dictionary = {}

## Cells fired so far, in order. Doubles as the single-use ledger.
var fired: Array = []

## Waypoints touched so far in this run (subset of [member Puzzle.waypoints]).
var collected_waypoints: Dictionary = {}

## Bitmask of gate channels flipped from their authored state. Every movement
## call takes it, which is what lets one activation be judged against exactly one
## board — see [Movement].
var gate_mask: int = 0

var selected_tool: Tool = Tool.PLUS
var solved: bool = false
var animating: bool = false

## How many times the player rewound or restarted. Not scored — it exists so the
## UI can stay quiet about it. Experimenting is the game, not a failure.
var rewinds: int = 0

## Live positions of every ball, index-aligned with [method Puzzle.ball_starts].
var ball_positions: Array = []

## Undo stack of `{balls, collected, fired, gates}` snapshots, one per fired
## magnet.
var _history: Array = []

var _message := ""
var _message_kind: MessageKind = MessageKind.NORMAL
var _flash_token := 0


func setup(level_puzzle: Puzzle, minimal_magnets: int = 0) -> void:
	puzzle = level_puzzle
	par = minimal_magnets
	magnets.clear()
	selected_tool = Tool.PLUS
	solved = false
	animating = false
	rewinds = 0
	_rewind_to_start()
	_set_message(_opening_hint(), MessageKind.NORMAL)
	changed.emit()


func _opening_hint() -> String:
	return "Setze Magnete. Fahre über einen, um seinen Zug zu sehen — klicke, um ihn auszulösen."


func message() -> String:
	return _message


func message_kind() -> MessageKind:
	return _message_kind


## The primary ball's position — the single-ball shorthand.
func ball_pos() -> Vector2i:
	return ball_positions[0]


func all_waypoints_collected() -> bool:
	return collected_waypoints.size() >= puzzle.waypoints.size()


## How many balls currently rest on their own target.
func balls_home() -> int:
	var targets := puzzle.ball_targets()
	var n := 0
	for i in ball_positions.size():
		if ball_positions[i] == targets[i]:
			n += 1
	return n


## The win condition: every ball on its target and every waypoint collected.
func reached_goal() -> bool:
	return balls_home() == puzzle.ball_count() and all_waypoints_collected()


func remaining_of(type: Magnet.Type) -> int:
	var budget := puzzle.plus_budget if type == Magnet.Type.PLUS else puzzle.minus_budget
	var placed := 0
	for t: Magnet.Type in magnets.values():
		if t == type:
			placed += 1
	return budget - placed


## Magnets as an [Array] of [Magnet], for movement consumption.
func magnet_list() -> Array:
	var out: Array = []
	for cell: Vector2i in magnets:
		out.append(Magnet.new(cell, magnets[cell]))
	return out


## True when this magnet has already fired and the puzzle forbids repeats.
func is_spent(cell: Vector2i) -> bool:
	return puzzle.single_use and fired.has(cell)


## Whether firing [param cell] right now is a legal move.
func can_fire(cell: Vector2i) -> bool:
	return not animating and not solved and magnets.has(cell) and not is_spent(cell)


## Stars for the finished level, scored purely on efficiency: 3 for matching the
## proven minimum, 2 for one magnet over, 1 for solving it at all.
##
## Deliberately not scored on attempts or undos. Rationing experiments is what
## made the earlier build joyless — the challenge is finding the *tight* answer,
## and that survives any amount of fiddling to reach it.
func stars() -> int:
	if not solved:
		return 0
	if par <= 0:
		return 3
	var used := magnets.size()
	if used <= par:
		return 3
	if used <= par + 1:
		return 2
	return 1


# --- Placement --------------------------------------------------------------

func select_tool(tool: Tool) -> void:
	if selected_tool == tool:
		return
	selected_tool = tool
	changed.emit()


## Left-click on a cell: fire the magnet standing there, or place a new one.
func click_cell(cell: Vector2i) -> void:
	if animating or solved:
		return

	if magnets.has(cell):
		if selected_tool == Tool.ERASE:
			erase_cell(cell)
			return
		# Clicking a placed magnet *always* fires it, whatever tool is selected.
		#
		# An earlier version swapped its polarity when the other tool happened to
		# be active. That silently broke the promise the hover preview makes: the
		# dashed line says "this is the move", so the click has to be that move.
		# Getting a rewind and a flipped magnet instead is indistinguishable from
		# a bug. Polarity is changed by removing the magnet and placing the other.
		if is_spent(cell):
			_flash("Einweg-Magnet: der hat seinen Zug schon gemacht.")
			return
		fire(cell)
		return

	if selected_tool == Tool.ERASE:
		return
	place_magnet(cell)


func place_magnet(cell: Vector2i) -> void:
	if animating or solved:
		return
	if not puzzle.in_bounds(cell) or puzzle.is_wall(cell):
		return
	if puzzle.target_index_at(cell) != -1:
		_flash("Auf einem Zielfeld kann kein Magnet stehen.")
		return
	if puzzle.start_index_at(cell) != -1:
		_flash("Auf einem Startfeld kann kein Magnet stehen.")
		return
	if puzzle.is_waypoint(cell):
		_flash("Auf einem Kristall kann kein Magnet stehen.")
		return
	if puzzle.is_deflector(cell):
		_flash("Auf einem Deflektor kann kein Magnet stehen.")
		return

	var type := Magnet.Type.PLUS if selected_tool == Tool.PLUS else Magnet.Type.MINUS
	if remaining_of(type) <= 0:
		_flash("Keine %s-Magnete übrig." % _label(type))
		return

	magnets[cell] = type
	_rewind_to_start()
	changed.emit()


## Replaces the whole placement at once, e.g. from the level's proven solution.
## Like any edit, it rewinds the run — so the player still has to work out the
## order, which is the half of the puzzle worth keeping.
func apply_placement(placement: Array) -> void:
	if animating:
		return
	magnets.clear()
	for magnet: Magnet in placement:
		magnets[magnet.pos] = magnet.type
	_rewind_to_start()
	changed.emit()


## Removes the magnet on [param cell]. Like any edit, this rewinds the run.
func erase_cell(cell: Vector2i) -> void:
	if animating or solved or not magnets.has(cell):
		return
	magnets.erase(cell)
	_rewind_to_start()
	changed.emit()


# --- The move loop ----------------------------------------------------------

## Fires the magnet on [param cell]: every ball on its line slides at once,
## animated leg by leg. The move is pushed onto the undo stack first, so it can
## always be taken back.
func fire(cell: Vector2i) -> void:
	if not can_fire(cell):
		return

	_history.append({
		"balls": ball_positions.duplicate(),
		"collected": collected_waypoints.duplicate(),
		"fired": fired.duplicate(),
		"gates": gate_mask,
	})
	fired.append(cell)

	animating = true
	activation_started.emit(cell)
	await _play_activation(Magnet.new(cell, magnets[cell]), magnet_list())
	animating = false

	if reached_goal():
		solved = true
		_set_message(_win_text(), MessageKind.WIN)
		changed.emit()
		solved_level.emit()
		return

	_set_message(_progress_text(), MessageKind.NORMAL)
	changed.emit()


## Takes back the last fired magnet.
func undo() -> void:
	if animating or _history.is_empty():
		return
	var snapshot: Dictionary = _history.pop_back()
	ball_positions = snapshot["balls"]
	collected_waypoints = snapshot["collected"]
	fired = snapshot["fired"]
	gate_mask = snapshot["gates"]
	solved = false
	rewinds += 1
	_set_message(_progress_text(), MessageKind.NORMAL)
	changed.emit()


## Rewinds every fired magnet but keeps the placement.
func restart_run() -> void:
	if animating or _history.is_empty():
		return
	rewinds += 1
	_rewind_to_start()
	_set_message("Zurück auf Anfang. Die Magnete stehen noch.", MessageKind.NORMAL)
	changed.emit()


## Clears the board completely — magnets included.
func clear_board() -> void:
	if animating:
		return
	magnets.clear()
	rewinds += 1
	_rewind_to_start()
	_set_message(_opening_hint(), MessageKind.NORMAL)
	changed.emit()


## Puts the balls back on their starts and drops the move history. Every edit
## goes through here, which is what keeps the played board identical to the one
## the solver verified: all magnets present, for the whole run.
func _rewind_to_start() -> void:
	ball_positions = puzzle.ball_starts()
	fired.clear()
	_history.clear()
	gate_mask = 0
	solved = false
	collected_waypoints.clear()
	var starts := puzzle.ball_starts()
	for w: Vector2i in puzzle.waypoints:
		if starts.has(w):
			collected_waypoints[w] = true


# --- Preview ----------------------------------------------------------------

## The paths every ball would travel if [param cell] fired right now, one entry
## per ball. Empty when firing it is not a legal move.
##
## This is the feedback loop: hovering a magnet answers "what does this do?"
## before the player spends the move. It shows the consequence of *one* action,
## never the route to the target, so it teaches the rules without solving the
## puzzle — the ordering is still entirely the player's problem.
func preview_paths(cell: Vector2i) -> Array:
	if not can_fire(cell):
		return []
	return Movement.activate_all_paths(
		ball_positions, Magnet.new(cell, magnets[cell]), magnet_list(), puzzle, gate_mask
	)


# --- Simulation -------------------------------------------------------------

## Plays one activation. Each ball is animated **leg by leg** along its own
## corners, with all balls advancing in lockstep. Every leg is a straight
## row/column run, so a ball deflected around a corner never tweens diagonally
## across the board — it visibly goes across, then down.
func _play_activation(magnet: Magnet, list: Array) -> void:
	var paths := Movement.activate_all_paths(ball_positions, magnet, list, puzzle, gate_mask)
	# Plates read the paths of *this* slide but only take effect once it has
	# resolved, so the whole move is judged against one board. Pressing a plate is
	# therefore a move of its own — which is exactly what makes order matter.
	var toggled := puzzle.plates_toggled_by(paths)

	# A waypoint counts as collected the moment any ball crosses it.
	for w: Vector2i in puzzle.waypoints:
		for p: Array in paths:
			if p.has(w):
				collected_waypoints[w] = true
				break

	var next: Array = []
	for p: Array in paths:
		next.append(p[p.size() - 1])
	if Movement.same_positions(next, ball_positions):
		# Nothing moved — pause briefly so the dud move still reads.
		_flash("Der Magnet erreicht keine Kugel.")
		await _wait(IDLE_MS)
		return

	var legs: Array = []
	var most := 0
	for p: Array in paths:
		var corners := _turn_points(p)
		legs.append(corners)
		most = maxi(most, corners.size())

	# Balls with fewer legs simply hold their final cell while the others finish.
	for i in range(1, most):
		for b in legs.size():
			var l: Array = legs[b]
			var from: Vector2i = ball_positions[b]
			var to: Vector2i = l[i] if i < l.size() else l[l.size() - 1]
			ball_positions[b] = to
			if to != from:
				var distance := absi(to.x - from.x) + absi(to.y - from.y)
				ball_landed.emit(to, distance)
		changed.emit()
		await _wait(STEP_MS)

	if toggled != 0:
		gate_mask ^= toggled
		gates_toggled.emit(toggled)
		changed.emit()


## Reduces a full cell-by-cell [param path] to its corners: the start, every cell
## where the slide changes direction, and the end.
func _turn_points(path: Array) -> Array:
	if path.size() <= 2:
		return path
	var points: Array = [path[0]]
	for i in range(1, path.size() - 1):
		if path[i] - path[i - 1] != path[i + 1] - path[i]:
			points.append(path[i])
	points.append(path[path.size() - 1])
	return points


# --- Messages ---------------------------------------------------------------

func _win_text() -> String:
	var used := magnets.size()
	if par > 0 and used <= par:
		return "Gelöst — mit der Mindestzahl von %d Magneten." % par
	if par > 0:
		return "Gelöst mit %d Magneten. Es geht auch mit %d." % [used, par]
	return "Gelöst!"


func _progress_text() -> String:
	if puzzle.is_multi_ball():
		return "%d von %d Kugeln im Ziel." % [balls_home(), puzzle.ball_count()]
	if not puzzle.waypoints.is_empty() and not all_waypoints_collected():
		return "Kristalle %d/%d eingesammelt." % [
			collected_waypoints.size(), puzzle.waypoints.size()
		]
	if not puzzle.gates.is_empty() and gate_mask != 0:
		return "Tore umgeschaltet. Z nimmt zurück."
	if fired.is_empty():
		return _opening_hint()
	if fired.size() == 1:
		return "1 Zug gemacht. Z nimmt ihn zurück."
	return "%d Züge gemacht. Z nimmt zurück." % fired.size()


## Lets the surrounding UI put its own line in the status area — used by the hint
## button, which knows something the state does not.
func announce(text: String, kind: MessageKind = MessageKind.NORMAL) -> void:
	_set_message(text, kind)


func _set_message(text: String, kind: MessageKind) -> void:
	_flash_token += 1  # cancel any pending flash restore
	_message = text
	_message_kind = kind
	message_changed.emit(text, kind)


## Shows a transient note, then restores the previous message.
func _flash(text: String) -> void:
	var previous := _message
	var previous_kind := _message_kind
	_flash_token += 1
	var token := _flash_token
	_message = text
	_message_kind = MessageKind.FAIL
	message_changed.emit(_message, _message_kind)

	await _wait(FLASH_MS)
	if token != _flash_token:
		return  # superseded
	_message = previous
	_message_kind = previous_kind
	message_changed.emit(_message, _message_kind)


func _wait(milliseconds: int) -> void:
	await get_tree().create_timer(milliseconds / 1000.0).timeout


func _label(type: Magnet.Type) -> String:
	return "Anzieh" if type == Magnet.Type.PLUS else "Abstoß"
