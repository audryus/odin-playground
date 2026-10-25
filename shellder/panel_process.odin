package shellder

import "core:fmt"
import "core:strings"
import "core:sys/posix"

// Panels in a process of their own (manifest barWidget.panel: "process" with
// entryPoints.panel). Shellder starts the panel program on a left click on
// the item and ends it (SIGTERM to its group) on the next click on the item,
// on a click on another item or on the bar's empty area, or when another
// popup opens. The program exits by itself when its window closes (Esc, a
// click outside). So a toolkit's memory is used only while the panel is on
// screen, and the bar process needs no toolkit at all.
//
// stdin: the same "config" line as the bar process (again on theme changes),
// then the "click" that opened it. stdout is read and discarded; stderr goes
// to Shellder's. It runs in the plugin folder with the bar process's
// variables plus SHELLDER_PANEL=1.

panel_proc_running :: proc(p: ^Plugin) -> bool { return p.panel_pid > 0 }

// panel_proc_toggle handles a click for a plugin with a panel program.
// Returns true when the click was for the panel (not for the bar process).
panel_proc_toggle :: proc(app: ^App, p: ^Plugin, ev: Plugin_Event) -> bool {
	if p.panel_mode != .Process || len(p.panel_argv) == 0 { return false }
	if panel_proc_running(p) {
		panel_proc_stop(p)
		return ev.button == .Left
	}
	if ev.button != .Left { return false }
	// One popup at a time (the other plugins' were dismissed by the caller).
	if app.panel != nil { panel_dismiss(app, app.panel) }
	if app.menu != nil { popup_close(app, app.menu) }
	if app.tooltip != nil { popup_close(app, app.tooltip) }
	panel_proc_start(app, p, ev)
	return true
}

@(private = "file")
panel_proc_start :: proc(app: ^App, p: ^Plugin, ev: Plugin_Event) {
	argv := make([]cstring, len(p.panel_argv) + 1, context.temp_allocator)
	for a, i in p.panel_argv { argv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	env := [?]cstring{
		fmt.ctprintf("SHELLDER_PLUGIN_ID=%s", p.id),
		fmt.ctprintf("SHELLDER_PLUGIN_DIR=%s", p.dir),
		fmt.ctprintf("SHELLDER_CONFIG_DIR=%s", app.cfg.dir),
		fmt.ctprintf("SHELLDER_KIT=%s", kit_dir()),
		"SHELLDER_PANEL=1",
		nil,
	}
	cwd := strings.clone_to_cstring(p.dir, context.temp_allocator)
	pid := sh_spawn(raw_data(argv), cwd, &env[0], &p.panel_in, &p.panel_out)
	if pid < 0 {
		fmt.eprintfln("shellder: plugin %s: failed to start the panel %v", p.id, p.panel_argv)
		return
	}
	p.panel_pid = pid
	panel_proc_send(p, config_line_for(app, p))
	panel_proc_send(p, plugin_event_line(ev, app.cfg.position))
}

panel_proc_send :: proc(p: ^Plugin, line: string) {
	if p.panel_in < 0 || line == "" { return }
	sh_write(p.panel_in, raw_data(line), i32(len(line)))
}

// panel_proc_stop ends the panel process (no-op when none is running).
panel_proc_stop :: proc(p: ^Plugin) {
	if p.panel_pid > 0 {
		sh_kill_group(p.panel_pid)
		reap_later(p.panel_pid)
	}
	if p.panel_in >= 0  { posix.close(posix.FD(p.panel_in));  p.panel_in = -1 }
	if p.panel_out >= 0 { posix.close(posix.FD(p.panel_out)); p.panel_out = -1 }
	p.panel_pid = -1
}

// panel_proc_read drains the panel's stdout; EOF means it exited (its window
// closed), and whatever is left of its group is ended.
panel_proc_read :: proc(p: ^Plugin) {
	if p.panel_out < 0 { return }
	chunk: [4096]u8
	for {
		n := posix.read(posix.FD(p.panel_out), &chunk[0], len(chunk))
		if n > 0 { continue }
		if n == 0 { panel_proc_stop(p) }
		return
	}
}
