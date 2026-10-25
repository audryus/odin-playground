package shellder

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import "gui:skald"

// Panels drawn by Shellder (manifest barWidget.panel: "skald"). The plugin
// describes the content and Shellder draws it, so the plugin needs no GUI
// toolkit at all:
//
//   plugin -> {"panel": {"width": 380, "items": [node, ...]}}   open / update
//             {"panel": null}                                   close
//   Shellder -> {"event":"panel","action":"click","id":...}     row/button/action
//               {"event":"panel","action":"change","id":...,"value":0.42}  slider
//               {"event":"panel","action":"toggle","id":...,"value":true}  switch
//               {"event":"panel","action":"closed"}             closed by Shellder
//
// Nodes ("type"): hero, section, separator, slider, row, label, group — the
// same vocabulary as the kit's GTK widgets, drawn like Omarchy's panels. The
// card opens next to the item the plugin's last click came from, on a layer
// covering the output's usable area: a press outside the card closes it.

PANEL_PAD      :: 14 // Style.spacing.popupPadding
PANEL_GAP      :: 8
PANEL_ROW_H    :: 34
PANEL_SLIDER_H :: 26
PANEL_SWITCH   :: [2]f32{40, 22}
PANEL_CHANGE_INTERVAL :: 40 * time.Millisecond // slider changes while dragging

// panels_sync opens, updates or closes the Shellder-drawn panel after plugins
// sent their lines. Called from the main loop.
panels_sync :: proc(app: ^App) {
	if p := app.panel; p != nil {
		if !plugin_alive(app, p.plugin) {
			popup_close(app, p) // plugin unloaded, exited or restarting
		} else if _, open := p.plugin.panel_spec.(json.Object); !open {
			p.plugin.panel_changed = false
			popup_close(app, p) // the plugin closed it
		} else if p.plugin.panel_changed {
			p.plugin.panel_changed = false
			p.dirty = true
		}
	}
	for pl in app.plugins.plugins {
		if !pl.panel_changed { continue }
		pl.panel_changed = false
		if _, open := pl.panel_spec.(json.Object); !open { continue }
		if app.panel != nil && app.panel.plugin == pl { continue }
		panel_open(app, pl)
	}
}

plugin_alive :: proc(app: ^App, p: ^Plugin) -> bool {
	for q in app.plugins.plugins { if q == p { return plugin_running(p) } }
	return false
}

@(private = "file")
panel_open :: proc(app: ^App, pl: ^Plugin) {
	// One popup at a time.
	if app.panel != nil { panel_dismiss(app, app.panel) }
	if app.menu != nil { popup_close(app, app.menu) }
	if app.tooltip != nil { popup_close(app, app.tooltip) }
	dismiss_popups(app, pl)

	bar_out := pl.click_out
	if bar_out < 0 || bar_out >= i32(len(app.bars)) || app.bars[bar_out].win == nil {
		bar_out = 0
		for b, i in app.bars { if b.win != nil { bar_out = i32(i); break } }
	}
	p := popup_new(app, .Panel, bar_out, WB_EDGE_TOP | WB_EDGE_BOTTOM | WB_EDGE_LEFT | WB_EDGE_RIGHT, 0, 0, 0, 0, 0, 0)
	if p == nil { return }
	p.plugin = pl
	p.anchor = pl.click_rect
	app.panel = p
	mark_all_dirty(app)
}

// panel_dismiss closes the panel on Shellder's side and tells the plugin.
panel_dismiss :: proc(app: ^App, p: ^Popup) {
	pl := p.plugin
	popup_close(app, p)
	if pl != nil && plugin_alive(app, pl) {
		plugin_set_panel(pl, nil)
		pl.panel_changed = false
		plugin_send_line(pl, `{"event":"panel","action":"closed"}` + "\n")
	}
}

// plugin_set_panel replaces the plugin's panel description (cloned; nil closes).
plugin_set_panel :: proc(pl: ^Plugin, spec: json.Value) {
	json.destroy_value(pl.panel_spec)
	pl.panel_spec = nil
	if _, ok := spec.(json.Object); ok {
		pl.panel_spec = json.clone_value(spec, context.allocator)
	}
	pl.panel_changed = true
}

@(private = "file")
panel_send :: proc(p: ^Popup, action, id: string, value: string = "") {
	id_json, _ := json_quote(id)
	tail := value != "" ? fmt.tprintf(`,"value":%s`, value) : ""
	plugin_send_line(p.plugin, fmt.tprintf(`{{"event":"panel","action":"%s","id":%s%s}}`+"\n", action, id_json, tail))
}

// ---- drawing ----------------------------------------------------------------------

@(private = "file")
Panel_Style :: struct {
	fg, bg, dim, hairline, track: skald.Color,
	normal, normal_border, hover, hover_border, selected, selected_border, selected_color, pressed: skald.Color,
	nbw, hbw, sbw, r: f32,
	caption, body_small, body, subtitle, title, display, icon: f32,
}

@(private = "file")
panel_style :: proc(app: ^App) -> Panel_Style {
	om := &app.omarchy
	fg := om.popup_text
	darker :: proc(c: RGBA, f: f64) -> RGBA {
		return {u8(f64(c[0]) / f), u8(f64(c[1]) / f), u8(f64(c[2]) / f), c[3]}
	}
	sz :: proc(app: ^App, px: int) -> f32 { return em_size(app, px) }
	return Panel_Style{
		fg = to_color(fg), bg = to_color(om.popup_background), dim = to_color(darker(fg, 1.4)),
		hairline = to_color(with_alpha_rgba(fg, 0.12)), track = to_color(om.selected_fill),
		normal = to_color(om.normal_fill), normal_border = to_color(om.normal_border),
		hover = to_color(om.hover_fill), hover_border = to_color(om.hover_border),
		selected = to_color(om.selected_fill), selected_border = to_color(om.selected_border),
		selected_color = to_color(om.selected_color), pressed = to_color(om.pressed_fill),
		nbw = f32(om.normal_border_width), hbw = f32(om.hover_border_width),
		sbw = f32(om.selected_border_width), r = f32(om.radius),
		caption = sz(app, om.font.caption), body_small = sz(app, om.font.body_small),
		body = sz(app, om.font.body), subtitle = sz(app, om.font.subtitle),
		title = sz(app, om.font.title), display = sz(app, om.font.display),
		icon = sz(app, om.font.icon),
	}
}

@(private = "file")
Panel_Ctx :: struct {
	app:   ^App,
	p:     ^Popup,
	ctx:   ^skald.Ctx(Msg),
	st:    Panel_Style,
	bold:  skald.Font,
}

@(private = "file")
jstr :: proc(o: json.Object, k: string) -> string {
	s, _ := o[k].(json.String)
	return s
}

@(private = "file")
jnum :: proc(o: json.Object, k: string, def: f32) -> f32 {
	#partial switch n in o[k] {
	case json.Integer: return f32(n)
	case json.Float:   return f32(n)
	}
	return def
}

@(private = "file")
jbool :: proc(o: json.Object, k: string) -> bool {
	b, _ := o[k].(json.Boolean)
	return b
}

view_panel :: proc(app: ^App, p: ^Popup, ctx: ^skald.Ctx(Msg)) -> skald.View {
	spec, ok := p.plugin.panel_spec.(json.Object)
	if !ok { return skald.spacer(0) }
	c := Panel_Ctx{app = app, p = p, ctx = ctx, st = panel_style(app),
		bold = app.font_bold != 0 ? app.font_bold : app.font}
	bw := f32(app.omarchy.popup_border_width)
	width := jnum(spec, "width", 340)
	inner := width - 2 * PANEL_PAD - 2 * bw

	items, _ := spec["items"].(json.Array)
	body := panel_nodes(&c, items, inner, jnum(spec, "spacing", 14))
	card_id := skald.hash_id("shellder-panel-card")
	card := skald.zone(ctx, skald.col(
		skald.col(body, padding = PANEL_PAD, bg = c.st.bg, radius = c.st.r, width = width - 2 * bw),
		padding = bw, bg = to_color(app.omarchy.popup_border), radius = c.st.r, width = width), card_id)
	last := ctx.widgets.states[card_id].last_rect
	if last.w > 0 { p.card = last }

	// Next to the bar, centered on the item, kept inside the output.
	sw, sh := f32(p.win.size_logical.x), f32(p.win.size_logical.y)
	a := p.anchor
	h := p.card.h
	clampf :: proc(v, lo, hi: f32) -> f32 { return clamp(v, lo, max(lo, hi)) }
	switch app.cfg.position {
	case .Bottom:
		x := clampf(a.x + a.w / 2 - width / 2, PANEL_GAP, sw - width - PANEL_GAP)
		return skald.col(skald.flex(1, skald.spacer(0)), skald.row(skald.spacer(x), card),
			skald.spacer(PANEL_GAP), height = sh, width = sw)
	case .Top:
		x := clampf(a.x + a.w / 2 - width / 2, PANEL_GAP, sw - width - PANEL_GAP)
		return skald.col(skald.spacer(PANEL_GAP), skald.row(skald.spacer(x), card))
	case .Left, .Right:
		// The height is known from the previous frame: draw again until it is.
		if h == 0 { p.dirty = true }
		y := clampf(a.y + a.h / 2 - h / 2, PANEL_GAP, sh - h - PANEL_GAP)
		if app.cfg.position == .Left {
			return skald.col(skald.spacer(y), skald.row(skald.spacer(PANEL_GAP), card))
		}
		return skald.col(skald.spacer(y), skald.row(skald.flex(1, skald.spacer(0)), card,
			skald.spacer(PANEL_GAP), width = sw))
	}
	return card
}

@(private = "file")
panel_nodes :: proc(c: ^Panel_Ctx, items: json.Array, w, spacing: f32) -> skald.View {
	views := make([dynamic]skald.View, context.temp_allocator)
	for it in items {
		n := it.(json.Object) or_continue
		append(&views, panel_node(c, n, w))
	}
	return skald.col(..views[:], spacing = spacing, width = w)
}

@(private = "file")
panel_node :: proc(c: ^Panel_Ctx, n: json.Object, w: f32) -> skald.View {
	st := &c.st
	font := c.app.font
	switch jstr(n, "type") {
	case "separator":
		return skald.rect({w, 1}, st.hairline)

	case "section":
		return skald.row(
			skald.text(jstr(n, "text"), st.dim, st.caption, font = c.bold),
			skald.flex(1, skald.spacer(0)),
			skald.text(jstr(n, "value"), st.dim, st.caption, font = c.bold),
			width = w, cross_align = .Center)

	case "label":
		color := st.fg
		size := st.body
		f := font
		switch jstr(n, "style") {
		case "dim":     color = st.dim
		case "caption": size = st.caption; color = st.dim
		case "small":   size = st.body_small
		case "title":   size = st.title; f = c.bold
		case "bold":    f = c.bold
		}
		return skald.text(jstr(n, "text"), color, size, font = f, max_width = w, overflow = .Ellipsis)

	case "group":
		items, _ := n["items"].(json.Array)
		return panel_nodes(c, items, w, jnum(n, "spacing", 6))

	case "hero":
		title := skald.text(jstr(n, "title"), st.fg, st.title, font = c.bold, overflow = .Ellipsis)
		texts := make([dynamic]skald.View, context.temp_allocator)
		append(&texts, title)
		if meta := jstr(n, "meta"); meta != "" {
			append(&texts, skald.text(strings.to_upper(meta, context.temp_allocator), st.dim, st.caption, font = c.bold))
		}
		cells := make([dynamic]skald.View, context.temp_allocator)
		if icon := jstr(n, "icon"); icon != "" {
			append(&cells, skald.text(icon, st.fg, st.display, font = font), skald.spacer(14))
		}
		append(&cells, skald.flex(1, skald.col(..texts[:], spacing = 2)))
		if sw, ok := n["switch"].(json.Object); ok {
			append(&cells, panel_switch(c, jstr(sw, "id"), jbool(sw, "on")))
		}
		return skald.row(..cells[:], width = w, cross_align = .Center)

	case "slider":
		return panel_slider(c, n, w)

	case "row":
		return panel_row(c, n, w)
	}
	return skald.spacer(0)
}

// ---- row --------------------------------------------------------------------------

@(private = "file")
panel_row :: proc(c: ^Panel_Ctx, n: json.Object, w: f32) -> skald.View {
	st := &c.st
	id := jstr(n, "id")
	plain := jbool(n, "plain") // a line of content, not a list row
	zid := skald.hash_id(fmt.tprintf("shellder-panel-row\x00%s", id))
	clickable := id != "" && !jbool(n, "disabled")
	hovered := clickable && skald.widget_hovered(c.ctx, zid)
	selected := jbool(n, "selected")
	fg := selected ? st.selected_color : st.fg

	pad: f32 = plain ? 0 : 8
	cells := make([dynamic]skald.View, context.temp_allocator)
	if act, ok := n["action"].(json.Object); ok {
		append(&cells, panel_action(c, jstr(act, "id"), jstr(act, "icon")))
		append(&cells, skald.spacer(8))
	}
	if icon := jstr(n, "icon"); icon != "" {
		append(&cells, skald.row(skald.text(icon, fg, st.title, font = c.app.font), width = 22),
			skald.spacer(10))
	}
	append(&cells, skald.flex(1, skald.text(jstr(n, "text"), fg, st.body, font = c.app.font,
		overflow = .Ellipsis)))
	if v := jstr(n, "value"); v != "" {
		append(&cells, skald.spacer(8), skald.text(v, st.dim, st.body_small, font = c.app.font))
	}
	if t := jstr(n, "trailing"); t != "" {
		append(&cells, skald.spacer(8), skald.text(t, fg, st.subtitle, font = c.app.font))
	}

	h: f32 = plain ? 24 : PANEL_ROW_H
	fill, border: skald.Color
	bw: f32 = 0
	if selected {
		fill, border, bw = st.selected, st.selected_border, st.sbw
	} else if hovered {
		fill, border, bw = st.hover, st.hover_border, st.hbw
	}
	inner := skald.row(..cells[:], width = w - 2 * bw, height = h - 2 * bw, padding = pad,
		cross_align = .Center, bg = fill, radius = st.r)
	box := bw > 0 ? skald.col(inner, padding = bw, bg = border, radius = st.r) : inner
	if !clickable { return box }
	z := skald.zone(c.ctx, box, zid)
	if skald.widget_clicked(c.ctx, zid, .Left) { panel_send(c.p, "click", id) }
	return z
}

// panel_action is PanelActionButton: an icon button with a hover fill.
@(private = "file")
panel_action :: proc(c: ^Panel_Ctx, id, icon: string) -> skald.View {
	st := &c.st
	zid := skald.hash_id(fmt.tprintf("shellder-panel-action\x00%s", id))
	hovered := skald.widget_hovered(c.ctx, zid)
	v := skald.row(skald.text(icon, hovered ? to_color(c.app.omarchy.hover_color) : st.fg, st.icon, font = c.app.font),
		width = 26, height = 22, main_align = .Center, cross_align = .Center,
		bg = hovered ? st.hover : {}, radius = st.r)
	z := skald.zone(c.ctx, v, zid)
	if skald.widget_clicked(c.ctx, zid, .Left) { panel_send(c.p, "click", id) }
	return z
}

// ---- switch -------------------------------------------------------------------------

@(private = "file")
Switch_Paint :: struct {
	on: bool,
	st: Panel_Style,
}

@(private = "file")
panel_switch :: proc(c: ^Panel_Ctx, id: string, on: bool) -> skald.View {
	zid := skald.hash_id(fmt.tprintf("shellder-panel-switch\x00%s", id))
	paint := new(Switch_Paint, context.temp_allocator)
	paint^ = {on = on, st = c.st}
	draw :: proc(sp: ^Switch_Paint, pt: skald.Canvas_Painter) {
		b, st := pt.bounds, &sp.st
		border := sp.on ? st.selected_border : st.normal_border
		fill := sp.on ? st.selected : st.normal
		bw := st.nbw
		// The fills are translucent: the panel background goes under each one.
		inner := skald.Rect{b.x + bw, b.y + bw, b.w - 2 * bw, b.h - 2 * bw}
		skald.draw_rect(pt.r, b, st.bg, st.r)
		skald.draw_rect(pt.r, b, border, st.r)
		skald.draw_rect(pt.r, inner, st.bg, max(st.r - bw, 0))
		skald.draw_rect(pt.r, inner, fill, max(st.r - bw, 0))
		k: f32 = 16
		kx := sp.on ? b.x + b.w - k - 3 : b.x + 3
		knob := sp.on ? st.selected_color : skald.Color{st.fg[0] / 1.25, st.fg[1] / 1.25, st.fg[2] / 1.25, st.fg[3]}
		skald.draw_rect(pt.r, {kx, b.y + (b.h - k) / 2, k, k}, knob, st.r)
	}
	v := skald.canvas(c.ctx, paint, draw, width = PANEL_SWITCH.x, height = PANEL_SWITCH.y,
		min_w = PANEL_SWITCH.x, min_h = PANEL_SWITCH.y)
	z := skald.zone(c.ctx, v, zid)
	if skald.widget_clicked(c.ctx, zid, .Left) {
		panel_send(c.p, "toggle", id, on ? "false" : "true")
	}
	return z
}

// ---- slider ---------------------------------------------------------------------------

@(private = "file")
Slider_Paint :: struct {
	frac:    f32,
	hovered: bool,
	st:      Panel_Style,
}

// panel_slider is PanelSlider: 4 px track, fg fill, 14 px thumb with a 2 px
// background ring (16 px while hovered). Dragging sends "change" at most every
// 40 ms and once more on release.
@(private = "file")
panel_slider :: proc(c: ^Panel_Ctx, n: json.Object, w: f32) -> skald.View {
	p := c.p
	id := jstr(n, "id")
	lo, hi := jnum(n, "min", 0), jnum(n, "max", 1)
	step := jnum(n, "step", 0)
	value := jnum(n, "value", lo)
	zid := skald.hash_id(fmt.tprintf("shellder-panel-slider\x00%s", id))
	hovered := skald.widget_hovered(c.ctx, zid)
	in_ := c.ctx.input
	rect := c.ctx.widgets.states[zid].last_rect
	THUMB :: 7

	if in_.mouse_pressed[.Left] && hovered && p.drag_id == "" {
		p.drag_id = strings.clone(id)
	}
	dragging := p.drag_id == id
	if dragging {
		if rect.w > 2 * THUMB {
			f := clamp((in_.mouse_pos.x - rect.x - THUMB) / (rect.w - 2 * THUMB), 0, 1)
			v := lo + f * (hi - lo)
			if step > 0 { v = lo + f32(int((v - lo) / step + 0.5)) * step }
			p.drag_value = clamp(v, lo, hi)
		}
		value = p.drag_value
		released := !in_.mouse_buttons[.Left]
		if released || (p.drag_value != p.drag_sent && time.tick_since(p.drag_at) >= PANEL_CHANGE_INTERVAL) {
			panel_send(p, "change", id, fmt.tprintf("%.4f", p.drag_value))
			p.drag_sent, p.drag_at = p.drag_value, time.tick_now()
		}
		if released {
			delete(p.drag_id)
			p.drag_id = ""
		} else {
			p.dirty = true // follow the pointer
		}
	}

	paint := new(Slider_Paint, context.temp_allocator)
	paint^ = {frac = hi > lo ? clamp((value - lo) / (hi - lo), 0, 1) : 0, hovered = hovered || dragging, st = c.st}
	draw :: proc(sp: ^Slider_Paint, pt: skald.Canvas_Painter) {
		b, st := pt.bounds, &sp.st
		cy := b.y + b.h / 2
		// Full-width track; the thumb center travels inside it.
		x0, x1 := b.x + THUMB, b.x + b.w - THUMB
		skald.draw_rect(pt.r, {b.x, cy - 2, b.w, 4}, st.track, 2)
		tx := x0 + (x1 - x0) * sp.frac
		skald.draw_rect(pt.r, {b.x, cy - 2, tx - b.x, 4}, st.fg, 2)
		d: f32 = sp.hovered ? 16 : 14
		ring := d + 4
		skald.draw_rect(pt.r, {tx - ring / 2, cy - ring / 2, ring, ring}, st.bg, ring / 2)
		skald.draw_rect(pt.r, {tx - d / 2, cy - d / 2, d, d}, st.fg, d / 2)
	}
	v := skald.canvas(c.ctx, paint, draw, width = w, height = PANEL_SLIDER_H, min_w = w, min_h = PANEL_SLIDER_H)
	return skald.zone(c.ctx, v, zid)
}

// ---- input ---------------------------------------------------------------------------------

// panel_after_frame closes the panel on a press outside its card (ignoring the
// click that may still be in flight from the one that opened it).
panel_after_frame :: proc(app: ^App, p: ^Popup) {
	in_ := &p.win.input
	inside := rect_has(p.card, in_.mouse_pos)
	if time.tick_since(p.opened_at) > 150 * time.Millisecond && p.drag_id == "" {
		for b in skald.Mouse_Button {
			if in_.mouse_pressed[b] && !inside {
				append(&app.msgs, Msg(Panel_Dismiss{popup = p}))
				break
			}
		}
	}
	wb_set_cursor(inside ? 1 : 0)
}
