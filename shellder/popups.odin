package shellder

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import "gui:skald"

// Popups drawn by Shellder itself, so every plugin gets them whatever its
// language: the hover tooltip and the right-click menu. Each one is an extra
// layer surface (native/wlbar.c: wb_popup_open) rendered by the same Skald
// renderer as the bars.
//
// Panel — a plugin's panel described in JSON and drawn here (panels.odin).
//
// Tooltip — like Omarchy's Bar.qml: shown 400 ms after the pointer settles on
// an item, centered on it, 6 px from the bar, body font, 10x7 px padding,
// [tooltip] colors and a 1 px border. It takes no input.
//
// Menu — the manifest's barWidget.menu (or the plugin's {"menu": [...]}),
// opened by a right click. The surface covers the output's usable area so a
// click outside the card closes it; [menu] colors, popup-row-height rows.

TOOLTIP_DELAY :: 400 * time.Millisecond
TOOLTIP_GAP   :: 6
MENU_ROW_H    :: 28 // Style.spacing.popupRowHeight
MENU_PAD      :: 6
MENU_ROW_PAD  :: 12 // Style.spacing.rowPaddingX

Popup_Kind :: enum { Tooltip, Menu, Panel }

Popup :: struct {
	id:      i32,
	kind:    Popup_Kind,
	bar_out: i32, // output index of the bar it belongs to
	win:     ^skald.Window,
	dirty:   bool,

	text: string, // tooltip

	plugin: ^Plugin,          // menu
	items:  [dynamic]Menu_Item,
	card:   skald.Rect,       // menu card, in popup surface coordinates
	anchor: skald.Rect,       // the item's rect in its bar
	opened_at: time.Tick,

	// panel (panels.odin): the slider being dragged
	drag_id:    string,
	drag_value: f32,
	drag_sent:  f32,
	drag_at:    time.Tick,
}

// Hover_Target is what the pointer is over right now (recorded while drawing).
Hover_Target :: struct {
	set:     bool,
	bar_out: i32,
	plugin:  ^Plugin,
	segment: string,
	text:    string,
	rect:    skald.Rect,
}

hover_same :: proc(a, b: Hover_Target) -> bool {
	return a.set == b.set && a.bar_out == b.bar_out && a.plugin == b.plugin &&
	       a.segment == b.segment && a.text == b.text
}

popup_by_id :: proc(app: ^App, id: i32) -> ^Popup {
	i := id - WB_MAX_OUTPUTS
	if i < 0 || i >= WB_MAX_POPUPS { return nil }
	return app.popups[i]
}

// ---- lifecycle ----------------------------------------------------------------

popup_new :: proc(app: ^App, kind: Popup_Kind, bar_out: i32, edges, mt, mr, mb, ml, w, h: i32) -> ^Popup {
	wk := kind == .Tooltip ? WB_POPUP_TOOLTIP : kind == .Panel ? WB_POPUP_PANEL : WB_POPUP_MENU
	id := wb_popup_open(bar_out, i32(wk), edges, mt, mr, mb, ml, w, h)
	if id < 0 { return nil }
	p := new(Popup)
	p.id, p.kind, p.bar_out = id, kind, bar_out
	p.opened_at = time.tick_now()
	app.popups[id - WB_MAX_OUTPUTS] = p
	return p
}

popup_close :: proc(app: ^App, p: ^Popup) {
	if p == nil { return }
	if p.win != nil {
		skald.renderer_remove_embedded_surface(&app.r, p.win)
		free(p.win)
	}
	wb_popup_destroy(p.id)
	app.popups[p.id - WB_MAX_OUTPUTS] = nil
	if app.tooltip == p { app.tooltip = nil }
	if app.menu == p { app.menu = nil }
	if app.panel == p { app.panel = nil }
	delete(p.text)
	delete(p.drag_id)
	menu_free(&p.items); delete(p.items)
	free(p)
}

// popup_configure creates (or resizes) the popup's swapchain when the
// compositor sizes it.
popup_configure :: proc(app: ^App, p: ^Popup, w, h: i32) {
	scale := f32(wb_output_scale(p.id))
	size_px := [2]u32{u32(f32(w) * scale), u32(f32(h) * scale)}
	if p.win != nil {
		skald.window_resize_embedded(p.win, size_px, scale)
		skald.renderer_resize(&app.r, p.win)
	} else {
		win, ok := skald.window_init_embedded(skald.Embedded_Config{
			instance_extensions    = VK_INSTANCE_EXTS[:],
			get_instance_proc_addr = rawptr(vkGetInstanceProcAddr),
			create_surface         = create_wayland_surface,
			user                   = rawptr(uintptr(p.id)),
			size_px                = size_px,
			scale                  = scale,
			transparent            = true,
		})
		if !ok || !app.r_ready { popup_close(app, p); return }
		p.win = new_clone(win)
		if !skald.renderer_add_embedded_surface(&app.r, p.win, {0, 0, 0, 0}) {
			free(p.win)
			p.win = nil
			popup_close(app, p)
			return
		}
	}
	if p.kind == .Menu { menu_place(app, p, f32(w), f32(h)) }
	p.dirty = true
}

// Closes every popup that belongs to a bar (its output went away).
popups_close_for_bar :: proc(app: ^App, bar_out: i32) {
	for p in app.popups {
		if p != nil && p.bar_out == bar_out { popup_close(app, p) }
	}
}

// ---- tooltip --------------------------------------------------------------------

tooltip_size :: proc(app: ^App, text: string) -> (w, h: f32) {
	size := em_size(app, app.omarchy.font.body)
	it := text
	lines := 0
	line_h: f32 = 0
	for line in strings.split_lines_iterator(&it) {
		lw, lh := skald.measure_text(&app.r, line, size, app.font)
		w = max(w, lw)
		line_h = lh
		lines += 1
	}
	return w + 20, f32(lines) * line_h + 14
}

tooltip_open :: proc(app: ^App, t: Hover_Target) {
	b := &app.bars[t.bar_out]
	if b.win == nil || t.text == "" { return }
	w, h := tooltip_size(app, t.text)
	bw, bh := f32(b.win.size_logical.x), f32(b.win.size_logical.y)
	cx := t.rect.x + t.rect.w / 2
	cy := t.rect.y + t.rect.h / 2
	x := i32(clamp(cx - w / 2, 0, max(bw - w, 0)))
	y := i32(clamp(cy - h / 2, 0, max(bh - h, 0)))
	edges, mt, mr, mb, ml: i32
	switch app.cfg.position {
	case .Bottom: edges, mb, ml = WB_EDGE_BOTTOM | WB_EDGE_LEFT, TOOLTIP_GAP, x
	case .Top:    edges, mt, ml = WB_EDGE_TOP | WB_EDGE_LEFT, TOOLTIP_GAP, x
	case .Left:   edges, ml, mt = WB_EDGE_LEFT | WB_EDGE_TOP, TOOLTIP_GAP, y
	case .Right:  edges, mr, mt = WB_EDGE_RIGHT | WB_EDGE_TOP, TOOLTIP_GAP, y
	}
	p := popup_new(app, .Tooltip, t.bar_out, edges, mt, mr, mb, ml, i32(w + 0.99), i32(h + 0.99))
	if p == nil { return }
	p.text = strings.clone(t.text)
	app.tooltip = p
}

// tooltip_update runs after the bars are drawn: (re)arms the delay when the
// hover target changes and opens/closes the tooltip.
tooltip_update :: proc(app: ^App) {
	cur := app.hover_now
	if !hover_same(cur, app.hover_shown) {
		if app.tooltip != nil { popup_close(app, app.tooltip) }
		delete(app.hover_shown.text); delete(app.hover_shown.segment)
		app.hover_shown = cur
		app.hover_shown.text = strings.clone(cur.text)
		app.hover_shown.segment = strings.clone(cur.segment)
		app.hover_since = time.tick_now()
	}
	if cur.set && cur.text != "" && app.tooltip == nil && app.menu == nil &&
	   time.tick_since(app.hover_since) >= TOOLTIP_DELAY {
		tooltip_open(app, app.hover_shown)
	}
}

// tooltip_wake: when the loop must wake up to show a pending tooltip.
tooltip_wake :: proc(app: ^App) -> (time.Duration, bool) {
	t := app.hover_shown
	if !t.set || t.text == "" || app.tooltip != nil || app.menu != nil { return 0, false }
	return max(TOOLTIP_DELAY - time.tick_since(app.hover_since), 0), true
}

@(private = "file")
view_tooltip :: proc(app: ^App, p: ^Popup) -> skald.View {
	om := &app.omarchy
	size := em_size(app, om.font.body)
	lines := make([dynamic]skald.View, context.temp_allocator)
	it := p.text
	for line in strings.split_lines_iterator(&it) {
		append(&lines, skald.text(line, to_color(om.tooltip_text), size, font = app.font))
	}
	r := f32(om.radius)
	inner := skald.row(skald.spacer(9),
		skald.col(..lines[:], cross_align = .Center),
		skald.spacer(9), padding = 6, cross_align = .Center,
		bg = to_color(om.tooltip_background), radius = r)
	// 1 px border: the bubble sits on a border-colored box.
	return skald.col(inner, padding = 1, bg = to_color(om.tooltip_border), radius = r,
		width = f32(p.win.size_logical.x), height = f32(p.win.size_logical.y))
}

// ---- menu -----------------------------------------------------------------------

menu_open :: proc(app: ^App, bar_out: i32, plugin: ^Plugin, rect: skald.Rect) {
	if app.tooltip != nil { popup_close(app, app.tooltip) }
	if app.menu != nil {
		same := app.menu.plugin == plugin && app.menu.bar_out == bar_out
		popup_close(app, app.menu)
		if same { return } // right click again on the same item: toggle
	}
	p := popup_new(app, .Menu, bar_out, WB_EDGE_TOP | WB_EDGE_BOTTOM | WB_EDGE_LEFT | WB_EDGE_RIGHT, 0, 0, 0, 0, 0, 0)
	if p == nil { return }
	p.plugin = plugin
	p.anchor = rect
	for it in plugin.menu {
		append(&p.items, Menu_Item{
			id = strings.clone(it.id), label = strings.clone(it.label), icon = strings.clone(it.icon),
			exec = strings.clone(it.exec), separator = it.separator, disabled = it.disabled,
			checked = it.checked,
		})
	}
	app.menu = p
	mark_all_dirty(app) // redraw the bar so the plugin gets hovered=false
}

// menu_place sizes the card and places it next to the bar, centered on the item.
@(private = "file")
menu_place :: proc(app: ^App, p: ^Popup, sw, sh: f32) {
	size := em_size(app, app.omarchy.font.body)
	has_icon, has_check := false, false
	label_w: f32 = 0
	h: f32 = 2 * MENU_PAD
	for it in p.items {
		if it.separator { h += 2 * MENU_PAD + 1; continue }
		has_icon  ||= it.icon != ""
		has_check ||= it.checked >= 0
		lw, _ := skald.measure_text(&app.r, it.label, size, app.font)
		label_w = max(label_w, lw)
		h += MENU_ROW_H
	}
	w := label_w + 2 * MENU_ROW_PAD + 2 * MENU_PAD
	if has_icon  { w += 22 }
	if has_check { w += 22 }
	w = max(w, 140)
	gap: f32 = TOOLTIP_GAP
	a := p.anchor
	cx, cy := a.x + a.w / 2, a.y + a.h / 2
	x, y: f32
	switch app.cfg.position {
	case .Bottom: x, y = cx - w / 2, sh - h - gap
	case .Top:    x, y = cx - w / 2, gap
	case .Left:   x, y = gap, cy - h / 2
	case .Right:  x, y = sw - w - gap, cy - h / 2
	}
	p.card = {clamp(x, gap, max(sw - w - gap, gap)), clamp(y, gap, max(sh - h - gap, gap)), w, h}
}

@(private = "file")
view_menu :: proc(app: ^App, p: ^Popup, ctx: ^skald.Ctx(Msg)) -> skald.View {
	om := &app.omarchy
	size := em_size(app, om.font.body)
	icon_size := em_size(app, om.font.icon)
	r := f32(om.radius)
	has_icon, has_check := false, false
	for it in p.items {
		has_icon  ||= it.icon != ""
		has_check ||= it.checked >= 0
	}
	inner_w := p.card.w - 2 * MENU_PAD - 2

	rows := make([dynamic]skald.View, context.temp_allocator)
	for it, i in p.items {
		if it.separator {
			append(&rows, skald.col(skald.rect({inner_w, 1}, to_color(with_alpha_rgba(om.menu_text, 0.12))),
				padding = MENU_PAD))
			continue
		}
		id := skald.hash_id(fmt.tprintf("shellder-menu\x00%d", i))
		hovered := !it.disabled && skald.widget_hovered(ctx, id)
		fg := to_color(hovered ? om.menu_selected_text : om.menu_text)
		if it.disabled { fg = to_color(with_alpha_rgba(om.menu_text, 0.4)) }
		cells := make([dynamic]skald.View, context.temp_allocator)
		append(&cells, skald.spacer(MENU_ROW_PAD))
		if has_check {
			mark := it.checked == 1 ? "󰄬" : ""
			append(&cells, skald.row(skald.text(mark, fg, size, font = app.font), width = 22))
		}
		if has_icon {
			append(&cells, skald.row(skald.text(it.icon, fg, icon_size, font = app.font), width = 22))
		}
		append(&cells, skald.text(it.label, fg, size, font = app.font))
		bg := hovered ? to_color(om.menu_selected_background) : skald.Color{}
		row := skald.row(..cells[:], width = inner_w, height = MENU_ROW_H,
			cross_align = .Center, bg = bg, radius = r)
		z := skald.zone(ctx, row, id)
		if !it.disabled && skald.widget_clicked(ctx, id, .Left) {
			skald.send(ctx, Menu_Pick{popup = p, index = i})
		}
		append(&rows, z)
	}
	card := skald.col(
		skald.col(..rows[:], padding = MENU_PAD, bg = to_color(om.menu_background), radius = r),
		padding = 1, bg = to_color(om.menu_border), radius = r,
		width = p.card.w, height = p.card.h)
	return skald.col(skald.spacer(p.card.y), skald.row(skald.spacer(p.card.x), card))
}

// menu_pick runs the chosen entry: "exec" through the shell, otherwise a
// {"event":"menu"} line to the plugin.
menu_pick :: proc(app: ^App, p: ^Popup, index: int) {
	if index < 0 || index >= len(p.items) { return }
	it := p.items[index]
	if it.exec != "" {
		sh_run_detached(strings.clone_to_cstring(it.exec, context.temp_allocator))
	} else if p.plugin != nil {
		id_json, _ := json_quote(it.id)
		mon := wb_output_name(p.bar_out)
		mon_json, _ := json_quote(string(mon))
		plugin_send_line(p.plugin, fmt.tprintf(`{{"event":"menu","id":%s,"monitor":%s}}`+"\n", id_json, mon_json))
	}
	popup_close(app, p)
}

// ---- drawing ------------------------------------------------------------------

render_popup :: proc(app: ^App, p: ^Popup) {
	w := p.win
	t := target_for(app, w)
	if t == nil { return }
	skald.widget_store_begin_frame(t.widgets, w.input)
	if skald.frame_begin(&app.r, w, {0, 0, 0, 0}) {
		ctx := skald.Ctx(Msg){
			theme    = &app.theme,
			labels   = &app.labels,
			input    = &w.input,
			msgs     = &app.msgs,
			widgets  = t.widgets,
			renderer = &app.r,
			window   = skald.Window_Id(t),
		}
		v: skald.View
		switch p.kind {
		case .Tooltip: v = view_tooltip(app, p)
		case .Menu:    v = view_menu(app, p, &ctx)
		case .Panel:   v = view_panel(app, p, &ctx)
		}
		skald.render_view(&app.r, v, {0, 0}, {f32(w.size_logical.x), f32(w.size_logical.y)})
		skald.frame_end(&app.r)
	}
	// A press outside the menu card closes the menu (ignoring the press that
	// may still be in flight from the right click that opened it).
	if p.kind == .Menu && time.tick_since(p.opened_at) > 150 * time.Millisecond {
		in_ := &w.input
		for b in skald.Mouse_Button {
			if in_.mouse_pressed[b] && !rect_has(p.card, in_.mouse_pos) {
				append(&app.msgs, Msg(Menu_Dismiss{popup = p}))
			}
		}
		wb_set_cursor(rect_has(p.card, in_.mouse_pos) ? 1 : 0)
	}
	if p.kind == .Panel { panel_after_frame(app, p) }
	skald.input_begin(w)
	p.dirty = false
}

json_quote :: proc(s: string) -> (string, bool) {
	out, err := json.marshal(s, allocator = context.temp_allocator)
	return string(out), err == nil
}

popup_alive :: proc(app: ^App, p: ^Popup) -> bool {
	for q in app.popups { if q == p && p != nil { return true } }
	return false
}

rect_has :: proc(r: skald.Rect, pt: [2]f32) -> bool {
	return pt.x >= r.x && pt.y >= r.y && pt.x < r.x + r.w && pt.y < r.y + r.h
}

with_alpha_rgba :: proc(c: RGBA, a: f64) -> RGBA {
	out := c
	out[3] = u8(clamp(a, 0, 1) * 255)
	return out
}
