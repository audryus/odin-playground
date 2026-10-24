package shellder

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "gui:skald"

// Plugins externos: cada pasta em <config_dir>/plugins/ com um manifest.json
// (mesmo formato dos plugins do Omarchy). O Shellder roda o executável do
// `entryPoints.barWidget` como um processo filho e conversa por linhas:
//
//   plugin -> Shellder (stdout): uma atualização por linha. Um objeto JSON
//     {"text", "icon", "color", "visible", "segments", "monitor", "settings"}
//     (campos ausentes mantêm o valor anterior; "monitor" restringe a
//     atualização à barra desse monitor; "settings" é gravado na entrada do
//     plugin no shell.json) ou qualquer outra linha, que vira o texto.
//   Shellder -> plugin (stdin): um evento JSON por linha:
//     {"event":"config", "bar":{...}, "theme":{...}, "settings":{...}}
//         ao iniciar, ao trocar o tema e quando a entrada dele muda
//     {"event":"click","button":"left|middle|right","monitor":"DP-1", "bar":{...}, "item":{...}}
//     {"event":"scroll","direction":"up|down","monitor":"DP-1", "bar":{...}, "item":{...}}
//
// Se o processo morrer ele é reiniciado com backoff (1s, 2s, 4s... até 30s).
// O README.md tem a especificação completa.

KIND_BAR_WIDGET :: "bar-widget"

RESTART_MIN    :: time.Second
RESTART_MAX    :: 30 * time.Second
HEALTHY_UPTIME :: 30 * time.Second
MAX_LINE       :: 64 * 1024

// Segment é um botão dentro do item (ex.: um workspace). O clique informa o id.
Segment :: struct {
	id, text, icon, color: string,
	tooltip: string,
	font:    string, // token de tamanho do tema ("caption", "body", "iconFont"...) ou px
	opacity: f32, // 0..1 (padrão 1)
	width:   f32, // px lógicos; 0 = o do conteúdo
}

Plugin_View :: struct {
	text, icon, color: string,
	tooltip: string,
	font:    string, // tamanho do texto: token do tema ou px (padrão "body")
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
		delete(sg.tooltip); delete(sg.font)
	}
	clear(segs)
}

// plugin_view_for: o que mostrar na barra do monitor `monitor`.
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

	// estado exibido (atualizado pelo plugin): `view` vale para todas as
	// barras; uma atualização com "monitor" vai para per_monitor[monitor],
	// que então substitui `view` naquele monitor.
	view:        Plugin_View,
	per_monitor: map[string]Plugin_View,

	// processo
	pid:        i32,
	in_fd:      i32,
	out_fd:     i32,
	started_at: time.Time,
	restart_at: time.Time,
	backoff:    time.Duration,
	reaping:    bool, // saiu (EOF) e ainda não foi recolhido

	// hot reload (plugins_sync)
	tree_mtime:    time.Time, // da última vez que (re)carregamos
	pending_mtime: time.Time, // mudança vista, esperando assentar
	change_seen:   time.Time,
	line_buf:   [dynamic]u8,

	// Em que barras o ponteiro está sobre o item (para o evento "hover").
	hovered_on: map[string]bool,

	// {"settings": {...}} recebidos e ainda não gravados no shell.json
	// (heap; o main aplica e libera).
	settings_updates: [dynamic]json.Object,
}

// ---- descoberta e hot reload ------------------------------------------------
//
// plugins_sync compara <config_dir>/plugins/ com os plugins carregados — chamada
// na partida e a cada segundo:
//   - pasta nova com manifest válido  -> plugin carregado (e iniciado)
//   - pasta removida                  -> plugin parado e descarregado
//   - qualquer arquivo da pasta mudou -> manifest relido e processo reiniciado
//     (depois de RELOAD_DEBOUNCE sem novas mudanças, para não pegar um arquivo
//     no meio da gravação)
//   - id entrou/saiu de "disabled"    -> parado/iniciado
// Ignora .git, __pycache__, node_modules, .cache e temporários de editor: um
// plugin não deve gravar arquivos na própria pasta, ou vai se reiniciar.

RELOAD_DEBOUNCE :: 500 * time.Millisecond

Plugin_Set :: struct {
	plugins: [dynamic]^Plugin,
	// Pastas sem manifest válido, com o mtime da árvore quando falharam: só
	// tentamos (e avisamos) de novo quando algo nelas mudar.
	bad_dirs: map[string]time.Time,
}

Plugin_Sync :: struct {
	start:          [dynamic]^Plugin, // iniciar com o config atual
	layout_changed: bool,             // plugins entraram/saíram: refazer layout
}

plugins_sync :: proc(set: ^Plugin_Set, cfg: ^Config) -> (out: Plugin_Sync) {
	out.start = make([dynamic]^Plugin, context.temp_allocator)
	dirs := plugin_dirs(cfg.plugins_dir)
	seen := make(map[string]bool, len(dirs), context.temp_allocator)
	for d in dirs { seen[d] = true }

	// Removidos.
	for i := len(set.plugins) - 1; i >= 0; i -= 1 {
		p := set.plugins[i]
		if seen[p.dir] { continue }
		fmt.printfln("shellder: plugin %s removido", p.id)
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
			// Novo (ou que falhou antes e mudou desde então).
			if bad, was_bad := set.bad_dirs[d]; was_bad && bad == m { continue }
			q, ok := manifest_load(d)
			if ok && plugin_by_id(set, q.id) != nil {
				fmt.eprintfln("shellder: %s: id %q repetido; ignorando", d, q.id)
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

		// Mudou: espera assentar e recarrega.
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

		// disabled no shell.json.
		disabled := config_is_disabled(cfg, p.id)
		if disabled && plugin_running(p) {
			fmt.printfln("shellder: plugin %s desabilitado", p.id)
			plugin_stop(p)
		} else if !disabled && !plugin_running(p) && !slice.contains(out.start[:], p) {
			append(&out.start, p)
		}
	}
	return
}

// kit_dir: <pasta do Shellder>/kit, a partir do executável (build/shellder).
kit_dir :: proc() -> string {
	@(static) cached: string
	if cached != "" { return cached }
	buf: [4096]u8
	n := posix.readlink("/proc/self/exe", &buf[0], len(buf))
	exe := n > 0 ? string(buf[:n]) : ""
	dir := exe
	for _ in 0..<2 { // build/shellder -> build -> raiz
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

// plugin_reload relê o manifest e para o processo (o chamador reinicia).
// Com manifest inválido o plugin continua como estava. Devolve true se
// recarregou.
@(private = "file")
plugin_reload :: proc(set: ^Plugin_Set, p: ^Plugin) -> bool {
	q, ok := manifest_load(p.dir)
	if !ok {
		fmt.eprintfln("shellder: plugin %s: manifest inválido após a mudança; mantendo o anterior", p.id)
		return false
	}
	if q.id != p.id && plugin_by_id(set, q.id) != nil {
		fmt.eprintfln("shellder: plugin %s: novo id %q já existe; mantendo o anterior", p.id, q.id)
		plugin_free(q)
		return false
	}
	fmt.printfln("shellder: plugin %s mudou; recarregando", q.id)
	plugin_stop(p)
	// Troca só o que vem do manifest; o estado exibido fica até o processo
	// novo mandar o dele.
	delete(p.id); delete(p.name); delete(p.manifest_icon)
	for a in p.argv { delete(a) }
	delete(p.argv)
	if p.view.icon == "" || p.view.icon == p.manifest_icon {
		delete(p.view.icon)
		p.view.icon = strings.clone(q.manifest_icon)
	}
	p.id, p.name, p.argv = q.id, q.name, q.argv
	p.manifest_icon, p.default_section = q.manifest_icon, q.default_section
	p.backoff = RESTART_MIN
	p.restart_at = {}
	delete(q.dir); view_free(&q.view); delete(q.per_monitor); delete(q.line_buf); free(q)
	return true
}

plugin_free :: proc(p: ^Plugin) {
	delete(p.id); delete(p.name); delete(p.dir)
	delete(p.manifest_icon)
	view_free(&p.view)
	for k, &v in p.per_monitor { delete(k); view_free(&v) }
	delete(p.per_monitor)
	for a in p.argv { delete(a) }
	delete(p.argv)
	delete(p.line_buf)
	for u in p.settings_updates { json.destroy_value(u) }
	delete(p.settings_updates)
	free(p)
}

// plugin_dirs lista as pastas de plugins (symlinks para pastas contam: o
// `make install` dos plugins aponta para o repositório), em ordem.
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

// tree_mtime: o mtime mais recente da pasta do plugin e de tudo dentro dela.
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
		fmt.eprintfln("shellder: %s: sem manifest.json; ignorando", dir)
		return
	}
	root, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != nil {
		fmt.eprintfln("shellder: %s: JSON inválido (%v)", path, perr)
		return
	}
	m, is_obj := root.(json.Object)
	if !is_obj {
		fmt.eprintfln("shellder: %s: o manifest deve ser um objeto", path)
		return
	}
	fail :: proc(path, msg: string) { fmt.eprintfln("shellder: %s: %s", path, msg) }

	id, _ := m["id"].(json.String)
	if id == "" { fail(path, "falta \"id\""); return }

	kinds, _ := m["kinds"].(json.Array)
	has_bar := false
	for k in kinds {
		if s, _ := k.(json.String); s == KIND_BAR_WIDGET { has_bar = true }
	}
	if !has_bar {
		fail(path, "kinds não inclui \"bar-widget\" (único tipo suportado); ignorando")
		return
	}

	// entryPoints.barWidget: "arquivo" (executável) ou ["cmd", "arg", ...].
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
		fail(path, "falta entryPoints.barWidget (string ou array)")
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
	p.pid, p.in_fd, p.out_fd = -1, -1, -1
	p.backoff = RESTART_MIN
	return p, true
}

// plugin_start inicia o processo e manda o evento "config" (config_line) como
// primeira linha do stdin.
plugin_start :: proc(p: ^Plugin, cfg: ^Config, config_line: string) {
	argv := make([]cstring, len(p.argv) + 1, context.temp_allocator)
	for a, i in p.argv { argv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	env := [?]cstring{
		fmt.ctprintf("SHELLDER_PLUGIN_ID=%s", p.id),
		fmt.ctprintf("SHELLDER_PLUGIN_DIR=%s", p.dir),
		fmt.ctprintf("SHELLDER_CONFIG_DIR=%s", cfg.dir),
		// Kit de apoio a plugins (kit/python/shellder_kit, ...), ao lado do binário.
		fmt.ctprintf("SHELLDER_KIT=%s", kit_dir()),
		nil,
	}
	cwd := strings.clone_to_cstring(p.dir, context.temp_allocator)
	pid := sh_spawn(raw_data(argv), cwd, &env[0], &p.in_fd, &p.out_fd)
	if pid < 0 {
		fmt.eprintfln("shellder: plugin %s: falha ao iniciar %v", p.id, p.argv)
		plugin_schedule_restart(p)
		return
	}
	p.pid        = pid
	p.started_at = time.now()
	p.restart_at = {}
	clear(&p.line_buf)
	plugin_send_line(p, config_line)
}

// plugin_send_line escreve uma linha no stdin sem bloquear: se o plugin não
// lê e o pipe enche, a linha é descartada em vez de travar a barra.
plugin_send_line :: proc(p: ^Plugin, line: string) {
	if p.in_fd < 0 || line == "" { return }
	sh_write(p.in_fd, raw_data(line), i32(len(line)))
}

// plugin_stop encerra o processo (SIGTERM no grupo) sem esperar: o pid vai
// para `zombies` e é recolhido por plugins_reap.
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

// plugin_read consome o stdout do plugin. Devolve true se algo visível mudou.
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
			// EOF: o processo fechou o stdout (normalmente porque saiu).
			// Se ele só fechou o stdout e continua vivo, encerra o grupo.
			fmt.eprintfln("shellder: plugin %s terminou; reiniciando em %v", p.id, p.backoff)
			sh_kill_group(p.pid)
			plugin_close_fds(p)
			p.reaping = true
			plugin_schedule_restart(p)
		}
		break // n < 0: EAGAIN, nada mais por agora
	}

	for {
		nl := slice.linear_search(p.line_buf[:], '\n') or_break
		line := strings.trim_right(string(p.line_buf[:nl]), "\r")
		if plugin_apply_line(p, line) { changed = true }
		remove_range(&p.line_buf, 0, nl + 1)
	}
	if len(p.line_buf) > MAX_LINE {
		fmt.eprintfln("shellder: plugin %s: linha maior que %d bytes; descartada", p.id, MAX_LINE)
		clear(&p.line_buf)
	}
	return
}

// json_font aceita "font": "caption" (token) ou "font": 13 (px).
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
		fmt.eprintfln("shellder: plugin %s: JSON inválido: %s", p.id, trimmed)
		return false
	}

	// "monitor": a atualização vale só para a barra desse monitor. A primeira
	// vez copia o estado geral como ponto de partida.
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
			})
		}
	}
	if st, ok := obj["settings"].(json.Object); ok {
		append(&p.settings_updates, json.clone_value(st, context.allocator).(json.Object))
	}
	return true
}

// plugin_tick recolhe processos que saíram e reinicia os que já podem.
// plugin_tick recolhe o processo se ele saiu. Devolve true quando já é hora
// de reiniciá-lo (o main chama plugin_start com o config atual).
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

// Plugin_Event carrega, além do clique, onde ele aconteceu: o retângulo do
// item na barra e o tamanho da barra (px lógicos, relativos ao canto
// superior esquerdo da barra). Com isso e a posição da barra o plugin sabe
// onde abrir um popup.
Plugin_Event :: struct {
	kind:     Plugin_Event_Kind,
	segment:  string, // id do segmento clicado ("" = o item)
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
