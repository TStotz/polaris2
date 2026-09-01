class_name LevelSelect
extends Control

## Chapter-by-chapter level grid.
##
## Built in code because it is pure data: one section per chapter in the pack,
## one tile per level, each showing its star result and whether it is reachable
## yet. Adding a chapter to `data/levels.json` grows this screen with no edit here.

signal level_chosen(level: Level)
signal back_requested

const TILE_SIZE := Vector2(84, 84)
const COLUMNS := 7

var pack: LevelPack

var _list: VBoxContainer
var _header: Label
var _unlock_toggle: CheckButton


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var background := ColorRect.new()
	background.color = PolarisTheme.BG
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	margin.add_child(column)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 16)
	column.add_child(top)

	var back := Button.new()
	back.text = "‹  Menü"
	back.flat = true
	back.pressed.connect(func() -> void: back_requested.emit())
	top.add_child(back)

	_header = Label.new()
	_header.add_theme_font_size_override("font_size", 13)
	_header.add_theme_color_override("font_color", PolarisTheme.INK_DIM)
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_header.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(_header)

	# Development switch. Deliberately visible rather than a secret key combo:
	# testing a chapter in the middle of the campaign is the normal case while
	# building, and a hidden toggle is one more thing to remember.
	_unlock_toggle = CheckButton.new()
	_unlock_toggle.text = "Alle Level (Debug)"
	_unlock_toggle.add_theme_font_size_override("font_size", 12)
	_unlock_toggle.add_theme_color_override("font_color", PolarisTheme.ACCENT)
	_unlock_toggle.toggled.connect(_on_unlock_toggled)
	top.add_child(_unlock_toggle)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 22)
	scroll.add_child(_list)


## Rebuilds the whole grid. Cheap enough at this size, and it keeps unlock state
## and star counts honest without any incremental bookkeeping.
func refresh(level_pack: LevelPack) -> void:
	pack = level_pack
	for child in _list.get_children():
		child.queue_free()
	if pack == null or pack.is_empty():
		var error := Label.new()
		var reason := pack.load_error if pack != null else ""
		error.text = (
			"Kein Level-Pack gefunden.\n%s\n\n"
			% reason
			+ "Neu backen mit `dart run bin/build_levels.dart` in tools/reference_dart."
		)
		error.add_theme_color_override("font_color", PolarisTheme.PLUS)
		_list.add_child(error)
		return

	_header.text = (
		"%d/%d Level · %d/%d Sterne"
		% [
			PlayerProgress.completed_count(),
			pack.count(),
			PlayerProgress.total_stars(),
			pack.count() * 3,
		]
	)
	# set_pressed_no_signal, so restoring the saved state does not re-enter the
	# handler and rebuild the grid from inside its own rebuild.
	_unlock_toggle.set_pressed_no_signal(PlayerProgress.debug_unlock_all)

	for meta: Dictionary in pack.chapters:
		_add_chapter(meta)


func _on_unlock_toggled(enabled: bool) -> void:
	PlayerProgress.set_debug_unlock_all(enabled)
	refresh(pack)


func _add_chapter(meta: Dictionary) -> void:
	var chapter_id: String = meta["id"]
	var levels := pack.levels_in(chapter_id)
	if levels.is_empty():
		return

	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 6)
	_list.add_child(section)

	var title := Label.new()
	title.text = str(meta.get("title", chapter_id)).to_upper()
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", PolarisTheme.INK)
	section.add_child(title)

	var intro := Label.new()
	intro.text = str(meta.get("intro", ""))
	intro.add_theme_font_size_override("font_size", 12)
	intro.add_theme_color_override("font_color", PolarisTheme.INK_DIM)
	section.add_child(intro)

	var grid := GridContainer.new()
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	section.add_child(grid)

	for level: Level in levels:
		grid.add_child(_make_tile(level))


func _make_tile(level: Level) -> Button:
	var unlocked := PlayerProgress.is_unlocked(pack, level.id)
	var stars := PlayerProgress.stars_for(level.id)

	var tile := Button.new()
	tile.custom_minimum_size = TILE_SIZE
	tile.disabled = not unlocked
	# Same reasoning as the in-game meter: the magnet count is the answer's size,
	# so it stays hidden until the level has been beaten once.
	tile.tooltip_text = (
		"%s · Bestwert %d Magnete" % [level.difficulty_label(), level.par]
		if stars > 0
		else level.difficulty_label()
	)
	if unlocked:
		tile.text = "%d\n%s" % [level.id, _star_row(stars)]
	else:
		# A locked tile still shows its number, so the campaign reads as a path
		# rather than a wall of question marks.
		tile.text = "%d\n🔒" % level.id
	tile.pressed.connect(func() -> void: level_chosen.emit(level))
	return tile


func _star_row(stars: int) -> String:
	return "★".repeat(stars) + "·".repeat(3 - stars)
