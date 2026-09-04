@tool
class_name PolarisTheme
extends RefCounted

## The POLARIS palette and the [Theme] that dresses every Control in it.
##
## Colours are plain constants rather than a theme resource because the arena is
## drawn in [method CanvasItem._draw]; any Control reads the same values through
## [method build], so panel and arena can never drift apart.

const BG := Color("070a14")
const BG_DEEP := Color("04060d")
const PANEL := Color("111729")
const PANEL_RAISED := Color("18203a")
const GRID_LINE := Color("1e2740")
const CELL_HOVER := Color("27324f")
const INK := Color("eef1f8")
const INK_DIM := Color("7b87a3")
const PLUS := Color("ff4d6d")
const PLUS_LIGHT := Color("ff97a9")
const MINUS := Color("35a7ff")
const MINUS_LIGHT := Color("8ccfff")
const BALL := Color("e6eaf4")
const BALL_EDGE := Color("717c94")
const TARGET := Color("ffd166")
const WALL := Color("232c49")
const WALL_EDGE := Color("2f3a5e")
const ACCENT := Color("ffd166")
const OK := Color("4fe3a0")

## Font stack, best first. [SystemFont] walks it until one resolves, so this
## degrades gracefully off Windows instead of needing a bundled font file.
const FONT_NAMES: Array[String] = [
	"Segoe UI Variable Text",
	"Segoe UI",
	"Inter",
	"SF Pro Text",
	"Roboto",
	"DejaVu Sans",
]


## The one font instance the whole game draws with.
##
## [method CanvasItem.draw_string] needs a [Font] object, and [ThemeDB]'s fallback
## is not the stack below — letting the arena use the fallback while the panels
## used this one is how a screen ends up in two typefaces.
static var _font: SystemFont = null


static func font() -> Font:
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = FONT_NAMES
		_font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	return _font


# --- Theme ------------------------------------------------------------------

## Builds the project-wide [Theme]. Applied once to the root Control, so every
## button, panel and label inherits it.
##
## Built in code rather than as a `.tres` because it is derived from the palette
## constants above — a resource file would be a second copy of these colours,
## free to drift.
static func build() -> Theme:
	var theme := Theme.new()
	var font := SystemFont.new()
	font.font_names = FONT_NAMES
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	theme.default_font = font
	theme.default_font_size = 15

	_style_button(theme, "Button")
	_style_label(theme)
	_style_panel(theme)
	_style_check_button(theme, font)
	_style_scrollbar(theme)
	return theme


## Flat, slightly raised buttons with an accent-lit hover — the panel should read
## as a control surface, not as an operating-system dialog.
static func _style_button(theme: Theme, type: String) -> void:
	theme.set_color("font_color", type, INK)
	theme.set_color("font_hover_color", type, Color.WHITE)
	theme.set_color("font_pressed_color", type, ACCENT)
	theme.set_color("font_disabled_color", type, Color(INK_DIM, 0.45))
	theme.set_color("font_focus_color", type, INK)
	theme.set_constant("h_separation", type, 8)

	theme.set_stylebox("normal", type, _box(PANEL_RAISED, GRID_LINE))
	theme.set_stylebox("hover", type, _box(CELL_HOVER, Color(ACCENT, 0.55)))
	theme.set_stylebox("pressed", type, _box(Color("222c4a"), ACCENT))
	theme.set_stylebox("disabled", type, _box(Color(PANEL_RAISED, 0.4), Color(GRID_LINE, 0.4)))
	theme.set_stylebox("focus", type, _box(Color(0, 0, 0, 0), Color(ACCENT, 0.35)))


static func _box(fill: Color, border: Color, radius: int = 10) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(radius)
	box.set_border_width_all(1)
	box.border_color = border
	box.content_margin_left = 14
	box.content_margin_right = 14
	box.content_margin_top = 9
	box.content_margin_bottom = 9
	return box


static func _style_label(theme: Theme) -> void:
	theme.set_color("font_color", "Label", INK)
	theme.set_constant("line_spacing", "Label", 4)


static func _style_panel(theme: Theme) -> void:
	var panel := StyleBoxFlat.new()
	panel.bg_color = PANEL
	panel.set_corner_radius_all(18)
	panel.set_border_width_all(1)
	panel.border_color = Color(GRID_LINE, 0.9)
	panel.shadow_color = Color(0, 0, 0, 0.45)
	panel.shadow_size = 18
	panel.shadow_offset = Vector2(0, 6)
	theme.set_stylebox("panel", "PanelContainer", panel)
	theme.set_stylebox("panel", "Panel", panel)


## Without its own entry a CheckButton falls back to the OS look and stands out
## as the one unstyled control on screen.
static func _style_check_button(theme: Theme, font: SystemFont) -> void:
	_style_button(theme, "CheckButton")
	theme.set_color("font_color", "CheckButton", INK_DIM)
	theme.set_color("font_pressed_color", "CheckButton", ACCENT)
	theme.set_font("font", "CheckButton", font)
	theme.set_font_size("font_size", "CheckButton", 12)


static func _style_scrollbar(theme: Theme) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(GRID_LINE, 0.25)
	track.set_corner_radius_all(4)
	track.content_margin_left = 3
	track.content_margin_right = 3

	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color(INK_DIM, 0.55)
	grabber.set_corner_radius_all(4)

	var grabber_hover := grabber.duplicate() as StyleBoxFlat
	grabber_hover.bg_color = Color(ACCENT, 0.75)

	theme.set_stylebox("scroll", "VScrollBar", track)
	theme.set_stylebox("grabber", "VScrollBar", grabber)
	theme.set_stylebox("grabber_highlight", "VScrollBar", grabber_hover)
	theme.set_stylebox("grabber_pressed", "VScrollBar", grabber_hover)
