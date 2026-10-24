package shellder

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "gui:skald"

// Shellder — a Hyprland bar built with Skald. The bar is only the bar: empty
// by default, everything on it comes from plugins (plugins.odin) — external
// processes in any language, described by a manifest.json, talking over
// stdin/stdout. Look (colors, font, size, corners) follows the Omarchy theme
// (omarchy.odin), which is also forwarded to plugins.
//
// `skald.run` uses SDL, which cannot create layer surfaces, so we use Skald's
// embedded backend: native/wlbar.c creates one zwlr_layer_surface_v1 per
// output and each one is handed to the same Renderer as an extra swapchain.
// Input and the frame loop are ours.

Msg :: union {
	Plugin_Input,
	Open_Menu,
	Menu_Pick,
	Menu_Dismiss,
}

Open_Menu :: struct {
	plugin:  ^Plugin,
	bar_out: i32,
	rect:    skald.Rect,
}
Menu_Pick    :: struct { popup: ^Popup, index: int }
Menu_Dismiss :: struct { popup: ^Popup }

Plugin_Input :: struct {
	plugin: ^Plugin,
	ev:     Plugin_Event, // ev.monitor lives in temp_allocator: update runs before free_all
}

// update writes to the plugin's stdin — in a regular Skald app this would be a
// Command, but the embedded loop here does not process those.
update :: proc(app: ^App, m: Msg) {
	switch v in m {
	case Plugin_Input:
		plugin_send_event(v.plugin, v.ev, app.cfg.position)
	case Open_Menu:
		menu_open(app, v.bar_out, v.plugin, v.rect)
	case Menu_Pick:
		if popup_alive(app, v.popup) { menu_pick(app, v.popup, v.index) }
	case Menu_Dismiss:
		if popup_alive(app, v.popup) { popup_close(app, v.popup) }
	}
}

// ---------------------------------------------------------------------------

Bar :: struct {
	out:   i32, // index in app.bars (the shim's output id)
	win:   ^skald.Window,
	name:  string, // output name (DP-1, HDMI-A-1...)
	dirty: bool,

	// Double click on an empty area toggles bar.transparent (as in Omarchy).
	// The embedded backend does not count clicks, so we measure them here.
	over_item:  bool,      // pointer is over a plugin item this frame
	last_press: time.Tick, // last left click on an empty area
	press_pos:  [2]f32,
}

DOUBLE_CLICK_TIME :: 400 * time.Millisecond
DOUBLE_CLICK_DIST :: 4

App :: struct {
	cfg:      Config,
	layout:   [Section][dynamic]^Plugin,
	plugins:  Plugin_Set,

	r:        skald.Renderer,
	r_ready:  bool,
	bars:     [WB_MAX_OUTPUTS]Bar,
	labels:   skald.Labels,
	msgs:     [dynamic]Msg,

	omarchy:     Omarchy_Theme,
	theme:       skald.Theme,
	size:        int,    // effective bar thickness
	theme_json:  string, // theme serialized for the "config" event

	// Shellder's own popups (popups.odin), indexed by id - WB_MAX_OUTPUTS.
	popups:      [WB_MAX_POPUPS]^Popup,
	tooltip:     ^Popup,
	menu:        ^Popup,
	hover_now:   Hover_Target, // what the pointer is over (set while drawing)
	hover_shown: Hover_Target, // target the tooltip delay is running for
	hover_since: time.Tick,
	wb_position: Position, // edge the surfaces are currently anchored to
	pending_theme: bool,   // re-apply the theme next cycle (transparency changed)

	font:        skald.Font,
	font_file:   string, // file loaded into `font`
	em_factor:   f32,    // Omarchy px size -> Skald size (font_em_factor)
	font_data:   [dynamic][]u8, // bytes of every loaded font; they live as long as the renderer
}

vertical :: proc(app: ^App) -> bool {
	return app.cfg.position == .Left || app.cfg.position == .Right
}

// build_layout builds the sections from shell.json's bar.layout, in order.
// Installed plugins not yet in the layout (nor in "disabled") are appended to
// their defaultSection and shell.json is saved, like
// "omarchy plugin add --enable" does.
build_layout :: proc(app: ^App) {
	for s in Section { clear(&app.layout[s]) }
	placed := make(map[string]bool, 16, context.temp_allocator)
	for s in Section {
		for v in config_section(&app.cfg, s) {
			id := entry_id(v)
			if id == "" || config_is_disabled(&app.cfg, id) { continue }
			if placed[id] {
				fmt.eprintfln("shellder: %q appears more than once in the layout; keeping the first", id)
				continue
			}
			placed[id] = true
			found := false
			for p in app.plugins.plugins {
				if p.id == id { append(&app.layout[s], p); found = true }
			}
			if !found { fmt.eprintfln("shellder: plugin %q from shell.json is not installed", id) }
		}
	}
	added := false
	for p in app.plugins.plugins {
		if placed[p.id] || config_is_disabled(&app.cfg, p.id) { continue }
		if _, in_layout := config_entry(&app.cfg, p.id); in_layout { continue }
		append(&app.layout[p.default_section], p)
		config_add_entry(&app.cfg, p.default_section, p.id)
		fmt.printfln("shellder: plugin %s added to bar.layout.%s", p.id, SECTION_NAMES[p.default_section])
		added = true
	}
	if added { config_save(&app.cfg) }
}

// sync_plugins applies plugins_sync: starts new/reloaded plugins and rebuilds
// the layout if the set changed.
sync_plugins :: proc(app: ^App) {
	res := plugins_sync(&app.plugins, &app.cfg)
	if res.layout_changed { build_layout(app) }
	for p in res.start { plugin_start(p, &app.cfg, config_line_for(app, p)) }
	if res.layout_changed || len(res.start) > 0 { mark_all_dirty(app) }
}

// config_line_for builds the plugin's "config" event: bar, theme and the
// settings from its shell.json entry.
config_line_for :: proc(app: ^App, p: ^Plugin) -> string {
	return fmt.tprintf(`{{"event":"config","bar":{{"position":"%s","size":%d}},"theme":%s,"settings":%s}}` + "\n",
		POSITION_NAMES[app.cfg.position], app.size, app.theme_json,
		config_entry_settings_json(&app.cfg, p.id))
}

send_config_all :: proc(app: ^App) {
	for p in app.plugins.plugins { plugin_send_line(p, config_line_for(app, p)) }
}

// apply_settings_updates saves the settings plugins sent to shell.json and
// sends each one its updated "config".
apply_settings_updates :: proc(app: ^App) {
	for p in app.plugins.plugins {
		if len(p.settings_updates) == 0 { continue }
		for upd in p.settings_updates {
			config_merge_settings(&app.cfg, p.id, upd)
			json.destroy_value(upd)
		}
		clear(&p.settings_updates)
		config_save(&app.cfg)
		plugin_send_line(p, config_line_for(app, p))
	}
}

view :: proc(app: ^App, bar: ^Bar, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th  := ctx.theme
	gap: f32 = 0

	section :: proc(app: ^App, bar: ^Bar, ctx: ^skald.Ctx(Msg), s: Section) -> []skald.View {
		out := make([dynamic]skald.View, context.temp_allocator)
		for p in app.layout[s] {
			if v, ok := view_plugin(app, p, bar, ctx); ok { append(&out, v) }
		}
		return out[:]
	}
	left   := section(app, bar, ctx, .Left)
	right  := section(app, bar, ctx, .Right)

	// Three blocks: start and end with flex(1) so the center is truly centered.
	// As in Omarchy's Bar.qml: items packed together (each has its own
	// margin) and 8 px at both ends.
	EDGE :: 8
	vert := vertical(app)

	// bar.centerAnchor (Bar.qml: centerAnchorModule): the anchor item sits
	// exactly at the bar's center; center items before it hug its start edge
	// and grow away from it, items after it hug its end edge. So an item that
	// expands (indicators revealing on hover) never moves the anchor.
	before, anchor, after, has_anchor := split_center(app, bar, ctx)
	if has_anchor {
		stack :: proc(vert: bool, views: []skald.View, align: skald.Main_Align = .Start) -> skald.View {
			if vert { return skald.col(..views, main_align = align, cross_align = .Center) }
			return skald.row(..views, main_align = align, cross_align = .Center)
		}
		fill := skald.flex(1, skald.spacer(0))
		start_side := []skald.View{stack(vert, left), fill, stack(vert, before)}
		end_side   := []skald.View{stack(vert, after), fill, stack(vert, right)}
		parts := []skald.View{
			skald.spacer(EDGE),
			skald.flex(1, stack(vert, start_side)),
			anchor,
			skald.flex(1, stack(vert, end_side)),
			skald.spacer(EDGE),
		}
		if vert {
			return skald.col(..parts, width = f32(app.size), cross_align = .Center, bg = th.color.bg)
		}
		return skald.row(..parts, height = f32(app.size), cross_align = .Center, bg = th.color.bg)
	}

	center := section(app, bar, ctx, .Center)
	if vert {
		return skald.col(
			skald.spacer(EDGE),
			skald.flex(1, skald.col(..left, spacing = gap, cross_align = .Center)),
			skald.col(..center, spacing = gap, cross_align = .Center),
			skald.flex(1, skald.col(..right, spacing = gap, main_align = .End, cross_align = .Center)),
			skald.spacer(EDGE),
			width       = f32(app.size),
			cross_align = .Center,
			bg          = th.color.bg,
		)
	}
	return skald.row(
		skald.spacer(EDGE),
		skald.flex(1, skald.row(..left, spacing = gap, cross_align = .Center)),
		skald.row(..center, spacing = gap, cross_align = .Center),
		skald.flex(1, skald.row(..right, spacing = gap, main_align = .End, cross_align = .Center)),
		skald.spacer(EDGE),
		height      = f32(app.size),
		cross_align = .Center,
		bg          = th.color.bg,
	)
}

// split_center splits the center section around bar.centerAnchor. ok =
// false when there is no anchor or it is not in the center section.
split_center :: proc(app: ^App, bar: ^Bar, ctx: ^skald.Ctx(Msg)) -> (before: []skald.View, anchor: skald.View, after: []skald.View, ok: bool) {
	if app.cfg.center_anchor == "" { return }
	idx := -1
	for p, i in app.layout[.Center] {
		if p.id == app.cfg.center_anchor { idx = i }
	}
	if idx < 0 { return }
	b := make([dynamic]skald.View, context.temp_allocator)
	a := make([dynamic]skald.View, context.temp_allocator)
	for p, i in app.layout[.Center] {
		v, vok := view_plugin(app, p, bar, ctx)
		if i == idx {
			anchor = vok ? v : skald.spacer(0)
			continue
		}
		if !vok { continue }
		append(i < idx ? &b : &a, v)
	}
	return b[:], anchor, a[:], true
}

// view_plugin draws an item like Omarchy's bar buttons (Ui/WidgetButton.qml,
// BarIconButton.qml): no hover background — only the hand cursor —, text
// with an 8.5 px margin, an icon alone in an iconSlot-wide slot with the
// iconFont size, segments side by side.
view_plugin :: proc(app: ^App, p: ^Plugin, bar: ^Bar, ctx: ^skald.Ctx(Msg)) -> (skald.View, bool) {
	pv := plugin_view_for(p, bar.name)
	if !pv.visible || (pv.text == "" && pv.icon == "" && len(pv.segments) == 0) { return {}, false }
	th := ctx.theme
	om := &app.omarchy
	vert := vertical(app)
	bar_size := f32(app.size)
	MARGIN :: 8.5 // WidgetButton.horizontalMargin

	color, cok := color_by_name(om, pv.color)
	if !cok { color = th.color.fg }

	parts := make([dynamic]skald.View, context.temp_allocator)
	any_hover := false

	// Icon + text: one clickable zone.
	if pv.icon != "" || pv.text != "" {
		id := skald.hash_id(p.id)
		hovered := skald.widget_hovered(ctx, id)
		any_hover ||= hovered
		icon_size := em_size(app, om.bar_icon_font)
		text_size := em_size(app, font_px(om, pv.font, om.font.body))
		inner := make([dynamic]skald.View, context.temp_allocator)
		if pv.icon != "" { append(&inner, skald.text(pv.icon, color, icon_size, font = app.font)) }
		child: skald.View
		if vert {
			// Vertically each text line becomes a centered line, clipped to
			// the bar width (the clock uses "HH\n—\nmm").
			it := pv.text
			for line in strings.split_lines_iterator(&it) {
				append(&inner, skald.text(line, color, text_size, font = app.font,
					max_width = bar_size - 4, overflow = .Ellipsis, align = .Center))
			}
			child = skald.col(..inner[:], width = bar_size, padding = 4, cross_align = .Center)
		} else if pv.text == "" {
			child = skald.row(..inner[:], width = f32(om.bar_icon_slot), height = bar_size,
				main_align = .Center, cross_align = .Center)
		} else {
			append(&inner, skald.text(pv.text, color, text_size, font = app.font))
			child = skald.row(skald.spacer(MARGIN), skald.row(..inner[:], spacing = th.spacing.sm, cross_align = .Center),
				skald.spacer(MARGIN), height = bar_size, cross_align = .Center)
		}
		append(&parts, clickable_zone(app, ctx, p, bar, id, child, hovered, "", pv.tooltip))
	}

	// Segments: one button per segment, each with its id in the click.
	for sg in pv.segments {
		id := skald.hash_id(fmt.tprintf("%s\x00%s", p.id, sg.id))
		hovered := skald.widget_hovered(ctx, id)
		any_hover ||= hovered
		c := color
		if sg.color != "" {
			if sc, ok := color_by_name(om, sg.color); ok { c = sc }
		}
		c.a *= sg.opacity
		label := sg.text
		def_size := om.font.body
		if sg.icon != "" {
			label = sg.text == "" ? sg.icon : fmt.tprintf("%s %s", sg.icon, sg.text)
			if sg.text == "" { def_size = om.bar_icon_font }
		}
		size := em_size(app, font_px(om, sg.font, def_size))
		w, h := sg.width, bar_size
		if vert { w, h = bar_size, sg.width > 0 ? sg.width : 0 }
		pad: f32 = (vert ? h : w) > 0 ? 0 : MARGIN
		child := skald.row(skald.text(label, c, size, font = app.font),
			width = w, height = h, padding = vert ? 0 : pad,
			main_align = .Center, cross_align = .Center)
		if vert && h == 0 {
			child = skald.col(skald.text(label, c, size, font = app.font),
				width = w, padding = 5, main_align = .Center, cross_align = .Center)
		}
		append(&parts, clickable_zone(app, ctx, p, bar, id, child, hovered, sg.id,
			sg.tooltip != "" ? sg.tooltip : pv.tooltip))
	}

	// "hover" to the plugin when the pointer enters/leaves the item on this bar
	// (Omarchy's indicators reveal the inactive ones this way).
	// While the plugin's right-click menu is open its hover popup must go away.
	if app.menu != nil && app.menu.plugin == p { any_hover = false }
	if p.hover_mode != .None && p.hovered_on[bar.name] != any_hover {
		if _, had := p.hovered_on[bar.name]; !had {
			p.hovered_on[strings.clone(bar.name)] = any_hover
		} else {
			p.hovered_on[bar.name] = any_hover
		}
		// The hovered zone's rect, so the plugin can place a hover popup.
		hover_rect: skald.Rect
		if any_hover && app.hover_now.plugin == p { hover_rect = app.hover_now.rect }
		skald.send(ctx, Plugin_Input{plugin = p, ev = Plugin_Event{
			kind = .Hover, dir = any_hover ? 1 : 0, monitor = bar.name,
			item = hover_rect, bar_size = bar.win.size_logical,
		}})
	}

	if vert { return skald.col(..parts[:], spacing = 0, cross_align = .Center), true }
	return skald.row(..parts[:], spacing = 0, cross_align = .Center), true
}

// clickable_zone wraps `child` in a zone and sends the plugin the clicks and
// scrolls over it, with the zone rect and the segment (if any).
clickable_zone :: proc(app: ^App, ctx: ^skald.Ctx(Msg), p: ^Plugin, bar: ^Bar, id: skald.Widget_ID,
                       child: skald.View, hovered: bool, segment, tooltip: string) -> skald.View {
	z := skald.zone(ctx, child, id)
	rect := ctx.widgets.states[id].last_rect
	if hovered {
		bar.over_item = true
		// Tooltip target (manifest hover "tooltip", the default).
		app.hover_now = Hover_Target{
			set = true, bar_out = bar.out, plugin = p, segment = segment, rect = rect,
			text = p.hover_mode == .Tooltip ? tooltip : "",
		}
	}
	ev := Plugin_Event{
		segment  = segment,
		monitor  = bar.name,
		item     = rect,
		bar_size = bar.win.size_logical,
	}
	for b in skald.Mouse_Button {
		if !skald.widget_clicked(ctx, id, b) { continue }
		if b == .Right && len(p.menu) > 0 {
			// The manifest/plugin menu takes the right click.
			skald.send(ctx, Open_Menu{plugin = p, bar_out = bar.out, rect = rect})
			continue
		}
		{
			e := ev
			e.kind, e.button = .Click, b
			skald.send(ctx, Plugin_Input{plugin = p, ev = e})
		}
	}
	if hovered && ctx.input.scroll.y != 0 {
		e := ev
		e.kind, e.dir = .Scroll, ctx.input.scroll.y < 0 ? -1 : 1
		skald.send(ctx, Plugin_Input{plugin = p, ev = e})
	}
	return z
}

// ---------------------------------------------------------------------------

mark_all_dirty :: proc(app: ^App) {
	for &b in app.bars { b.dirty = true }
}

target_for :: proc(app: ^App, w: ^skald.Window) -> ^skald.Window_Target {
	for t in app.r.targets {
		if t.platform == w { return t }
	}
	return nil
}

// apply_theme (re)reads the Omarchy theme and propagates it: bar colors and
// sizes, surface thickness, font and the plugins' "config" event.
apply_theme :: proc(app: ^App, tw: ^Theme_Watch) {
	app.omarchy = theme_load(tw, app.cfg.transparent, app.cfg.position, vertical(app))
	app.theme   = theme_to_skald(&app.omarchy)

	size := vertical(app) ? app.omarchy.bar_size_vertical : app.omarchy.bar_size_horizontal
	// After wb_init: thickness or edge changed (theme, or bar.position in
	// shell.json) -> re-anchor the existing bars.
	if app.size != 0 && (size != app.size || app.cfg.position != app.wb_position) {
		wb_set_geometry(i32(size), i32(app.cfg.position))
	}
	app.size = size
	app.wb_position = app.cfg.position

	delete(app.theme_json)
	app.theme_json = theme_json(&app.omarchy)

	if app.r_ready { load_font(app) }
	mark_all_dirty(app)
}

// em_size converts an Omarchy size (em px, as in Qt) to Skald's `size` for
// the loaded font.
em_size :: proc(app: ^App, px: int) -> f32 {
	f := app.em_factor
	if f <= 0 { f = 1 }
	return f32(px) * f
}

// load_font loads the theme font into the renderer, with Skald's bundled
// Inter as fallback for missing glyphs.
load_font :: proc(app: ^App) {
	file := app.omarchy.font_file
	if file == "" {
		app.font = skald.font_default(&app.r)
		return
	}
	if file == app.font_file && app.font != 0 { return }
	data, err := os.read_entire_file(file, context.allocator)
	if err != nil {
		fmt.eprintfln("shellder: could not read font %s: %v", file, err)
		app.font = skald.font_default(&app.r)
		return
	}
	append(&app.font_data, data)
	app.em_factor = font_em_factor(data)
	app.font = skald.font_load(&app.r, app.omarchy.font_family, data)
	skald.font_add_fallback(&app.r, app.font, skald.font_default(&app.r))
	delete(app.font_file)
	app.font_file = strings.clone(file)
	fmt.printfln("shellder: font %s (%s, em ×%.3f)", app.omarchy.font_family, file, app.em_factor)
}

bar_configure :: proc(app: ^App, out: i32, w, h: i32) {
	b := &app.bars[out]
	scale := f32(wb_output_scale(out))
	size_px := [2]u32{u32(f32(w) * scale), u32(f32(h) * scale)}

	if b.win != nil {
		skald.window_resize_embedded(b.win, size_px, scale)
		skald.renderer_resize(&app.r, b.win)
		b.dirty = true
		return
	}

	win, ok := skald.window_init_embedded(skald.Embedded_Config{
		instance_extensions    = VK_INSTANCE_EXTS[:],
		get_instance_proc_addr = rawptr(vkGetInstanceProcAddr),
		create_surface         = create_wayland_surface,
		user                   = rawptr(uintptr(out)),
		size_px                = size_px,
		scale                  = scale,
		// Always with alpha: bar.transparent may turn on at any time.
		transparent            = true,
	})
	if !ok { return }
	b.win  = new_clone(win)
	b.out  = out
	b.name = strings.clone_from_cstring(wb_output_name(out))

	if !app.r_ready {
		app.r.lazy_present = true
		if !skald.renderer_init(&app.r, b.win) {
			fmt.eprintln("shellder: renderer_init failed")
			posix.exit(1)
		}
		app.r_ready = true
		app.font_file = ""
		app.font = 0
		load_font(app)
	} else if !skald.renderer_add_embedded_surface(&app.r, b.win, app.theme.color.bg) {
		fmt.eprintfln("shellder: could not add the surface for %s", b.name)
		free(b.win)
		delete(b.name)
		b^ = {}
		wb_output_destroy(out)
		return
	}
	fmt.printfln("shellder: bar on %s (%dx%d @%.0fx)", b.name, w, h, scale)
	b.dirty = true
}

bar_close :: proc(app: ^App, out: i32) {
	b := &app.bars[out]
	if b.win != nil {
		if len(app.r.targets) > 1 {
			skald.renderer_remove_embedded_surface(&app.r, b.win)
		} else {
			// Last output: Skald does not remove the last target, so we tear
			// the whole renderer down; it comes back on the next configure.
			skald.renderer_destroy(&app.r)
			app.r = {}
			app.r_ready = false
		}
		fmt.printfln("shellder: output %s removed", b.name)
		free(b.win)
		delete(b.name)
	}
	b^ = {}
	wb_output_destroy(out)
}

// handle_popup_event routes surface events of Shellder's own popups.
handle_popup_event :: proc(app: ^App, ev: WB_Event) {
	p := popup_by_id(app, ev.out)
	if p == nil { return }
	w := p.win
	#partial switch ev.type {
	case .Configure:
		popup_configure(app, p, ev.a, ev.b)
	case .Closed:
		popup_close(app, p)
	case .Enter, .Motion:
		if w != nil { skald.input_feed_pointer_motion(w, {f32(ev.x), f32(ev.y)}) }
	case .Leave:
		if w != nil { skald.input_feed_pointer_motion(w, {-10_000, -10_000}) }
	case .Button:
		if w != nil {
			btn: skald.Mouse_Button = ev.a == 0 ? .Left : ev.a == 1 ? .Middle : .Right
			skald.input_feed_pointer_button(w, btn, ev.b != 0)
		}
	}
}

handle_wayland_events :: proc(app: ^App) {
	ev: WB_Event
	for wb_next_event(&ev) != 0 {
		if ev.out >= WB_MAX_OUTPUTS {
			handle_popup_event(app, ev)
			continue
		}
		if ev.out < 0 { continue }
		w := app.bars[ev.out].win
		#partial switch ev.type {
		case .Configure:
			bar_configure(app, ev.out, ev.a, ev.b)
		case .Closed:
			popups_close_for_bar(app, ev.out)
			bar_close(app, ev.out)
		case .Enter, .Motion:
			if w != nil { skald.input_feed_pointer_motion(w, {f32(ev.x), f32(ev.y)}) }
		case .Leave:
			// Move the pointer off everything so hover clears.
			if w != nil {
				skald.input_feed_pointer_motion(w, {-10_000, -10_000})
				for btn in skald.Mouse_Button {
					if w.input.mouse_buttons[btn] { skald.input_feed_pointer_button(w, btn, false) }
				}
			}
		case .Button:
			if w != nil {
				btn: skald.Mouse_Button = ev.a == 0 ? .Left : ev.a == 1 ? .Middle : .Right
				skald.input_feed_pointer_button(w, btn, ev.b != 0)
			}
		case .Axis:
			if w != nil { skald.input_feed_scroll(w, {f32(ev.x), f32(ev.y)}) }
		}
	}
}

render_bar :: proc(app: ^App, b: ^Bar) {
	w := b.win
	t := target_for(app, w)
	if t == nil { return }

	skald.widget_store_begin_frame(t.widgets, w.input)
	clear_color := app.theme.color.bg
	if skald.frame_begin(&app.r, w, clear_color) {
		ctx := skald.Ctx(Msg){
			theme      = &app.theme,
			labels     = &app.labels,
			input      = &w.input,
			msgs       = &app.msgs,
			widgets    = t.widgets,
			renderer   = &app.r,
			window     = skald.Window_Id(t),
			breakpoint = skald.breakpoint_for_width(f32(w.size_logical.x)),
		}
		b.over_item = false
		if app.hover_now.bar_out == b.out { app.hover_now = {} }
		v := view(app, b, &ctx)
		skald.render_view(&app.r, v, {0, 0}, {f32(w.size_logical.x), f32(w.size_logical.y)})
		skald.render_overlays(&app.r)
		skald.frame_end(&app.r)
	}
	// Hand cursor over clickable items, like Omarchy's PointingHandCursor.
	if mp := w.input.mouse_pos; mp.x >= 0 && mp.y >= 0 {
		wb_set_cursor(b.over_item ? 1 : 0)
	}
	// Any left/middle press on the bar closes an open menu.
	if app.menu != nil && (w.input.mouse_pressed[.Left] || w.input.mouse_pressed[.Middle]) {
		append(&app.msgs, Msg(Menu_Dismiss{popup = app.menu}))
	}
	check_double_click(app, b)
	skald.input_begin(w) // reset input edges for the next frame
	b.dirty = false
}

// check_double_click: two quick left clicks outside items toggle the bar's
// transparency and save bar.transparent in shell.json.
check_double_click :: proc(app: ^App, b: ^Bar) {
	in_ := &b.win.input
	if !in_.mouse_pressed[.Left] { return }
	if b.over_item {
		b.last_press = {}
		return
	}
	pos := in_.mouse_pos
	d := pos - b.press_pos
	if b.last_press != {} && time.tick_since(b.last_press) <= DOUBLE_CLICK_TIME &&
	   abs(d.x) <= DOUBLE_CLICK_DIST && abs(d.y) <= DOUBLE_CLICK_DIST {
		b.last_press = {}
		config_set_transparent(&app.cfg, !app.cfg.transparent)
		app.pending_theme = true
		return
	}
	b.last_press = time.tick_now()
	b.press_pos = pos
}

THEME_CHECK :: time.Second

main :: proc() {
	sh_signals_init()

	app := new(App)
	app.labels = skald.labels_en()
	app.cfg = config_load()

	tw: Theme_Watch
	theme_watch_init(&tw)
	theme_changed(&tw)
	apply_theme(app, &tw)

	sync_plugins(app)
	if len(app.plugins.plugins) == 0 {
		fmt.printfln("shellder: no plugins in %s; the bar stays empty", app.cfg.plugins_dir)
	}

	if wb_init(i32(app.size), i32(app.cfg.position), "shellder") == 0 { posix.exit(1) }

	next_theme_check := time.time_add(time.now(), THEME_CHECK)
	for sh_should_quit() == 0 {
		handle_wayland_events(app)

		for p in app.plugins.plugins {
			if plugin_read(p) { mark_all_dirty(app) }
			if plugin_tick(p) { plugin_start(p, &app.cfg, config_line_for(app, p)) }
		}
		apply_settings_updates(app)
		plugins_reap()

		if app.pending_theme {
			app.pending_theme = false
			apply_theme(app, &tw)
			send_config_all(app)
		}

		if time.since(next_theme_check) >= 0 {
			if theme_changed(&tw) {
				apply_theme(app, &tw)
				send_config_all(app)
				fmt.println("shellder: theme reloaded")
			}
			// shell.json edited by hand: re-read everything — layout, settings,
			// disabled, transparent and position — without restarting.
			if config_changed_on_disk(&app.cfg) {
				old_pos, old_transparent := app.cfg.position, app.cfg.transparent
				if config_read(&app.cfg) {
					if app.cfg.position != old_pos || app.cfg.transparent != old_transparent {
						apply_theme(app, &tw) // size/edge and background
					}
					sync_plugins(app)
					build_layout(app)
					send_config_all(app)
					mark_all_dirty(app)
					fmt.println("shellder: shell.json reloaded")
				}
			}
			// New or removed plugins, or plugins whose files changed.
			sync_plugins(app)
			next_theme_check = time.time_add(time.now(), THEME_CHECK)
		}

		now_ns := time.now()._nsec
		for &b in app.bars {
			if b.win == nil || !app.r_ready { continue }
			deadline := false
			if t := target_for(app, b.win); t != nil {
				d := t.widgets.next_frame_deadline_ns
				deadline = d != 0 && now_ns >= d
			}
			if b.dirty || b.win.had_events || deadline { render_bar(app, &b) }
		}
		for p in app.popups {
			if p != nil && p.win != nil && (p.dirty || p.win.had_events) { render_popup(app, p) }
		}
		if app.r_ready { tooltip_update(app) }

		if len(app.msgs) > 0 {
			for m in app.msgs { update(app, m) }
			clear(&app.msgs)
			mark_all_dirty(app)
		}

		free_all(context.temp_allocator)

		// Wait for Wayland, plugin stdout, the next theme check or the next
		// plugin restart.
		wake := next_theme_check
		for p in app.plugins.plugins {
			if p.reaping { wake = time.time_add(time.now(), 100 * time.Millisecond) }
			if p.restart_at != {} && time.diff(p.restart_at, wake) > 0 { wake = p.restart_at }
		}
		if d, ok := tooltip_wake(app); ok {
			if at := time.time_add(time.now(), d); time.diff(at, wake) > 0 { wake = at }
		}
		any_dirty := false
		for b in app.bars { if b.win != nil && b.dirty { any_dirty = true } }
		for p in app.popups { if p != nil && p.win != nil && p.dirty { any_dirty = true } }
		timeout := i32(0)
		if !any_dirty {
			timeout = i32(max(time.duration_milliseconds(time.diff(time.now(), wake)), 0)) + 1
		}

		fds := make([dynamic]posix.pollfd, 0, 1 + len(app.plugins.plugins), context.temp_allocator)
		append(&fds, posix.pollfd{fd = posix.FD(wb_fd()), events = {.IN}})
		for p in app.plugins.plugins {
			if p.out_fd >= 0 { append(&fds, posix.pollfd{fd = posix.FD(p.out_fd), events = {.IN}}) }
		}

		if wb_before_poll() < 0 {
			fmt.eprintln("shellder: lost the connection to the compositor")
			break
		}
		posix.poll(raw_data(fds), posix.nfds_t(len(fds)), timeout)
		if wb_after_poll(.IN in fds[0].revents ? 1 : 0) < 0 {
			fmt.eprintln("shellder: lost the connection to the compositor")
			break
		}
	}

	for p in app.plugins.plugins { plugin_stop(p) }
}
