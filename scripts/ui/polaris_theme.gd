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

## Flipping-gravity zones. Two hues so the direction reads at a glance, and
## deliberately not the magnet colours — a zone is not a magnet, and reusing
## red/blue here would suggest a polarity the player can change.
## The zone's body — constant, so a fast beat never turns the field into a strobe.
const ZONE_BODY := Color("6a5cc4")

## Direction accents, carried only by the chevrons, the lit edge and the rail.
const ZONE_UP := Color("c8a6ff")
const ZONE_DOWN := Color("93a8e8")

## A world's palette: what the *scenery* is made of.
##
## **Only scenery.** A theme may repaint the background, the far blocks and the
## face of a wall; it may never touch [constant PLUS], [constant MINUS],
## [constant TARGET], [constant ACCENT], [constant OK], [constant BALL] or the
## zone colours. Those carry meaning the player has learned — red pulls, blue
## pushes, amber is the goal, mint is a checkpoint — and a board that recolours
## them is not a new world, it is a board you have to learn to read again.
##
## Seven colours, and deliberately no more. The panel keeps [constant BG] in every
## world too: it is interface, not scenery, and a world with a pale ground would
## otherwise take the HUD's legibility with it.
class World:
	var name: String
	var deep: Color        ## top of the background wash
	var low: Color         ## bottom of it
	var wall: Color        ## the far blocks that never move
	var wall_edge: Color   ## the frame, the block caps, the vignette's border
	var face_top: Color    ## the lit face of something you can stand on
	var face_bottom: Color
	var glow: Color        ## the light along the floor

	## The scenery, top of the board to bottom: `[[motif, share], ...]`, shares of the
	## arena's height that add up to one.
	##
	## **Shares rather than pixels**, so the same world tells the same story on a
	## 660px board and on a 2400px one. A board that only ever showed the bottom band
	## would be a board whose world is invisible.
	##
	## Top to bottom is written order because that is the order the boards are drawn
	## in and the order y counts in — but the stories read bottom-up, because that is
	## how a player travels them: out of the hull, up through the hold, onto the deck.
	var bands: Array

	func _init(
		world_name: String, top: String, bottom: String, far: String, far_edge: String,
		face_a: String, face_b: String, light: String, band_list: Array
	) -> void:
		name = world_name
		bands = band_list
		deep = Color(top)
		low = Color(bottom)
		wall = Color(far)
		wall_edge = Color(far_edge)
		face_top = Color(face_a)
		face_bottom = Color(face_b)
		glow = Color(light)


## The worlds, default first. Seven colours and a stack of bands each. The names are what a level writes into
## [member SimLevel.theme], and an unknown one falls back to the first rather than
## failing — a typo should cost you the look, not the level.
##
## They come from the campaign shape in `docs/echtzeit-ideen.md`: each world
## bundles mechanics that already exist and adds a *verbot*. The palette was the
## cheap half of that; the [member World.bands] are where a world stops being a
## tint and becomes a place. [WorldArt] draws them.
static var WORLDS: Array[World] = [
	# The default, and deliberately the quietest of them: fifteen boards already wear
	# it, so its scenery has to change the mood without taking the reading. A station
	# hull with the pole star above it.
	World.new(
		"Polaris", "04060d", "0a1020", "232c49", "2f3a5e", "46516e", "222a41", "35a7ff",
		[["sterne", 0.30], ["huelle", 0.40], ["decksplatten", 0.30]]
	),
	# A freighter you climb out of: ribs and portholes below the waterline, the hold
	# above that, crane booms over the deck.
	World.new(
		"Werft", "0d0a06", "1a1208", "4a3524", "6b4c30", "7a5c3c", "3a2a1c", "ff9a3c",
		[["kranausleger", 0.28], ["laderaum", 0.38], ["unterdeck", 0.34]]
	),
	# The one story that runs the other way: its top is the way out.
	World.new(
		"Schacht", "03060a", "070d16", "1a2733", "2b3d4d", "3a4e5e", "1c2833", "6fd3ff",
		[["schachtkopf", 0.26], ["gestein", 0.40], ["sumpf", 0.34]]
	),
	# Olive rather than green. The first cut was a mint-adjacent green and the gates
	# — [constant OK], also mint — stopped popping against it. A world may sit next
	# to a meaning; it may not sit *on* one.
	World.new(
		"Reaktor", "0a0a04", "181810", "3a3a1e", "5c5c2f", "6b7a3c", "2f3a1c", "c8ff4d",
		[["galerie", 0.28], ["kern", 0.40], ["kuehlkreis", 0.32]]
	),
	# The only world whose *top* band is empty space, which is its ban — no floor —
	# said in scenery.
	World.new(
		"Wrack", "06040c", "0e0a1c", "2a2142", "40325f", "584a7a", "281f3e", "cdd6ff",
		[["offenes", 0.34], ["truemmer", 0.36], ["rumpfbruch", 0.30]]
	),
	World.new(
		"Sortieranlage", "06100f", "0c1c1a", "1c3a37", "2d5a55", "447a74", "1e3a37", "5cf0d8",
		[["einlauf", 0.26], ["sortierboden", 0.40], ["schaechte", 0.34]]
	),
	World.new(
		"Sturm", "090c10", "141a22", "333d48", "4d5a68", "66757f", "2f3a44", "dfe9f5",
		[["himmel", 0.30], ["takelage", 0.38], ["aussenhaut", 0.32]]
	),
]

static var _world := 0


## Switches the scenery. An empty or unknown name is the default world.
##
## Called from the screens' [method CanvasItem._draw] rather than once on load, so
## it cannot go stale — the build mode changes the theme live, and a level can
## reach the play screen by more than one route. It returns immediately when
## nothing changes, so a per-frame call costs a comparison.
static func use(name: String) -> void:
	if name == WORLDS[_world].name:
		return
	for i in WORLDS.size():
		if WORLDS[i].name == name:
			_world = i
			return
	_world = 0


static func world() -> World:
	return WORLDS[_world]


## Index of [param name] among the worlds, 0 if it is not one of them.
static func world_index(name: String) -> int:
	for i in WORLDS.size():
		if WORLDS[i].name == name:
			return i
	return 0


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
