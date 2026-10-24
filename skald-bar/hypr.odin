package skald_bar

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"

// IPC do Hyprland:
//   .socket.sock  — request/response (uma conexão por comando)
//   .socket2.sock — stream de eventos, uma linha por evento ("evento>>dados")

Hypr_Monitor :: struct {
	id:              int,
	name:            string,
	focused:         bool,
	activeWorkspace: struct { id: int, name: string },
}

Hypr_Workspace :: struct {
	id:      int,
	name:    string,
	monitor: string,
	windows: int,
}

Hypr_Window :: struct {
	title:   string,
	monitor: int,
}

Hypr :: struct {
	monitors:   []Hypr_Monitor,
	workspaces: []Hypr_Workspace, // ordenados por id
	active:     Hypr_Window,

	// Tudo acima vive nesta arena, que é zerada a cada refresh.
	arena:      mem.Dynamic_Arena,
	events_fd:  posix.FD,
	events_buf: [dynamic]u8,
}

hypr_socket_path :: proc(name: string) -> string {
	rt  := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	sig := os.get_env("HYPRLAND_INSTANCE_SIGNATURE", context.temp_allocator)
	return fmt.tprintf("%s/hypr/%s/%s", rt, sig, name)
}

hypr_connect :: proc(name: string) -> (posix.FD, bool) {
	path := hypr_socket_path(name)
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 { return -1, false }

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(path) >= len(addr.sun_path) {
		posix.close(fd)
		return -1, false
	}
	mem.copy(&addr.sun_path[0], raw_data(path), len(path))
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

// hypr_request manda um comando para o socket de request e devolve a resposta
// inteira (temp_allocator).
hypr_request :: proc(cmd: string) -> (reply: []u8, ok: bool) {
	fd := hypr_connect(".socket.sock") or_return
	defer posix.close(fd)

	if posix.write(fd, raw_data(cmd), uint(len(cmd))) < 0 { return }

	buf := make([dynamic]u8, 0, 4096, context.temp_allocator)
	chunk: [4096]u8
	for {
		n := posix.read(fd, &chunk[0], len(chunk))
		if n <= 0 { break }
		append(&buf, ..chunk[:n])
	}
	return buf[:], true
}

// hypr_focus_workspace troca de workspace. Hyprland >= 0.56 com config em Lua
// só aceita dispatch como expressão Lua (hl.dsp.*); o formato antigo
// ("dispatch workspace N") volta "error: ...". Tentamos o novo e caímos no
// antigo para versões anteriores.
hypr_focus_workspace :: proc(id: int) {
	reply, ok := hypr_request(fmt.tprintf("dispatch hl.dsp.focus({{ workspace = \"%d\" }})", id))
	if ok && strings.has_prefix(string(reply), "ok") { return }
	reply, ok = hypr_request(fmt.tprintf("dispatch workspace %d", id))
	if !ok || !strings.has_prefix(string(reply), "ok") {
		fmt.eprintfln("skald-bar: falha ao trocar para o workspace %d: %s", id, string(reply))
	}
}

hypr_init :: proc(h: ^Hypr) -> bool {
	mem.dynamic_arena_init(&h.arena)
	fd, ok := hypr_connect(".socket2.sock")
	if !ok {
		fmt.eprintln("skald-bar: sem socket de eventos do Hyprland (HYPRLAND_INSTANCE_SIGNATURE?)")
		h.events_fd = -1
		return false
	}
	posix.fcntl(fd, .SETFL, posix.fcntl(fd, .GETFL) | posix.O_NONBLOCK)
	h.events_fd = fd
	hypr_refresh(h)
	return true
}

// hypr_drain_events lê o que chegou no socket2. Devolve true se algum evento
// relevante chegou (aí vale um refresh).
hypr_drain_events :: proc(h: ^Hypr) -> (changed: bool) {
	if h.events_fd < 0 { return }
	chunk: [4096]u8
	for {
		n := posix.read(h.events_fd, &chunk[0], len(chunk))
		if n <= 0 { break }
		append(&h.events_buf, ..chunk[:n])
	}
	for {
		nl := slice.linear_search(h.events_buf[:], '\n') or_break
		line := string(h.events_buf[:nl])
		name := line
		if i := strings.index(line, ">>"); i >= 0 { name = line[:i] }
		switch name {
		case "workspace", "workspacev2", "focusedmon", "focusedmonv2",
		     "activewindow", "createworkspace", "createworkspacev2",
		     "destroyworkspace", "destroyworkspacev2", "moveworkspace",
		     "moveworkspacev2", "renameworkspace", "openwindow", "closewindow",
		     "movewindow", "movewindowv2", "monitoradded", "monitorremoved":
			changed = true
		}
		remove_range(&h.events_buf, 0, nl + 1)
	}
	return
}

hypr_refresh :: proc(h: ^Hypr) {
	mem.dynamic_arena_free_all(&h.arena)
	alloc := mem.dynamic_arena_allocator(&h.arena)

	h.monitors   = nil
	h.workspaces = nil
	h.active     = {}

	if data, ok := hypr_request("j/monitors"); ok {
		json.unmarshal(data, &h.monitors, allocator = alloc)
	}
	if data, ok := hypr_request("j/workspaces"); ok {
		json.unmarshal(data, &h.workspaces, allocator = alloc)
		slice.sort_by(h.workspaces, proc(a, b: Hypr_Workspace) -> bool { return a.id < b.id })
	}
	if data, ok := hypr_request("j/activewindow"); ok {
		json.unmarshal(data, &h.active, allocator = alloc)
	}
}

hypr_monitor :: proc(h: ^Hypr, name: string) -> (^Hypr_Monitor, bool) {
	for &m in h.monitors {
		if m.name == name { return &m, true }
	}
	return nil, false
}
