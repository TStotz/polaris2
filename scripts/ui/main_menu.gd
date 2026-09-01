class_name MainMenu
extends Control

## Title screen. Built in code because it is four buttons and a headline — a
## scene file would be more ceremony than content.

signal continue_requested
signal select_requested
signal prototype_requested
signal quit_requested

var _continue_button: Button
var _progress_label: Label

var pack: LevelPack


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var background := ColorRect.new()
	background.color = PolarisTheme.BG
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	add_child(FieldBackdrop.new())

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	column.custom_minimum_size = Vector2(320, 0)
	center.add_child(column)

	var title := Label.new()
	title.text = "POLARIS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 62)
	title.add_theme_color_override("font_color", PolarisTheme.INK)
	title.add_theme_constant_override("line_spacing", 0)
	column.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "M A G N E T   P U Z Z L E"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 13)
	subtitle.add_theme_color_override("font_color", PolarisTheme.INK_DIM)
	column.add_child(subtitle)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 28)
	column.add_child(gap)

	_continue_button = _add_button(column, "Weiterspielen", 50)
	_continue_button.pressed.connect(func() -> void: continue_requested.emit())

	var select := _add_button(column, "Level-Auswahl", 44)
	select.pressed.connect(func() -> void: select_requested.emit())

	# Marked as an experiment on purpose: it shares nothing with the campaign's
	# rules and is here to be judged by feel, not to be mistaken for a mode.
	var prototype := _add_button(column, "⚡ Prototyp: Echtzeit", 44)
	prototype.add_theme_color_override("font_color", PolarisTheme.ACCENT)
	prototype.pressed.connect(func() -> void: prototype_requested.emit())

	var quit := _add_button(column, "Beenden", 44)
	quit.pressed.connect(func() -> void: quit_requested.emit())

	_progress_label = Label.new()
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_progress_label.add_theme_font_size_override("font_size", 12)
	_progress_label.add_theme_color_override("font_color", PolarisTheme.INK_DIM)
	column.add_child(_progress_label)


func _add_button(column: VBoxContainer, text: String, height: int) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, height)
	column.add_child(button)
	return button


## Refreshes the progress line. Called every time the menu is shown, since stars
## change while the player is away in a level.
func refresh(level_pack: LevelPack) -> void:
	pack = level_pack
	if pack == null or pack.is_empty():
		_progress_label.text = "Keine Level geladen."
		_continue_button.disabled = true
		return
	var done := PlayerProgress.completed_count()
	_progress_label.text = (
		"%d von %d Leveln · %d von %d Sternen"
		% [done, pack.count(), PlayerProgress.total_stars(), pack.count() * 3]
	)
	var next := PlayerProgress.next_level(pack)
	_continue_button.disabled = next == null
	_continue_button.text = "Weiterspielen" if done > 0 else "Spiel starten"
