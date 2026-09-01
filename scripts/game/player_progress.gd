extends Node

## Campaign progress, persisted to `user://progress.cfg`. Registered as the
## `PlayerProgress` autoload.
##
## Stores one row per finished level (stars + the attempts it took) and derives
## everything else — how far the player has come, which level to offer next,
## whether a chapter is unlocked. Deliberately small and forgiving: a corrupt or
## missing file just means a fresh campaign, never a crash on launch.

signal progress_changed

const SAVE_PATH := "user://progress.cfg"
const SECTION := "levels"
const SETTINGS := "settings"

## level id -> {"stars": int, "runs": int}
var _records: Dictionary = {}

## Which campaign these records belong to ([method LevelPack.fingerprint]).
var _pack_fingerprint := ""

var music_enabled := true
var sfx_enabled := true

## Development switch: every level is playable regardless of progress.
##
## Persisted like any other setting so it survives a restart — testing a chapter
## in the middle of the campaign is otherwise impossible without playing sixty
## levels first. It only ever *adds* access; stars and best results are recorded
## exactly as usual, so a level genuinely solved while this is on still counts.
var debug_unlock_all := false


func _ready() -> void:
	load_progress()


func load_progress() -> void:
	_records.clear()
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return  # no save yet, or unreadable — start fresh
	for key: String in config.get_section_keys(SECTION) if config.has_section(SECTION) else []:
		var value: Variant = config.get_value(SECTION, key)
		if typeof(value) == TYPE_DICTIONARY:
			_records[int(key)] = value
	if config.has_section(SETTINGS):
		music_enabled = config.get_value(SETTINGS, "music", true)
		sfx_enabled = config.get_value(SETTINGS, "sfx", true)
		_pack_fingerprint = config.get_value(SETTINGS, "pack", "")
		debug_unlock_all = config.get_value(SETTINGS, "debug_unlock_all", false)


## Ties the loaded records to [param pack], discarding them when they belong to a
## different campaign. Returns true when progress was discarded.
##
## Level ids are positions in the pack, so a re-bake would otherwise leave three
## stars sitting on whichever board happens to be number 1 now. Wiping is the
## only honest option — and during development the pack is re-baked often.
func adopt_pack(pack: LevelPack) -> bool:
	if pack == null or pack.is_empty():
		return false
	var fingerprint := pack.fingerprint()
	if _pack_fingerprint == fingerprint:
		return false
	var had_records := not _records.is_empty()
	_records.clear()
	_pack_fingerprint = fingerprint
	save_progress()
	progress_changed.emit()
	return had_records


func save_progress() -> void:
	var config := ConfigFile.new()
	for id: int in _records:
		config.set_value(SECTION, str(id), _records[id])
	config.set_value(SETTINGS, "music", music_enabled)
	config.set_value(SETTINGS, "sfx", sfx_enabled)
	config.set_value(SETTINGS, "pack", _pack_fingerprint)
	config.set_value(SETTINGS, "debug_unlock_all", debug_unlock_all)
	var err := config.save(SAVE_PATH)
	if err != OK:
		push_error("PlayerProgress: could not save to %s (error %d)" % [SAVE_PATH, err])


## Records a finished level. Only ever improves a stored result, so replaying a
## level for fun can never cost the player the stars they already earned.
func record(level_id: int, stars: int, runs: int) -> void:
	var previous: Dictionary = _records.get(level_id, {})
	var best_stars: int = maxi(stars, previous.get("stars", 0))
	var best_runs: int = previous.get("runs", 0)
	if runs > 0 and (best_runs == 0 or runs < best_runs):
		best_runs = runs
	_records[level_id] = {"stars": best_stars, "runs": best_runs}
	save_progress()
	progress_changed.emit()


func stars_for(level_id: int) -> int:
	return _records.get(level_id, {}).get("stars", 0)


func best_runs_for(level_id: int) -> int:
	return _records.get(level_id, {}).get("runs", 0)


func is_completed(level_id: int) -> bool:
	return stars_for(level_id) > 0


func total_stars() -> int:
	var sum := 0
	for record: Dictionary in _records.values():
		sum += record.get("stars", 0)
	return sum


func completed_count() -> int:
	var n := 0
	for record: Dictionary in _records.values():
		if record.get("stars", 0) > 0:
			n += 1
	return n


## A level is playable when it is the first, already finished, or the one right
## after a finished level. Strictly linear unlocking is the wrong fit for a
## puzzle game — one board you cannot crack should not end the campaign — so
## [method is_unlocked] also opens anything within [constant SKIP_WINDOW] of the
## furthest level reached.
const SKIP_WINDOW := 3


func is_unlocked(pack: LevelPack, level_id: int) -> bool:
	if debug_unlock_all:
		return true
	var index := pack.index_of(level_id)
	if index <= 0:
		return true
	if is_completed(level_id):
		return true
	return index <= _furthest_index(pack) + SKIP_WINDOW


## Flips the development unlock and persists it.
func set_debug_unlock_all(enabled: bool) -> void:
	if debug_unlock_all == enabled:
		return
	debug_unlock_all = enabled
	save_progress()
	progress_changed.emit()


## Index of the last completed level in play order, or -1 when nothing is done.
func _furthest_index(pack: LevelPack) -> int:
	var furthest := -1
	for i in pack.levels.size():
		if is_completed(pack.levels[i].id):
			furthest = i
	return furthest


## The level the "Weiterspielen" button should open: the first unfinished one,
## falling back to the last level once the campaign is complete.
func next_level(pack: LevelPack) -> Level:
	if pack.is_empty():
		return null
	for level: Level in pack.levels:
		if not is_completed(level.id):
			return level
	return pack.levels[pack.levels.size() - 1]


## Wipes all progress. Used by the settings screen; asks nothing itself, the
## caller is responsible for confirming.
func reset_all() -> void:
	_records.clear()
	save_progress()
	progress_changed.emit()
