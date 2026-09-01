@tool
class_name LevelPack
extends RefCounted

## The shipped campaign, loaded from `res://data/levels.json`.
##
## That file is baked offline by `tools/reference_dart/bin/build_levels.dart`:
## every level in it was generated, solved and then **verified by replay**, so
## the game never has to search at runtime. Generation is far too slow to do
## while a player waits — see the tool's header — and baking also gives every
## level a stable id, which is what level select and any future achievements
## need to lean on.

const PACK_PATH := "res://data/levels.json"

## Chapter metadata in play order: `{id, title, intro, level_count}`.
var chapters: Array = []

## Every level in play order. [Array] of [Level].
var levels: Array = []

## Pack format version and the generator seed that baked it. Together with the
## level count they identify *which* campaign this is — see [method fingerprint].
var version: int = 0
var seed_value: int = 0

var load_error := ""


## Identifies this exact campaign. Level ids are positions in the pack, so
## re-baking with different chapters silently re-points every saved star at a
## different board. [PlayerProgress] stores this string and starts over when it
## changes, which is the honest answer: the old results were about levels that
## no longer exist.
func fingerprint() -> String:
	return "v%d-s%d-n%d" % [version, seed_value, levels.size()]


static func load_default() -> LevelPack:
	var pack := LevelPack.new()
	pack._load(PACK_PATH)
	return pack


func _load(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		load_error = "%s fehlt (Fehler %d)" % [path, FileAccess.get_open_error()]
		push_error("LevelPack: " + load_error)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		load_error = "%s ist kein gültiges JSON" % path
		push_error("LevelPack: " + load_error)
		return

	var data: Dictionary = parsed
	version = int(data.get("version", 0))
	seed_value = int(data.get("seed", 0))
	chapters = data.get("chapters", [])
	for entry: Dictionary in data.get("levels", []):
		levels.append(Level.from_json(entry))


func is_empty() -> bool:
	return levels.is_empty()


func count() -> int:
	return levels.size()


## The level with [param id], or null.
func by_id(id: int) -> Level:
	for level: Level in levels:
		if level.id == id:
			return level
	return null


## Zero-based play-order index of [param id], or -1.
func index_of(id: int) -> int:
	for i in levels.size():
		if levels[i].id == id:
			return i
	return -1


## The level after [param id] in play order, or null at the end of the campaign.
func next_after(id: int) -> Level:
	var i := index_of(id)
	if i == -1 or i + 1 >= levels.size():
		return null
	return levels[i + 1]


## Every level belonging to [param chapter_id], in play order.
func levels_in(chapter_id: String) -> Array:
	var out: Array = []
	for level: Level in levels:
		if level.chapter == chapter_id:
			out.append(level)
	return out


## Chapter metadata for [param chapter_id], or an empty Dictionary.
func chapter_meta(chapter_id: String) -> Dictionary:
	for meta: Dictionary in chapters:
		if meta["id"] == chapter_id:
			return meta
	return {}


## The chapter title for [param chapter_id], falling back to the raw id.
func chapter_title(chapter_id: String) -> String:
	var meta := chapter_meta(chapter_id)
	return meta.get("title", chapter_id)
