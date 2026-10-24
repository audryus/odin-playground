package shellder

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "gui:skald"

// Omarchy theme, resolved the way its shell does
// (/usr/share/omarchy/shell/Commons/{Color,Style}.qml):
//
//   palette    ~/.local/state/omarchy/current/theme/colors.toml
//   surfaces   the theme's shell.toml + ~/.config/omarchy/shell.toml on top
//              ([bar], [popups], [controls], [font])
//   font       fontconfig's "monospace" alias (what `omarchy font set`
//              changes), with the size scale derived from [font] base-size
//   corners    Hyprland's decoration:rounding
//
// Outside Omarchy (missing files) the Color.qml defaults apply. The result
// drives the bar and is sent to plugins as JSON in the "config" event so
// everything draws with the same theme.

RGBA :: [4]u8

Font_Sizes :: struct {
	caption, body_small, body, subtitle, title, heading, display, display_large: int,
	icon_small, icon, icon_large: int,
}

Omarchy_Theme :: struct {
	// base palette
	foreground, background, accent, urgent, muted: RGBA,

	bar_background, bar_text, bar_active: RGBA,
	popup_background, popup_text, popup_border: RGBA,
	popup_border_width: int,
	hover_fill, hover_border, selected_fill: RGBA,
	// Remaining control states (Style.qml: *FillFor/*BorderFor/*StateColor).
	normal_fill, normal_border, hover_color, selected_color, selected_border, pressed_fill: RGBA,
	normal_border_width, hover_border_width, selected_border_width: int,

	radius:      int,
	font_family: string, // concrete family (e.g. "JetBrainsMono Nerd Font")
	font_file:   string,
	font:        Font_Sizes,
	bar_size_horizontal, bar_size_vertical: int,
	// Omarchy bar tokens (Style.bar), already scaled by font size.
	bar_icon_slot, bar_icon_canvas, bar_icon_font, bar_status_slot: int,
}

Theme_Watch :: struct {
	paths:  [4]string,
	mtimes: [4]time.Time,
	loaded: bool,
}

theme_watch_init :: proc(tw: ^Theme_Watch) {
	home := os.get_env("HOME", context.temp_allocator)
	state := os.get_env("XDG_STATE_HOME", context.temp_allocator)
	if state == "" { state = strings.concatenate({home, "/.local/state"}, context.temp_allocator) }
	tw.paths = {
		strings.concatenate({state, "/omarchy/current/theme/colors.toml"}),
		strings.concatenate({state, "/omarchy/current/theme/shell.toml"}),
		strings.concatenate({home, "/.config/omarchy/shell.toml"}),
		strings.concatenate({home, "/.config/fontconfig/fonts.conf"}), // omarchy font set
	}
}

// theme_changed reports whether any of the files changed since the last read.
theme_changed :: proc(tw: ^Theme_Watch) -> bool {
	changed := !tw.loaded
	for p, i in tw.paths {
		m: time.Time
		if fi, err := os.stat(p, context.temp_allocator); err == nil { m = fi.modification_time }
		if m != tw.mtimes[i] { tw.mtimes[i] = m; changed = true }
	}
	tw.loaded = true
	return changed
}

// theme_load reads and resolves everything. `transparent` is shell.json's
// bar.transparent: as in Omarchy, a transparent background and the text color
// omarchy-bar-text-color picks to stay legible over the wallpaper.
theme_load :: proc(tw: ^Theme_Watch, transparent: bool, position: Position, vertical: bool) -> (t: Omarchy_Theme) {
	// --- base palette (Color.qml: loadColors)
	t.foreground = {0xca, 0xcc, 0xcc, 0xff}
	t.background = {0x10, 0x13, 0x15, 0xff}
	t.accent     = {0xca, 0xcc, 0xcc, 0xff}
	t.urgent     = {0xa5, 0x55, 0x55, 0xff}
	t.muted      = {0x70, 0x78, 0x80, 0xff}
	if data, err := os.read_entire_file(tw.paths[0], context.temp_allocator); err == nil {
		load_palette(&t, string(data))
	}

	// --- theme + user shell.toml
	sv := make(map[string]string, 128, context.temp_allocator)
	for i in 1..=2 {
		if data, err := os.read_entire_file(tw.paths[i], context.temp_allocator); err == nil {
			parse_shell(string(data), &sv)
		}
	}
	r := Resolver{sv = sv, t = &t}

	t.bar_background   = composed(&r, "bar.background", "bar.background-alpha", t.background, 1)
	t.bar_text         = flat_color(&r, pick(&r, "bar.text"), t.foreground)
	t.bar_active       = flat_color(&r, pick(&r, "bar.active"), t.urgent)
	t.popup_background = composed(&r, "popups.background", "popups.background-alpha", t.background, 1)
	t.popup_text       = flat_color(&r, pick(&r, "popups.text"), t.foreground)
	t.popup_border     = composed(&r, "popups.border", "popups.border-alpha", t.accent, 1)

	hover := flat_color(&r, pick(&r, "controls.hover-cursor-color"), t.foreground)
	t.hover_fill   = with_alpha(hover, num(&r, "controls.hover-cursor-fill-alpha", 0.08))
	t.hover_border = with_alpha(flat_color(&r, pick(&r, "controls.hover-cursor-border"), hover),
		num(&r, "controls.hover-cursor-border-alpha", 0.25))
	sel := flat_color(&r, pick(&r, "controls.selected-color"), t.foreground)
	t.selected_fill = with_alpha(sel, num(&r, "controls.selected-fill-alpha", 0.18))
	t.hover_color   = hover
	t.selected_color = sel
	t.selected_border = with_alpha(flat_color(&r, pick(&r, "controls.selected-border"), sel),
		num(&r, "controls.selected-border-alpha", 1))
	normal := flat_color(&r, pick(&r, "controls.normal-color"), t.foreground)
	t.normal_fill   = with_alpha(normal, num(&r, "controls.normal-fill-alpha", 0.04))
	t.normal_border = with_alpha(flat_color(&r, pick(&r, "controls.normal-border"), normal),
		num(&r, "controls.normal-border-alpha", 0.4))
	t.pressed_fill  = with_alpha(hover, num(&r, "controls.pressed-fill-alpha", 0.22))
	t.normal_border_width   = int(num(&r, "controls.normal-border-width", 1))
	t.hover_border_width    = int(num(&r, "controls.hover-cursor-border-width", f64(t.normal_border_width)))
	t.selected_border_width = int(num(&r, "controls.selected-border-width", 0))

	// --- typography (Style.qml: font)
	base := max(1.0, num(&r, "font.base-size", 12))
	px :: proc(base, mult: f64) -> int { return max(1, int(math.round(base * mult))) }
	tok :: proc(r: ^Resolver, key: string, def: int) -> int {
		n := num(r, strings.concatenate({"font.", key}, context.temp_allocator), 0)
		return n > 0 ? int(math.round(n)) : def
	}
	t.font.caption       = tok(&r, "caption",       px(base, 0.833))
	t.font.body_small    = tok(&r, "body-small",    px(base, 0.917))
	t.font.body          = tok(&r, "body",          px(base, 1.0))
	t.font.subtitle      = tok(&r, "subtitle",      px(base, 1.083))
	t.font.title         = tok(&r, "title",         px(base, 1.167))
	t.font.heading       = tok(&r, "heading",       px(base, 1.333))
	t.font.display       = tok(&r, "display",       px(base, 2.0))
	t.font.display_large = tok(&r, "display-large", px(base, 2.333))
	t.font.icon_small    = tok(&r, "icon-small",    t.font.body_small)
	t.font.icon          = tok(&r, "icon",          t.font.title)
	t.font.icon_large    = tok(&r, "icon-large",    px(base, 1.5))

	// --- bar size (Style.qml: barToken)
	scale := max(1.0 / 12, base / 12)
	bar_tok :: proc(r: ^Resolver, key: string, def, scale: f64) -> int {
		n := num(r, key, def)
		if n <= 0 { n = def }
		if boolean(r, "bar.scale-with-font", true) { n *= scale }
		return max(1, int(math.round(n)))
	}
	t.bar_size_horizontal = bar_tok(&r, "bar.size-horizontal", 26, scale)
	t.bar_size_vertical   = bar_tok(&r, "bar.size-vertical",   28, scale)
	t.bar_icon_slot       = bar_tok(&r, "bar.icon-slot",       27, scale)
	t.bar_icon_canvas     = bar_tok(&r, "bar.icon-canvas",     16, scale)
	t.bar_icon_font       = bar_tok(&r, "bar.icon-font",       13, scale)
	t.bar_status_slot     = bar_tok(&r, "bar.status-slot",     21, scale)

	// --- Hyprland: corners and default popup border width
	t.radius = hypr_int_option("decoration:rounding", 0)
	t.popup_border_width = int(num(&r, "popups.border-width", f64(hypr_int_option("general:border_size", 1))))

	if transparent {
		t.bar_background[3] = 0
		size := vertical ? t.bar_size_vertical : t.bar_size_horizontal
		t.bar_text = transparent_text_color(position, size, t.bar_text, t.background)
	}

	// --- font: the monospace alias
	t.font_family, t.font_file = resolve_font("monospace")
	return
}

// theme_to_skald builds the Skald theme for the bar.
theme_to_skald :: proc(t: ^Omarchy_Theme) -> skald.Theme {
	th := skald.theme_dark()
	th.color.bg         = to_color(t.bar_background)
	th.color.surface    = to_color(t.hover_fill)
	th.color.elevated   = to_color(t.popup_background)
	th.color.border     = to_color(t.hover_border)
	th.color.fg         = to_color(t.bar_text)
	th.color.fg_muted   = to_color(t.muted)
	th.color.primary    = to_color(t.accent)
	th.color.on_primary = to_color(t.background)
	th.color.selection  = to_color(t.selected_fill)
	th.color.danger     = to_color(t.urgent)
	th.color.warning    = to_color(t.bar_active)
	th.font.size_xs      = f32(t.font.caption)
	th.font.size_sm      = f32(t.font.body_small)
	th.font.size_md      = f32(t.font.body)
	th.font.size_lg      = f32(t.font.title)
	th.font.size_xl      = f32(t.font.heading)
	th.font.size_display = f32(t.font.display)
	r := f32(t.radius)
	th.radius.sm, th.radius.md, th.radius.lg = r, r, r
	return th
}

// theme_json serializes the theme for the plugins' "config" event.
theme_json :: proc(t: ^Omarchy_Theme, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	h :: proc(c: RGBA) -> string { return fmt.tprintf("#%02x%02x%02x%02x", c[0], c[1], c[2], c[3]) }
	q := proc(s: string) -> string {
		out, _ := json.marshal(s, allocator = context.temp_allocator)
		return string(out)
	}
	f := t.font
	fmt.sbprintf(&b, `{{"font":{{"family":%s,"sizes":{{"caption":%d,"bodySmall":%d,"body":%d,"subtitle":%d,"title":%d,"heading":%d,"display":%d,"displayLarge":%d,"iconSmall":%d,"icon":%d,"iconLarge":%d}}}},`,
		q(t.font_family), f.caption, f.body_small, f.body, f.subtitle, f.title, f.heading,
		f.display, f.display_large, f.icon_small, f.icon, f.icon_large)
	fmt.sbprintf(&b, `"radius":%d,`, t.radius)
	fmt.sbprintf(&b, `"colors":{{"foreground":"%s","background":"%s","accent":"%s","urgent":"%s","muted":"%s"}},`,
		h(t.foreground), h(t.background), h(t.accent), h(t.urgent), h(t.muted))
	fmt.sbprintf(&b, `"bar":{{"background":"%s","text":"%s","active":"%s","sizeHorizontal":%d,"sizeVertical":%d,"iconSlot":%d,"iconCanvas":%d,"iconFont":%d,"statusSlot":%d}},`,
		h(t.bar_background), h(t.bar_text), h(t.bar_active), t.bar_size_horizontal, t.bar_size_vertical,
		t.bar_icon_slot, t.bar_icon_canvas, t.bar_icon_font, t.bar_status_slot)
	fmt.sbprintf(&b, `"popup":{{"background":"%s","text":"%s","border":"%s","borderWidth":%d}},`,
		h(t.popup_background), h(t.popup_text), h(t.popup_border), t.popup_border_width)
	fmt.sbprintf(&b, `"controls":{{"normal":"%s","normalBorder":"%s","normalBorderWidth":%d,"hover":"%s","hoverBorder":"%s","hoverBorderWidth":%d,"hoverColor":"%s","selected":"%s","selectedBorder":"%s","selectedBorderWidth":%d,"selectedColor":"%s","pressed":"%s"}}}}`,
		h(t.normal_fill), h(t.normal_border), t.normal_border_width,
		h(t.hover_fill), h(t.hover_border), t.hover_border_width, h(t.hover_color),
		h(t.selected_fill), h(t.selected_border), t.selected_border_width, h(t.selected_color),
		h(t.pressed_fill))
	return strings.to_string(b)
}

to_color :: proc(c: RGBA) -> skald.Color {
	return skald.rgba(u32(c[0]) << 24 | u32(c[1]) << 16 | u32(c[2]) << 8 | u32(c[3]))
}

// font_px resolves a size requested by a plugin: an Omarchy type-scale token
// ("caption", "bodySmall", "body", "title", "icon", "iconFont"...) or px.
font_px :: proc(t: ^Omarchy_Theme, spec: string, def: int) -> int {
	f := t.font
	switch spec {
	case "":             return def
	case "caption":      return f.caption
	case "bodySmall":    return f.body_small
	case "body":         return f.body
	case "subtitle":     return f.subtitle
	case "title":        return f.title
	case "heading":      return f.heading
	case "display":      return f.display
	case "displayLarge": return f.display_large
	case "iconSmall":    return f.icon_small
	case "icon":         return f.icon
	case "iconLarge":    return f.icon_large
	case "iconFont":     return t.bar_icon_font
	}
	if n, ok := strconv.parse_int(spec); ok && n > 0 { return n }
	return def
}

// color_by_name resolves the colors a plugin may ask for: "#rrggbb[aa]" or a
// theme role.
color_by_name :: proc(t: ^Omarchy_Theme, name: string) -> (skald.Color, bool) {
	switch name {
	case "", "foreground", "fg", "text": return to_color(t.bar_text), true
	case "muted":                        return to_color(t.muted), true
	case "accent":                       return to_color(t.accent), true
	case "urgent", "danger":             return to_color(t.urgent), true
	case "active":                       return to_color(t.bar_active), true
	}
	if c, ok := parse_color(name); ok { return to_color(c), true }
	return {}, false
}

// ---------------------------------------------------------------------------

@(private = "file")
load_palette :: proc(t: ^Omarchy_Theme, text: string) {
	found_fg, found_bg, found_accent, found_muted := false, false, false, false
	c0, c4, c7, c8: Maybe(RGBA)
	it := text
	for line in strings.split_lines_iterator(&it) {
		eq := strings.index_byte(line, '=')
		if eq < 0 { continue }
		key := strings.trim_space(line[:eq])
		val := strings.trim(strings.trim_space(line[eq+1:]), "\"'")
		if !strings.has_prefix(val, "#") || len(val) < 7 { continue }
		c, ok := parse_color(val[:7])
		if !ok { continue }
		switch key {
		case "foreground":      t.foreground = c; found_fg = true
		case "background":      t.background = c; found_bg = true
		case "accent":          t.accent = c; found_accent = true
		case "muted":           t.muted = c; found_muted = true
		case "color0":          c0 = c
		case "color4":          c4 = c
		case "color7":          c7 = c
		case "color8":          c8 = c
		case "red", "color1":   t.urgent = c
		}
	}
	if v, ok := c0.?; ok && !found_bg     { t.background = v }
	if v, ok := c7.?; ok && !found_fg     { t.foreground = v }
	if v, ok := c4.?; ok && !found_accent { t.accent = v }
	if !found_muted {
		t.muted = t.foreground
		if v, ok := c8.?; ok { t.muted = v }
	}
}

// parse_shell: the same lenient reader as Color.qml (strings, numbers, width
// lists and bare words; only inside sections).
@(private = "file")
parse_shell :: proc(text: string, out: ^map[string]string) {
	section := ""
	it := text
	for raw in strings.split_lines_iterator(&it) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' { continue }
		if line[0] == '[' {
			end := strings.index_byte(line, ']')
			if end > 0 { section = line[1:end] }
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 || section == "" { continue }
		key := strings.trim_space(line[:eq])
		val := strings.trim_space(line[eq+1:])
		if len(val) > 0 && (val[0] == '"' || val[0] == '\'') {
			end := strings.index_byte(val[1:], val[0])
			if end < 0 { continue }
			val = val[1:][:end]
		} else if hash := strings.index_byte(val, '#'); hash >= 0 {
			val = strings.trim_space(val[:hash])
		}
		out[strings.concatenate({section, ".", key}, context.temp_allocator)] = val
	}
}

@(private = "file")
Resolver :: struct {
	sv: map[string]string,
	t:  ^Omarchy_Theme,
}

@(private = "file")
pick :: proc(r: ^Resolver, key: string) -> string { return r.sv[key] }

@(private = "file")
num :: proc(r: ^Resolver, key: string, def: f64) -> f64 {
	v, ok := r.sv[key]
	if !ok { return def }
	// Width lists ("2 4"): the first number wins.
	if sp := strings.index_byte(v, ' '); sp >= 0 { v = v[:sp] }
	n, nok := strconv.parse_f64(v)
	return nok ? n : def
}

@(private = "file")
boolean :: proc(r: ^Resolver, key: string, def: bool) -> bool {
	switch strings.to_lower(r.sv[key], context.temp_allocator) {
	case "true", "1", "yes", "on":  return true
	case "false", "0", "no", "off": return false
	}
	return def
}

// flat_color resolves a shell.toml color value: a role (foreground,
// accent...), a reference to another key ("hyprland.active-border"), a color
// (#rgb, #rrggbb[aa], rgb(...), rgba(...)) or a gradient (first stop wins).
@(private = "file")
flat_color :: proc(r: ^Resolver, value: string, fallback: RGBA, depth := 0) -> RGBA {
	v := strings.trim_space(value)
	if v == "" || depth > 8 { return fallback }
	// First token that is not a gradient angle.
	for part in strings.fields(v, context.temp_allocator) {
		if strings.has_suffix(part, "deg") { continue }
		v = part
		break
	}
	if ref, ok := r.sv[strings.to_lower(v, context.temp_allocator)]; ok && ref != v {
		return flat_color(r, ref, fallback, depth + 1)
	}
	switch strings.to_lower(v, context.temp_allocator) {
	case "foreground", "text": return r.t.foreground
	case "accent":             return r.t.accent
	case "urgent":             return r.t.urgent
	case "muted":              return r.t.muted
	case "background":         return r.t.background
	case "transparent":        return {0, 0, 0, 0}
	}
	if c, ok := parse_color(v); ok { return c }
	return fallback
}

@(private = "file")
composed :: proc(r: ^Resolver, color_key, alpha_key: string, fallback: RGBA, alpha_def: f64) -> RGBA {
	c := flat_color(r, pick(r, color_key), fallback)
	return with_alpha(c, num(r, alpha_key, alpha_def))
}

@(private = "file")
with_alpha :: proc(c: RGBA, a: f64) -> RGBA {
	out := c
	out[3] = u8(math.round(clamp(a, 0, 1) * 255))
	return out
}

parse_color :: proc(s: string) -> (c: RGBA, ok: bool) {
	hex_byte :: proc(s: string) -> (u8, bool) {
		n, nok := strconv.parse_u64(s, 16)
		return u8(n), nok && len(s) == 2
	}
	v := strings.trim_space(s)
	lower := strings.to_lower(v, context.temp_allocator)
	switch {
	case strings.has_prefix(lower, "rgba(") && strings.has_suffix(lower, ")"):
		v = v[5:len(v)-1]
	case strings.has_prefix(lower, "rgb(") && strings.has_suffix(lower, ")"):
		inner := v[4:len(v)-1]
		if strings.contains(inner, ",") {
			parts := strings.split(inner, ",", context.temp_allocator)
			if len(parts) != 3 { return }
			for p, i in parts {
				n, nok := strconv.parse_u64(strings.trim_space(p))
				if !nok || n > 255 { return }
				c[i] = u8(n)
			}
			c[3] = 255
			return c, true
		}
		v = inner
	case strings.has_prefix(v, "#"):
		v = v[1:]
	case:
		return
	}
	if len(v) == 3 {
		v = fmt.tprintf("%c%c%c%c%c%c", v[0], v[0], v[1], v[1], v[2], v[2])
	}
	if len(v) != 6 && len(v) != 8 { return }
	c[3] = 255
	for i in 0..<len(v)/2 {
		c[i] = hex_byte(v[i*2:][:2]) or_return
	}
	return c, true
}

// transparent_text_color: the same choice as Omarchy's Bar.qml
// (omarchy-bar-text-color <position> <size> <text> <contrast>). Without the
// script the theme color stays.
@(private = "file")
transparent_text_color :: proc(position: Position, size: int, text, contrast: RGBA) -> RGBA {
	hex :: proc(c: RGBA) -> string { return fmt.tprintf("#%02x%02x%02x", c[0], c[1], c[2]) }
	buf: [64]u8
	cmd := fmt.ctprintf("omarchy-bar-text-color %s %d '%s' '%s' 2>/dev/null",
		POSITION_NAMES[position], size, hex(text), hex(contrast))
	n := sh_capture(cmd, &buf[0], len(buf))
	if n <= 0 { return text }
	if c, ok := parse_color(strings.trim_space(string(buf[:n]))); ok { return c }
	return text
}

@(private = "file")
hypr_int_option :: proc(name: string, def: int) -> int {
	buf: [512]u8
	cmd := fmt.ctprintf("hyprctl -j getoption %s 2>/dev/null", name)
	if sh_capture(cmd, &buf[0], len(buf)) <= 0 { return def }
	Opt :: struct { int: int, set: bool }
	o: Opt
	if json.unmarshal(buf[:], &o, allocator = context.temp_allocator) != nil { return def }
	return o.int
}

// resolve_font returns (concrete family, file) via fc-match.
@(private = "file")
resolve_font :: proc(family: string) -> (name, file: string) {
	if strings.contains_any(family, "'\\") { family_bad(family); return }
	buf: [2048]u8
	cmd := fmt.ctprintf("fc-match -f '%%{{family[0]}}\\n%%{{file}}' '%s' 2>/dev/null", family)
	n := sh_capture(cmd, &buf[0], len(buf))
	if n <= 0 { return }
	out := string(buf[:n])
	nl := strings.index_byte(out, '\n')
	if nl < 0 { return }
	return strings.clone(out[:nl]), strings.clone(out[nl+1:])
}

@(private = "file")
family_bad :: proc(family: string) {
	fmt.eprintfln("shellder: invalid font name %q", family)
}

// font_em_factor reads unitsPerEm (head) and ascender/descender (hhea) from a
// TTF/OTF and returns (ascender − descender) / unitsPerEm. Skald treats `size`
// as the ascender−descender height; Qt (and Omarchy) as the em. For the bar to
// match Omarchy's text size: skald_size = em × factor.
font_em_factor :: proc(data: []u8) -> f32 {
	be16 :: proc(d: []u8, at: int) -> int {
		if at + 2 > len(d) { return 0 }
		return int(d[at]) << 8 | int(d[at+1])
	}
	be16s :: proc(d: []u8, at: int) -> int { return int(i16(u16(be16(d, at)))) }
	be32 :: proc(d: []u8, at: int) -> int { return be16(d, at) << 16 | be16(d, at+2) }

	num_tables := be16(data, 4)
	head, hhea := -1, -1
	for i in 0..<num_tables {
		rec := 12 + i * 16
		if rec + 16 > len(data) { break }
		switch string(data[rec:][:4]) {
		case "head": head = be32(data, rec + 8)
		case "hhea": hhea = be32(data, rec + 8)
		}
	}
	if head < 0 || hhea < 0 { return 1 }
	upem := be16(data, head + 18)
	extent := be16s(data, hhea + 4) - be16s(data, hhea + 6)
	if upem <= 0 || extent <= 0 { return 1 }
	return f32(extent) / f32(upem)
}
