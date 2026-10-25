package shellder

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "gui:skald"

// External plugins: each folder in <config_dir>/plugins/ with a manifest.json
// (same format as Omarchy plugins). Shellder runs the `entryPoints.barWidget`
// executable as a child process and talks to it line by line:
//
//   plugin -> Shellder (stdout): one update per line. A JSON object
//     {"text", "icon", "color", "visible", "segments", "monitor", "settings"}
//     (missing fields keep their previous value; "monitor" limits the update
//     to that output's bar; "settings" is saved to the plugin's shell.json
//     entry) or any other line, which becomes the text.
//   Shellder -> plugin (stdin): one JSON event per line:
//     {"event":"config", "bar":{...}, "theme":{...}, "settings":{...}}
//         on start, on theme change and whenever its entry changes
//     {"event":"click","button":"left|middle|right","monitor":"DP-1", "bar":{...}, "item":{...}}
//     {"event":"scroll","direction":"up|down","monitor":"DP-1", "bar":{...}, "item":{...}}
//
// A process that dies is restarted with backoff (1s, 2s, 4s... up to 30s).
// README.md has the full specification.

KIND_BAR_WIDGET :: "bar-widget"

RESTART_MIN    :: time.Second
RESTART_MAX    :: 30 * time.Second
HEALTHY_UPTIME :: 30 * time.Second
MAX_LINE       :: 64 * 1024

// Segment is a button inside the item (e.g. a workspace). Clicks carry its id.
Segment :: struct {
	id, text, icon, color: string,
	tooltip: string,
	font:    string, // theme size token ("caption", "body", "iconFont"...) or px
	opacity: f32, // 0..1 (default 1)
	width:   f32, // logical px; 0 = fit the content
	image:      string, // PNG path drawn instead of icon/text (tray icons)
	image_size: f32,    // logical px of the image's square (default 12)
	passive:    bool,   // drawn only: no clicks, hover or tooltip (spacers)
	margin:     f32,    // side margin when width is 0 (default 8.5, WidgetButton's)
}

// Hover_Mode comes from the manifest's barWidget.hover:
//   "tooltip" (default) Shellder shows the item/segment tooltip; the plugin
//                       still gets "hover" events
//   "event"             no Shellder tooltip: the plugin gets "hover" events
//                       (with the item rect) and shows whatever it wants
//   "none"              neither
Hover_Mode :: enum { Tooltip, Event, None }

// Panel_Mode comes from the manifest's barWidget.panel; Shellder forwards it
// in the "config" event so the plugin (or the kit) knows how to show its panel:
//   "plugin" (default) the plugin shows its own windows
//   "skald"            the plugin sends {"panel": ...} and Shellder draws it
//   "process"          the plugin shows it from a short-lived child process
Panel_Mode :: enum { Plugin, Skald, Process }
PANEL_MODE_NAMES := [Panel_Mode]string{ .Plugin = "plugin", .Skald = "skald", .Process = "process" }

// Menu_Item is one entry of the right-click menu, declared in the manifest's
// barWidget.menu or replaced at runtime with {"menu": [...]} on stdout.
// "exec" runs a shell command; otherwise {"event":"menu","id":...} goes to
// the plugin.
Menu_Item :: struct {
	id, label, icon, exec: string,
	separator: bool,
	disabled:  bool,
	checked:   int, // -1 = no check mark, 0 = unchecked, 1 = checked
}

menu_free :: proc(items: ^[dynamic]Menu_Item) {
	for it in items { delete(it.id); delete(it.label); delete(it.icon); delete(it.exec) }
	clear(items)
}

// menu_parse reads a JSON menu array into `out` (cleared first).
menu_parse :: proc(arr: json.Array, out: ^[dynamic]Menu_Item) {
	menu_free(out)
	for v in arr {
		o := v.(json.Object) or_continue
		str :: proc(o: json.Object, k: string) -> string {
			s, _ := o[k].(json.String)
			return strings.clone(s)
		}
		kind, _ := o["type"].(json.String)
		checked := -1
		if c, ok := o["checked"].(json.Boolean); ok { checked = c ? 1 : 0 }
		disabled, _ := o["disabled"].(json.Boolean)
		append(out, Menu_Item{
			id = str(o, "id"), label = str(o, "label"), icon = str(o, "icon"), exec = str(o, "exec"),
			separator = kind == "separator", disabled = disabled, checked = checked,
		})
	}
}

Plugin_View :: struct {
	text, icon, color: string,
	tooltip: string,
	font:    string, // text size: theme token or px (default "body")
	visible:  bool,
	segments: [dynamic]Segment,
}

view_free :: proc(v: ^Plugin_View) {
	delete(v.text); delete(v.icon); delete(v.color); delete(v.tooltip); delete(v.font)
	segments_clear(&v.segments)
	delete(v.segments)
}

segments_clear :: proc(segs: ^[dynamic]Segment) {
	for sg in segs {
		delete(sg.id); delete(sg.text); delete(sg.icon); delete(sg.color)
		delete(sg.tooltip); delete(sg.font); delete(sg.image)
	}
	clear(segs)
}

// plugin_view_for: what to show on output `monitor`'s bar.
plugin_view_for :: proc(p: ^Plugin, monitor: string) -> ^Plugin_View {
	if v, ok := &p.per_monitor[monitor]; ok { return v }
	return &p.view
}

Plugin :: struct {
	// manifest
	id:              string,
	name:            string,
	dir:             string,
	argv:            []string,
	default_section: Section,
	manifest_icon:   string,
	hover_mode:      Hover_Mode,
	menu:            [dynamic]Menu_Item, // manifest menu, replaced by {"menu": ...}
	panel_mode:      Panel_Mode,

	// {"panel": ...} — the description of a Shellder-drawn panel (nil: closed),
	// and where the last click came from (the panel opens next to it).
	panel_spec:    json.Value,
	panel_changed: bool,
	click_out:     i32,
	click_rect:    skald.Rect,

	// displayed state (updated by the plugin): `view` applies to every bar; an
	// update with "monitor" goes to per_monitor[monitor], which then replaces
	// `view` on that output.
	view:        Plugin_View,
	per_monitor: map[string]Plugin_View,

	// process
	pid:        i32,
	in_fd:      i32,
	out_fd:     i32,
	started_at: time.Time,
	restart_at: time.Time,
	backoff:    time.Duration,
	reaping:    bool, // exited (EOF) and not reaped yet

	// hot reload (plugins_sync)
	tree_mtime:    time.Time, // when we last (re)loaded
	pending_mtime: time.Time, // change seen, waiting for it to settle
	change_seen:   time.Time,
	line_buf:   [dynamic]u8,

	// Which bars have the pointer over the item (for the "hover" event).
	hovered_on: map[string]string, // output -> "" (not hovered) or "\x01" + hovered segment id

	// {"settings": {...}} received and not yet saved to shell.json
	// (heap; main applies and frees them).
	settings_updates: [dynamic]json.Object,
}

// ---- discovery and hot reload -----------------------------------------------
//
// plugins_sync compares <config_dir>/plugins/ with the loaded plugins — called
// at startup and every second:
//   - new folder with a valid manifest -> plugin loaded (and started)
//   - folder removed                   -> plugin stopped and unloaded
//   - any file in the folder changed   -> manifest re-read, process restarted
//     (after RELOAD_DEBOUNCE without further changes, so a file is not caught
//     half-written)
//   - id added to/removed from "disabled" -> stopped/started
// Ignores .git, __pycache__, node_modules, .cache and editor temp files: a
// plugin must not write files into its own folder or it will keep restarting.

RELOAD_DEBOUNCE :: 500 * time.Millisecond

Plugin_Set :: struct {
	plugins: [dynamic]^Plugin,
	// Folders without a valid manifest, with the tree mtime when they failed:
	// retried (and reported) only when something in them changes.
	bad_dirs: map[string]time.Time,
}

Plugin_Sync :: struct {
	start:          [dynamic]^Plugin, // start with the current config
	layout_changed: bool,             // plugins came or went: rebuild the layout
}

plugins_sync :: proc(set: ^Plugin_Set, cfg: ^Config) -> (out: Plugin_Sync) {
	out.start = make([dynamic]^Plugin, context.temp_allocator)
	dirs := plugin_dirs(cfg.plugins_dir)
	seen := make(map[string]bool, len(dirs), context.temp_allocator)
	for d in dirs { seen[d] = true }

	// Removed.
	for i := len(set.plugins) - 1; i >= 0; i -= 1 {
		p := set.plugins[i]
		if seen[p.dir] { continue }
		fmt.printfln("shellder: plugin %s removed", p.id)
		plugin_stop(p)
		ordered_remove(&set.plugins, i)
		plugin_free(p)
		out.layout_changed = true
	}
	for d in set.bad_dirs {
		if !seen[d] { delete_key(&set.bad_dirs, d) }
	}

	now := time.now()
	for d in dirs {
		p := plugin_by_dir(set, d)
		m := tree_mtime(d)

		if p == nil {
			// New (or failed before and changed since).
			if bad, was_bad := set.bad_dirs[d]; was_bad && bad == m { continue }
			q, ok := manifest_load(d)
			if ok && plugin_by_id(set, q.id) != nil {
				fmt.eprintfln("shellder: %s: duplicate id %q; ignoring", d, q.id)
				plugin_free(q)
				ok = false
			}
			if !ok {
				if _, had := set.bad_dirs[d]; !had { set.bad_dirs[strings.clone(d)] = m } else { set.bad_dirs[d] = m }
				continue
			}
			delete_key(&set.bad_dirs, d)
			q.tree_mtime = m
			append(&set.plugins, q)
			fmt.printfln("shellder: plugin %s (%s)", q.id, q.dir)
			out.layout_changed = true
			if !config_is_disabled(cfg, q.id) { append(&out.start, q) }
			continue
		}

		// Changed: wait for it to settle, then reload.
		if m != p.tree_mtime {
			if m != p.pending_mtime {
				p.pending_mtime = m
				p.change_seen = now
			} else if time.diff(p.change_seen, now) >= RELOAD_DEBOUNCE {
				p.tree_mtime = m
				p.change_seen = {}
				if plugin_reload(set, p) {
					out.layout_changed = true
					if !config_is_disabled(cfg, p.id) { append(&out.start, p) }
				}
			}
		}

		// disabled in shell.json.
		disabled := config_is_disabled(cfg, p.id)
		if disabled && plugin_running(p) {
			fmt.printfln("shellder: plugin %s disabled", p.id)
			plugin_stop(p)
		} else if !disabled && !plugin_running(p) && !slice.contains(out.start[:], p) {
			append(&out.start, p)
		}
	}
	return
}

// kit_dir: <Shellder folder>/kit, derived from the executable (build/shellder).
kit_dir :: proc() -> string {
	@(static) cached: string
	if cached != "" { return cached }
	buf: [4096]u8
	n := posix.readlink("/proc/self/exe", &buf[0], len(buf))
	exe := n > 0 ? string(buf[:n]) : ""
	dir := exe
	for _ in 0..<2 { // build/shellder -> build -> root
		if i := strings.last_index_byte(dir, '/'); i >= 0 { dir = dir[:i] }
	}
	cached = strings.concatenate({dir, "/kit"})
	return cached
}

plugin_running :: proc(p: ^Plugin) -> bool {
	return p.pid > 0 || p.restart_at != {}
}

@(private = "file")
plugin_by_dir :: proc(set: ^Plugin_Set, dir: string) -> ^Plugin {
	for p in set.plugins { if p.dir == dir { return p } }
	return nil
}

@(private = "file")
plugin_by_id :: proc(set: ^Plugin_Set, id: string) -> ^Plugin {
	for p in set.plugins { if p.id == id { return p } }
	return nil
}

// plugin_reload re-reads the manifest and stops the process (the caller
// restarts it). With an invalid manifest the plugin stays as it was. Returns
// true if it reloaded.
@(private = "file")
plugin_reload :: proc(set: ^Plugin_Set, p: ^Plugin) -> bool {
	q, ok := manifest_load(p.dir)
	if !ok {
		fmt.eprintfln("shellder: plugin %s: invalid manifest after the change; keeping the previous one", p.id)
		return false
	}
	if q.id != p.id && plugin_by_id(set, q.id) != nil {
		fmt.eprintfln("shellder: plugin %s: new id %q already exists; keeping the previous one", p.id, q.id)
		plugin_free(q)
		return false
	}
	fmt.printfln("shellder: plugin %s changed; reloading", q.id)
	plugin_stop(p)
	// Swap only what comes from the manifest; the displayed state stays until
	// the new process sends its own.
	delete(p.id); delete(p.name); delete(p.manifest_icon)
	for a in p.argv { delete(a) }
	delete(p.argv)
	if p.view.icon == "" || p.view.icon == p.manifest_icon {
		delete(p.view.icon)
		p.view.icon = strings.clone(q.manifest_icon)
	}
	p.id, p.name, p.argv = q.id, q.name, q.argv
	p.manifest_icon, p.default_section = q.manifest_icon, q.default_section
	p.hover_mode = q.hover_mode
	menu_free(&p.menu); delete(p.menu)
	p.menu = q.menu
	q.menu = {}
	p.backoff = RESTART_MIN
	p.restart_at = {}
	delete(q.dir); view_free(&q.view); delete(q.per_monitor); delete(q.line_buf)
	menu_free(&q.menu); delete(q.menu); free(q)
	return true
}

plugin_free :: proc(p: ^Plugin) {
	delete(p.id); delete(p.name); delete(p.dir)
	delete(p.manifest_icon)
	menu_free(&p.menu); delete(p.menu)
	view_free(&p.view)
	for k, &v in p.per_monitor { delete(k); view_free(&v) }
	delete(p.per_monitor)
	for a in p.argv { delete(a) }
	delete(p.argv)
	delete(p.line_buf)
	for u in p.settings_updates { json.destroy_value(u) }
	delete(p.settings_updates)
	json.destroy_value(p.panel_spec)
	free(p)
}

// plugin_dirs lists the plugin folders (symlinks to folders count: the
// plugins' `make install` points at the repository), sorted.
@(private = "file")
plugin_dirs :: proc(root: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil { return out[:] }
	for e in entries {
		is_dir := e.type == .Directory
		if e.type == .Symlink {
			if fi, serr := os.stat(e.fullpath, context.temp_allocator); serr == nil {
				is_dir = fi.type == .Directory
			}
		}
		if is_dir { append(&out, e.fullpath) }
	}
	slice.sort(out[:])
	return out[:]
}

// tree_mtime: the newest mtime of the plugin folder and everything in it.
@(private = "file")
tree_mtime :: proc(dir: string, depth := 0) -> (newest: time.Time) {
	if fi, err := os.stat(dir, context.temp_allocator); err == nil { newest = fi.modification_time }
	if depth > 8 { return }
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for e in entries {
		if ignored_name(e.name) { continue }
		m := e.modification_time
		if e.type == .Directory {
			m = tree_mtime(e.fullpath, depth + 1)
		} else if e.type == .Symlink {
			if fi, serr := os.stat(e.fullpath, context.temp_allocator); serr == nil { m = fi.modification_time }
		}
		if time.diff(newest, m) > 0 { newest = m }
	}
	return
}

@(private = "file")
ignored_name :: proc(name: string) -> bool {
	switch name {
	case ".git", "__pycache__", "node_modules", ".cache", ".venv", "4913": return true
	}
	return strings.has_suffix(name, "~") || strings.has_suffix(name, ".swp") ||
	       strings.has_suffix(name, ".swx") || strings.has_suffix(name, ".tmp") ||
	       strings.has_prefix(name, ".#")
}

@(private = "file")
manifest_load :: proc(dir: string) -> (p: ^Plugin, ok: bool) {
	path := strings.concatenate({dir, "/manifest.json"}, context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		fmt.eprintfln("shellder: %s: no manifest.json; ignoring", dir)
		return
	}
	root, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != nil {
		fmt.eprintfln("shellder: %s: invalid JSON (%v)", path, perr)
		return
	}
	m, is_obj := root.(json.Object)
	if !is_obj {
		fmt.eprintfln("shellder: %s: the manifest must be an object", path)
		return
	}
	fail :: proc(path, msg: string) { fmt.eprintfln("shellder: %s: %s", path, msg) }

	id, _ := m["id"].(json.String)
	if id == "" { fail(path, "missing \"id\""); return }

	kinds, _ := m["kinds"].(json.Array)
	has_bar := false
	for k in kinds {
		if s, _ := k.(json.String); s == KIND_BAR_WIDGET { has_bar = true }
	}
	if !has_bar {
		fail(path, "kinds does not include \"bar-widget\" (the only supported kind); ignoring")
		return
	}

	// entryPoints.barWidget: "file" (an executable) or ["cmd", "arg", ...].
	argv := make([dynamic]string)
	entry, _ := m["entryPoints"].(json.Object)
	#partial switch v in entry["barWidget"] {
	case json.String:
		append(&argv, strings.concatenate({dir, "/", v}))
	case json.Array:
		for a in v {
			s, _ := a.(json.String)
			append(&argv, strings.clone(s))
		}
	}
	if len(argv) == 0 || argv[0] == "" {
		fail(path, "missing entryPoints.barWidget (string or array)")
		return
	}

	bw, _ := m["barWidget"].(json.Object)
	section := Section.Right
	switch ds, _ := bw["defaultSection"].(json.String); ds {
	case "left":   section = .Left
	case "center": section = .Center
	}

	p = new(Plugin)
	p.id              = strings.clone(id)
	p.dir             = strings.clone(dir)
	p.argv            = argv[:]
	p.default_section = section
	p.view.visible    = true
	name, _ := m["name"].(json.String)
	p.name = strings.clone(name if name != "" else id)
	icon, _ := bw["icon"].(json.String)
	p.manifest_icon = strings.clone(icon)
	p.view.icon     = strings.clone(icon)
	switch hm, _ := bw["hover"].(json.String); hm {
	case "event": p.hover_mode = .Event
	case "none":  p.hover_mode = .None
	}
	if arr, ok := bw["menu"].(json.Array); ok { menu_parse(arr, &p.menu) }
	switch pm, _ := bw["panel"].(json.String); pm {
	case "skald":   p.panel_mode = .Skald
	case "process": p.panel_mode = .Process
	}
	p.click_out = -1
	p.pid, p.in_fd, p.out_fd = -1, -1, -1
	p.backoff = RESTART_MIN
	return p, true
}

// plugin_start starts the process and sends the "config" event (config_line)
// as the first stdin line.
plugin_start :: proc(p: ^Plugin, cfg: ^Config, config_line: string) {
	// A new process starts without a panel.
	plugin_set_panel(p, nil)
	p.panel_changed = false
	argv := make([]cstring, len(p.argv) + 1, context.temp_allocator)
	for a, i in p.argv { argv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	env := [?]cstring{
		fmt.ctprintf("SHELLDER_PLUGIN_ID=%s", p.id),
		fmt.ctprintf("SHELLDER_PLUGIN_DIR=%s", p.dir),
		fmt.ctprintf("SHELLDER_CONFIG_DIR=%s", cfg.dir),
		// Plugin support kit (kit/python/shellder_kit, ...), next to the binary.
		fmt.ctprintf("SHELLDER_KIT=%s", kit_dir()),
		nil,
	}
	cwd := strings.clone_to_cstring(p.dir, context.temp_allocator)
	pid := sh_spawn(raw_data(argv), cwd, &env[0], &p.in_fd, &p.out_fd)
	if pid < 0 {
		fmt.eprintfln("shellder: plugin %s: failed to start %v", p.id, p.argv)
		plugin_schedule_restart(p)
		return
	}
	p.pid        = pid
	p.started_at = time.now()
	p.restart_at = {}
	clear(&p.line_buf)
	plugin_send_line(p, config_line)
}

// plugin_send_line writes one stdin line without blocking: if the plugin does
// not read and the pipe fills up, the line is dropped instead of freezing the bar.
plugin_send_line :: proc(p: ^Plugin, line: string) {
	if p.in_fd < 0 || line == "" { return }
	sh_write(p.in_fd, raw_data(line), i32(len(line)))
}

// plugin_stop ends the process (SIGTERM to the group) without waiting: the pid
// goes to `zombies` and is reaped by plugins_reap.
plugin_stop :: proc(p: ^Plugin) {
	if p.pid > 0 {
		sh_kill_group(p.pid)
		if sh_reap(p.pid) == 0 { append(&zombies, p.pid) }
	}
	plugin_close_fds(p)
	p.pid = -1
	p.reaping = false
	p.restart_at = {}
	clear(&p.line_buf)
}

@(private = "file")
zombies: [dynamic]i32

plugins_reap :: proc() {
	for i := len(zombies) - 1; i >= 0; i -= 1 {
		if sh_reap(zombies[i]) != 0 { unordered_remove(&zombies, i) }
	}
}

@(private = "file")
plugin_close_fds :: proc(p: ^Plugin) {
	if p.in_fd >= 0  { posix.close(posix.FD(p.in_fd));  p.in_fd = -1 }
	if p.out_fd >= 0 { posix.close(posix.FD(p.out_fd)); p.out_fd = -1 }
}

@(private = "file")
plugin_schedule_restart :: proc(p: ^Plugin) {
	if p.started_at != {} && time.since(p.started_at) >= HEALTHY_UPTIME {
		p.backoff = RESTART_MIN
	}
	p.restart_at = time.time_add(time.now(), p.backoff)
	p.backoff = min(p.backoff * 2, RESTART_MAX)
}

// plugin_read consumes the plugin's stdout. Returns true if anything visible changed.
plugin_read :: proc(p: ^Plugin) -> (changed: bool) {
	if p.out_fd < 0 { return }
	chunk: [4096]u8
	for {
		n := posix.read(posix.FD(p.out_fd), &chunk[0], len(chunk))
		if n > 0 {
			append(&p.line_buf, ..chunk[:n])
			continue
		}
		if n == 0 {
			// EOF: the process closed stdout (usually because it exited).
			// If it only closed stdout and is still alive, end the group.
			fmt.eprintfln("shellder: plugin %s exited; restarting in %v", p.id, p.backoff)
			sh_kill_group(p.pid)
			plugin_close_fds(p)
			p.reaping = true
			plugin_schedule_restart(p)
		}
		break // n < 0: EAGAIN, nothing more for now
	}

	for {
		nl := slice.linear_search(p.line_buf[:], '\n') or_break
		line := strings.trim_right(string(p.line_buf[:nl]), "\r")
		if plugin_apply_line(p, line) { changed = true }
		remove_range(&p.line_buf, 0, nl + 1)
	}
	if len(p.line_buf) > MAX_LINE {
		fmt.eprintfln("shellder: plugin %s: line longer than %d bytes; dropped", p.id, MAX_LINE)
		clear(&p.line_buf)
	}
	return
}

// json_font accepts "font": "caption" (token) or "font": 13 (px).
@(private = "file")
json_font :: proc(v: json.Value) -> (string, bool) {
	#partial switch f in v {
	case json.String:  return f, true
	case json.Integer: return fmt.tprintf("%d", f), true
	case json.Float:   return fmt.tprintf("%d", int(f)), true
	}
	return "", false
}

@(private = "file")
plugin_apply_line :: proc(p: ^Plugin, line: string) -> bool {
	set :: proc(dst: ^string, v: string) {
		delete(dst^)
		dst^ = strings.clone(v)
	}

	trimmed := strings.trim_space(line)
	if !strings.has_prefix(trimmed, "{") {
		set(&p.view.text, line)
		return true
	}
	root, err := json.parse_string(trimmed, allocator = context.temp_allocator)
	obj, is_obj := root.(json.Object)
	if err != nil || !is_obj {
		fmt.eprintfln("shellder: plugin %s: invalid JSON: %s", p.id, trimmed)
		return false
	}

	// "monitor": the update applies only to that output's bar. The first time it
	// copies the shared state as a starting point.
	v := &p.view
	if mon, ok := obj["monitor"].(json.String); ok && mon != "" {
		if _, has := p.per_monitor[mon]; !has {
			p.per_monitor[strings.clone(mon)] = Plugin_View{
				text    = strings.clone(p.view.text),
				icon    = strings.clone(p.view.icon),
				color   = strings.clone(p.view.color),
				visible = p.view.visible,
			}
		}
		v = &p.per_monitor[mon]
	}

	if s, ok := obj["text"].(json.String);  ok { set(&v.text, s) }
	if s, ok := obj["icon"].(json.String);  ok { set(&v.icon, s) }
	if s, ok := obj["color"].(json.String); ok { set(&v.color, s) }
	if s, ok := obj["tooltip"].(json.String); ok { set(&v.tooltip, s) }
	if s, ok := json_font(obj["font"]); ok { set(&v.font, s) }
	if b, ok := obj["visible"].(json.Boolean); ok { v.visible = b }
	if arr, ok := obj["segments"].(json.Array); ok {
		segments_clear(&v.segments)
		for item in arr {
			o := item.(json.Object) or_continue
			str :: proc(o: json.Object, k: string) -> string {
				s, _ := o[k].(json.String)
				return strings.clone(s)
			}
			num :: proc(o: json.Object, k: string, def: f32) -> f32 {
				#partial switch n in o[k] {
				case json.Integer: return f32(n)
				case json.Float:   return f32(n)
				}
				return def
			}
			append(&v.segments, Segment{
				id      = str(o, "id"),
				text    = str(o, "text"),
				icon    = str(o, "icon"),
				color   = str(o, "color"),
				tooltip = str(o, "tooltip"),
				font    = strings.clone(json_font(o["font"]) or_else ""),
				opacity = clamp(num(o, "opacity", 1), 0, 1),
				width   = max(num(o, "width", 0), 0),
				image   = str(o, "image"),
				image_size = max(num(o, "imageSize", 12), 1),
				passive = (o["passive"].(json.Boolean) or_else false),
				margin  = max(num(o, "margin", 8.5), 0),
			})
		}
	}
	if arr, ok := obj["menu"].(json.Array); ok { menu_parse(arr, &p.menu) }
	if spec, has := obj["panel"]; has { plugin_set_panel(p, spec) }
	if st, ok := obj["settings"].(json.Object); ok {
		append(&p.settings_updates, json.clone_value(st, context.allocator).(json.Object))
	}
	return true
}

// plugin_tick reaps the process if it exited. Returns true when it is time to
// restart it (main calls plugin_start with the current config).
plugin_tick :: proc(p: ^Plugin) -> bool {
	if p.reaping && p.pid > 0 {
		if sh_reap(p.pid) != 0 {
			p.reaping = false
			p.pid = -1
		}
	}
	return p.pid < 0 && p.restart_at != {} && time.since(p.restart_at) >= 0
}

Plugin_Event_Kind :: enum { Click, Scroll, Hover }

// Plugin_Event carries, besides the click, where it happened: the item rect
// in the bar and the bar size (logical px, relative to the bar's top-left
// corner). With that and the bar position the plugin knows where to open a
// popup.
Plugin_Event :: struct {
	kind:     Plugin_Event_Kind,
	segment:  string, // id of the clicked segment ("" = the item)
	button:   skald.Mouse_Button,
	dir:      int,
	monitor:  string,
	item:     skald.Rect,
	bar_size: [2]u32,
}

plugin_send_event :: proc(p: ^Plugin, ev: Plugin_Event, position: Position) {
	head: string
	switch ev.kind {
	case .Click:
		btn := "left"
		#partial switch ev.button {
		case .Middle: btn = "middle"
		case .Right:  btn = "right"
		}
		head = fmt.tprintf(`"event":"click","button":"%s"`, btn)
	case .Scroll:
		head = fmt.tprintf(`"event":"scroll","direction":"%s"`, ev.dir < 0 ? "up" : "down")
	case .Hover:
		head = fmt.tprintf(`"event":"hover","hovered":%s`, ev.dir != 0 ? "true" : "false")
	}
	monitor, _ := json.marshal(ev.monitor, allocator = context.temp_allocator)
	if ev.segment != "" {
		seg, _ := json.marshal(ev.segment, allocator = context.temp_allocator)
		head = fmt.tprintf(`%s,"segment":%s`, head, string(seg))
	}
	line := fmt.tprintf(
		`{{%s,"monitor":%s,"bar":{{"position":"%s","width":%d,"height":%d}},"item":{{"x":%d,"y":%d,"width":%d,"height":%d}}}}` + "\n",
		head, string(monitor), POSITION_NAMES[position], ev.bar_size.x, ev.bar_size.y,
		int(ev.item.x), int(ev.item.y), int(ev.item.w), int(ev.item.h))
	plugin_send_line(p, line)
}
