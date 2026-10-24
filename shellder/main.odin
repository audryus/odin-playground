package shellder

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "gui:skald"

// Shellder — uma barra para Hyprland feita com Skald. A barra é só a barra:
// vazia por padrão, tudo o que aparece nela vem de plugins (plugins.odin) —
// processos externos em qualquer linguagem, descritos por um manifest.json,
// que conversam por stdin/stdout. Visual (cores, fonte, tamanho, cantos) segue
// o tema do Omarchy (omarchy.odin), que também é repassado aos plugins.
//
// O `skald.run` usa SDL, que não sabe criar layer-surfaces. Por isso usamos o
// backend embedded do Skald: native/wlbar.c cria uma zwlr_layer_surface_v1 por
// monitor e entregamos cada uma ao mesmo Renderer como um swapchain a mais.
// Input e loop de frames são nossos.

Msg :: union {
	Plugin_Input,
}

Plugin_Input :: struct {
	plugin: ^Plugin,
	ev:     Plugin_Event, // ev.monitor no temp_allocator: update roda antes do free_all
}

// update escreve no stdin do plugin — num app Skald normal seria um Command,
// mas o loop embedded aqui não os processa.
update :: proc(app: ^App, m: Msg) {
	switch v in m {
	case Plugin_Input:
		plugin_send_event(v.plugin, v.ev, app.cfg.position)
	}
}

// ---------------------------------------------------------------------------

Bar :: struct {
	win:   ^skald.Window,
	name:  string, // nome do output (DP-1, HDMI-A-1...)
	dirty: bool,

	// Duplo clique em área vazia alterna bar.transparent (como no Omarchy).
	// O backend embedded não conta cliques, então medimos aqui.
	over_item:  bool,      // o ponteiro está sobre um item de plugin neste frame
	last_press: time.Tick, // último clique esquerdo em área vazia
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
	size:        int,    // espessura efetiva da barra
	theme_json:  string, // tema serializado para o evento "config"
	wb_position: Position, // borda em que as surfaces estão ancoradas agora
	pending_theme: bool,   // reaplicar o tema no próximo ciclo (transparência mudou)

	font:        skald.Font,
	font_file:   string, // arquivo carregado em `font`
	em_factor:   f32,    // tamanho em px do Omarchy -> size do Skald (font_em_factor)
	font_data:   [dynamic][]u8, // bytes de cada fonte carregada; vivem com o renderer
}

vertical :: proc(app: ^App) -> bool {
	return app.cfg.position == .Left || app.cfg.position == .Right
}

// build_layout monta as seções a partir de bar.layout do shell.json, na
// ordem. Plugins instalados que ainda não estão no layout (nem em
// "disabled") entram no fim da defaultSection deles e o shell.json é gravado,
// como o "omarchy plugin add --enable" faz.
build_layout :: proc(app: ^App) {
	for s in Section { clear(&app.layout[s]) }
	placed := make(map[string]bool, 16, context.temp_allocator)
	for s in Section {
		for v in config_section(&app.cfg, s) {
			id := entry_id(v)
			if id == "" || config_is_disabled(&app.cfg, id) { continue }
			if placed[id] {
				fmt.eprintfln("shellder: %q aparece mais de uma vez no layout; mantendo a primeira", id)
				continue
			}
			placed[id] = true
			found := false
			for p in app.plugins.plugins {
				if p.id == id { append(&app.layout[s], p); found = true }
			}
			if !found { fmt.eprintfln("shellder: plugin %q do shell.json não está instalado", id) }
		}
	}
	added := false
	for p in app.plugins.plugins {
		if placed[p.id] || config_is_disabled(&app.cfg, p.id) { continue }
		if _, in_layout := config_entry(&app.cfg, p.id); in_layout { continue }
		append(&app.layout[p.default_section], p)
		config_add_entry(&app.cfg, p.default_section, p.id)
		fmt.printfln("shellder: plugin %s adicionado em bar.layout.%s", p.id, SECTION_NAMES[p.default_section])
		added = true
	}
	if added { config_save(&app.cfg) }
}

// sync_plugins aplica plugins_sync: inicia os novos/recarregados e refaz o
// layout se o conjunto mudou.
sync_plugins :: proc(app: ^App) {
	res := plugins_sync(&app.plugins, &app.cfg)
	if res.layout_changed { build_layout(app) }
	for p in res.start { plugin_start(p, &app.cfg, config_line_for(app, p)) }
	if res.layout_changed || len(res.start) > 0 { mark_all_dirty(app) }
}

// config_line_for monta o evento "config" do plugin: barra, tema e as
// preferências da entrada dele no shell.json.
config_line_for :: proc(app: ^App, p: ^Plugin) -> string {
	return fmt.tprintf(`{{"event":"config","bar":{{"position":"%s","size":%d}},"theme":%s,"settings":%s}}` + "\n",
		POSITION_NAMES[app.cfg.position], app.size, app.theme_json,
		config_entry_settings_json(&app.cfg, p.id))
}

send_config_all :: proc(app: ^App) {
	for p in app.plugins.plugins { plugin_send_line(p, config_line_for(app, p)) }
}

// apply_settings_updates grava no shell.json as preferências que os plugins
// mandaram e devolve a cada um o "config" atualizado.
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
	gap := th.spacing.md

	section :: proc(app: ^App, bar: ^Bar, ctx: ^skald.Ctx(Msg), s: Section) -> []skald.View {
		out := make([dynamic]skald.View, context.temp_allocator)
		for p in app.layout[s] {
			if v, ok := view_plugin(app, p, bar, ctx); ok { append(&out, v) }
		}
		return out[:]
	}
	left   := section(app, bar, ctx, .Left)
	center := section(app, bar, ctx, .Center)
	right  := section(app, bar, ctx, .Right)

	// Três blocos: início e fim com flex(1) para o centro ficar realmente no
	// centro, qualquer que seja o tamanho dos lados.
	if vertical(app) {
		return skald.col(
			skald.flex(1, skald.col(..left, spacing = gap, cross_align = .Center)),
			skald.col(..center, spacing = gap, cross_align = .Center),
			skald.flex(1, skald.col(..right, spacing = gap, main_align = .End, cross_align = .Center)),
			width       = f32(app.size),
			padding     = th.spacing.xs,
			cross_align = .Center,
			bg          = th.color.bg,
		)
	}
	return skald.row(
		skald.flex(1, skald.row(..left, spacing = gap, cross_align = .Center)),
		skald.row(..center, spacing = gap, cross_align = .Center),
		skald.flex(1, skald.row(..right, spacing = gap, main_align = .End, cross_align = .Center)),
		height      = f32(app.size),
		padding     = th.spacing.xs,
		cross_align = .Center,
		bg          = th.color.bg,
	)
}

view_plugin :: proc(app: ^App, p: ^Plugin, bar: ^Bar, ctx: ^skald.Ctx(Msg)) -> (skald.View, bool) {
	pv := plugin_view_for(p, bar.name)
	if !pv.visible || (pv.text == "" && pv.icon == "" && len(pv.segments) == 0) { return {}, false }
	th := ctx.theme
	om := &app.omarchy
	vert := vertical(app)

	color, cok := color_by_name(om, pv.color)
	if !cok { color = th.color.fg }
	text_size := em_size(app, om.font.body)
	icon_size := em_size(app, om.font.icon)

	parts := make([dynamic]skald.View, context.temp_allocator)

	// Ícone + texto: uma zona clicável.
	if pv.icon != "" || pv.text != "" {
		id := skald.hash_id(p.id)
		hovered := skald.widget_hovered(ctx, id)
		inner := make([dynamic]skald.View, context.temp_allocator)
		if pv.icon != "" { append(&inner, skald.text(pv.icon, color, icon_size, font = app.font)) }
		bg := hovered ? th.color.surface : skald.Color{}
		child: skald.View
		if vert {
			// Na vertical cada linha do texto vira uma linha centrada, cortada
			// na largura da barra (o clock usa "HH\n—\nmm").
			max_w := f32(app.size) - 4 * th.spacing.xs
			it := pv.text
			for line in strings.split_lines_iterator(&it) {
				append(&inner, skald.text(line, color, text_size, font = app.font,
					max_width = max_w, overflow = .Ellipsis, align = .Center))
			}
			child = skald.col(..inner[:], spacing = 0, padding = th.spacing.xs,
				cross_align = .Center, bg = bg, radius = th.radius.sm)
		} else {
			if pv.text != "" { append(&inner, skald.text(pv.text, color, text_size, font = app.font)) }
			child = skald.row(..inner[:], spacing = th.spacing.sm, padding = th.spacing.xs,
				cross_align = .Center, bg = bg, radius = th.radius.sm)
		}
		append(&parts, clickable_zone(ctx, p, bar, id, child, hovered, ""))
	}

	// Segmentos: um botão por segmento, cada um com seu id no clique.
	for sg in pv.segments {
		id := skald.hash_id(fmt.tprintf("%s\x00%s", p.id, sg.id))
		hovered := skald.widget_hovered(ctx, id)
		c := color
		if sg.color != "" {
			if sc, ok := color_by_name(om, sg.color); ok { c = sc }
		}
		c.a *= sg.opacity
		label := sg.text
		size := text_size
		if sg.icon != "" {
			label = sg.text == "" ? sg.icon : fmt.tprintf("%s %s", sg.icon, sg.text)
			if sg.text == "" { size = icon_size }
		}
		bg := hovered ? th.color.surface : skald.Color{}
		w := sg.width
		if vert { w = f32(app.size) - 2 * th.spacing.xs }
		child := skald.row(skald.text(label, c, size, font = app.font),
			width = w, height = f32(app.size) - 2 * th.spacing.xs,
			padding = w > 0 ? 0 : th.spacing.xs,
			main_align = .Center, cross_align = .Center, bg = bg, radius = th.radius.sm)
		append(&parts, clickable_zone(ctx, p, bar, id, child, hovered, sg.id))
	}

	if vert { return skald.col(..parts[:], spacing = 0, cross_align = .Center), true }
	return skald.row(..parts[:], spacing = 0, cross_align = .Center), true
}

// clickable_zone envolve `child` numa zona e manda para o plugin os cliques e o
// scroll sobre ela, com o retângulo da zona e o segmento (se houver).
clickable_zone :: proc(ctx: ^skald.Ctx(Msg), p: ^Plugin, bar: ^Bar, id: skald.Widget_ID,
                       child: skald.View, hovered: bool, segment: string) -> skald.View {
	z := skald.zone(ctx, child, id)
	if hovered { bar.over_item = true }
	ev := Plugin_Event{
		segment  = segment,
		monitor  = bar.name,
		item     = ctx.widgets.states[id].last_rect,
		bar_size = bar.win.size_logical,
	}
	for b in skald.Mouse_Button {
		if skald.widget_clicked(ctx, id, b) {
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

// apply_theme (re)lê o tema do Omarchy e propaga: cores/tamanhos da barra,
// espessura das surfaces, fonte e o evento "config" dos plugins.
apply_theme :: proc(app: ^App, tw: ^Theme_Watch) {
	app.omarchy = theme_load(tw, app.cfg.transparent, app.cfg.position, vertical(app))
	app.theme   = theme_to_skald(&app.omarchy)

	size := vertical(app) ? app.omarchy.bar_size_vertical : app.omarchy.bar_size_horizontal
	// Depois do wb_init: espessura ou borda mudaram (tema, ou bar.position no
	// shell.json) -> reancora as barras existentes.
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

// em_size converte um tamanho do Omarchy (em px, como o Qt) para o `size` do
// Skald na fonte carregada.
em_size :: proc(app: ^App, px: int) -> f32 {
	f := app.em_factor
	if f <= 0 { f = 1 }
	return f32(px) * f
}

// load_font carrega a fonte do tema no renderer, com a Inter embutida do
// Skald como fallback para glyphs que faltem nela.
load_font :: proc(app: ^App) {
	file := app.omarchy.font_file
	if file == "" {
		app.font = skald.font_default(&app.r)
		return
	}
	if file == app.font_file && app.font != 0 { return }
	data, err := os.read_entire_file(file, context.allocator)
	if err != nil {
		fmt.eprintfln("shellder: não li a fonte %s: %v", file, err)
		app.font = skald.font_default(&app.r)
		return
	}
	append(&app.font_data, data)
	app.em_factor = font_em_factor(data)
	app.font = skald.font_load(&app.r, app.omarchy.font_family, data)
	skald.font_add_fallback(&app.r, app.font, skald.font_default(&app.r))
	delete(app.font_file)
	app.font_file = strings.clone(file)
	fmt.printfln("shellder: fonte %s (%s, em ×%.3f)", app.omarchy.font_family, file, app.em_factor)
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
		// Sempre com alpha: bar.transparent pode ligar a qualquer momento.
		transparent            = true,
	})
	if !ok { return }
	b.win  = new_clone(win)
	b.name = strings.clone_from_cstring(wb_output_name(out))

	if !app.r_ready {
		app.r.lazy_present = true
		if !skald.renderer_init(&app.r, b.win) {
			fmt.eprintln("shellder: renderer_init falhou")
			posix.exit(1)
		}
		app.r_ready = true
		app.font_file = ""
		app.font = 0
		load_font(app)
	} else if !skald.renderer_add_embedded_surface(&app.r, b.win, app.theme.color.bg) {
		fmt.eprintfln("shellder: não consegui adicionar a surface de %s", b.name)
		free(b.win)
		delete(b.name)
		b^ = {}
		wb_output_destroy(out)
		return
	}
	fmt.printfln("shellder: barra em %s (%dx%d @%.0fx)", b.name, w, h, scale)
	b.dirty = true
}

bar_close :: proc(app: ^App, out: i32) {
	b := &app.bars[out]
	if b.win != nil {
		if len(app.r.targets) > 1 {
			skald.renderer_remove_embedded_surface(&app.r, b.win)
		} else {
			// Último monitor: o Skald não remove o último target, então
			// derrubamos o renderer inteiro; ele volta no próximo configure.
			skald.renderer_destroy(&app.r)
			app.r = {}
			app.r_ready = false
		}
		fmt.printfln("shellder: monitor %s saiu", b.name)
		free(b.win)
		delete(b.name)
	}
	b^ = {}
	wb_output_destroy(out)
}

handle_wayland_events :: proc(app: ^App) {
	ev: WB_Event
	for wb_next_event(&ev) != 0 {
		if ev.out < 0 || ev.out >= WB_MAX_OUTPUTS { continue }
		w := app.bars[ev.out].win
		#partial switch ev.type {
		case .Configure:
			bar_configure(app, ev.out, ev.a, ev.b)
		case .Closed:
			bar_close(app, ev.out)
		case .Enter, .Motion:
			if w != nil { skald.input_feed_pointer_motion(w, {f32(ev.x), f32(ev.y)}) }
		case .Leave:
			// Tira o ponteiro de cima de tudo para o hover sumir.
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
		v := view(app, b, &ctx)
		skald.render_view(&app.r, v, {0, 0}, {f32(w.size_logical.x), f32(w.size_logical.y)})
		skald.render_overlays(&app.r)
		skald.frame_end(&app.r)
	}
	check_double_click(app, b)
	skald.input_begin(w) // zera as bordas de input para o próximo frame
	b.dirty = false
}

// check_double_click: dois cliques esquerdos rápidos fora dos itens alternam
// a transparência da barra e gravam bar.transparent no shell.json.
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
		fmt.printfln("shellder: nenhum plugin em %s; a barra fica vazia", app.cfg.plugins_dir)
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
				fmt.println("shellder: tema recarregado")
			}
			// shell.json editado à mão: relê tudo — layout, preferências,
			// disabled, transparent e position — sem reiniciar.
			if config_changed_on_disk(&app.cfg) {
				old_pos, old_transparent := app.cfg.position, app.cfg.transparent
				if config_read(&app.cfg) {
					if app.cfg.position != old_pos || app.cfg.transparent != old_transparent {
						apply_theme(app, &tw) // tamanho/borda e fundo
					}
					sync_plugins(app)
					build_layout(app)
					send_config_all(app)
					mark_all_dirty(app)
					fmt.println("shellder: shell.json recarregado")
				}
			}
			// Plugins novos, removidos ou com arquivos alterados.
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

		if len(app.msgs) > 0 {
			for m in app.msgs { update(app, m) }
			clear(&app.msgs)
			mark_all_dirty(app)
		}

		free_all(context.temp_allocator)

		// Espera por Wayland, stdout dos plugins, a próxima checagem do tema
		// ou o próximo restart de plugin.
		wake := next_theme_check
		for p in app.plugins.plugins {
			if p.reaping { wake = time.time_add(time.now(), 100 * time.Millisecond) }
			if p.restart_at != {} && time.diff(p.restart_at, wake) > 0 { wake = p.restart_at }
		}
		any_dirty := false
		for b in app.bars { if b.win != nil && b.dirty { any_dirty = true } }
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
			fmt.eprintln("shellder: conexão com o compositor caiu")
			break
		}
		posix.poll(raw_data(fds), posix.nfds_t(len(fds)), timeout)
		if wb_after_poll(.IN in fds[0].revents ? 1 : 0) < 0 {
			fmt.eprintln("shellder: conexão com o compositor caiu")
			break
		}
	}

	for p in app.plugins.plugins { plugin_stop(p) }
}
