package skald_bar

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "gui:skald"

// skald-bar — barra inferior para Hyprland/Omarchy feita com Skald.
//
// O `skald.run` usa SDL, que não sabe criar layer-surfaces. Por isso usamos o
// backend embedded do Skald: o shim em wl/ cria uma zwlr_layer_surface_v1 por
// monitor (ancorada embaixo, com exclusive zone) e nós entregamos cada uma ao
// mesmo Renderer como um swapchain a mais. Input e loop de frames são nossos;
// o resto (State/Msg/update/view) segue o modelo Elm do Skald.

BAR_HEIGHT :: 30

State :: struct {
	hypr: Hypr,
	sys:  Sysinfo,
}

Msg :: union {
	Goto_Workspace,
}

Goto_Workspace :: distinct int

// update tem um efeito colateral (o dispatch no Hyprland) — num app Skald
// normal isso seria um Command, mas o loop embedded aqui não os processa.
update :: proc(s: ^State, m: Msg) {
	switch v in m {
	case Goto_Workspace:
		hypr_focus_workspace(int(v))
	}
}

view :: proc(s: ^State, monitor: string, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	fs := th.font.size_sm

	// --- esquerda: workspaces deste monitor + título da janela ativa
	active_ws := -1
	mon_id    := -1
	if m, ok := hypr_monitor(&s.hypr, monitor); ok {
		active_ws = m.activeWorkspace.id
		mon_id    = m.id
	}

	left := make([dynamic]skald.View, context.temp_allocator)
	for ws in s.hypr.workspaces {
		if ws.monitor != monitor || ws.id < 0 { continue } // id < 0: special workspaces
		is_active := ws.id == active_ws
		append(&left, skald.button(ctx, ws.name, Goto_Workspace(ws.id),
			bg        = is_active ? th.color.primary : th.color.surface,
			fg        = is_active ? th.color.on_primary : th.color.fg,
			radius    = th.radius.sm,
			padding   = {10, 3},
			font_size = fs,
		))
	}
	if s.hypr.active.monitor == mon_id && len(s.hypr.active.title) > 0 {
		append(&left, skald.spacer(th.spacing.sm))
		append(&left, skald.text(s.hypr.active.title, th.color.fg_muted, fs,
			max_width = 480, overflow = .Ellipsis))
	}

	// --- centro: relógio
	center := skald.text(sysinfo_clock(&s.sys), th.color.fg, th.font.size_md)

	// --- direita: cpu, memória, data
	cpu_color := s.sys.cpu_pct >= 80 ? th.color.danger : th.color.fg
	right := skald.row(
		skald.text("CPU", th.color.fg_muted, fs),
		skald.text(fmt.tprintf("%d%%", s.sys.cpu_pct), cpu_color, fs),
		skald.spacer(th.spacing.md),
		skald.text("RAM", th.color.fg_muted, fs),
		skald.text(fmt.tprintf("%.1f/%.0fG", s.sys.mem_used, s.sys.mem_total), th.color.fg, fs),
		skald.spacer(th.spacing.md),
		skald.text(sysinfo_date(&s.sys), th.color.fg, fs),
		spacing     = th.spacing.xs,
		main_align  = .End,
		cross_align = .Center,
	)

	return skald.row(
		skald.flex(1, skald.row(..left[:], spacing = th.spacing.xs, cross_align = .Center)),
		center,
		skald.flex(1, right),
		height      = BAR_HEIGHT,
		padding     = th.spacing.sm,
		cross_align = .Center,
		bg          = th.color.bg,
	)
}

// ---------------------------------------------------------------------------

Bar :: struct {
	win:   ^skald.Window,
	name:  string,
	dirty: bool,
}

App :: struct {
	r:        skald.Renderer,
	r_ready:  bool,
	bars:     [WB_MAX_OUTPUTS]Bar,
	theme:    skald.Theme,
	labels:   skald.Labels,
	msgs:     [dynamic]Msg,
	state:    State,
}

mark_all_dirty :: proc(app: ^App) {
	for &b in app.bars { b.dirty = true }
}

target_for :: proc(app: ^App, w: ^skald.Window) -> ^skald.Window_Target {
	for t in app.r.targets {
		if t.platform == w { return t }
	}
	return nil
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
	})
	if !ok { return }
	b.win  = new_clone(win)
	b.name = strings.clone_from_cstring(wb_output_name(out))

	if !app.r_ready {
		app.r.lazy_present = true
		if !skald.renderer_init(&app.r, b.win) {
			fmt.eprintln("skald-bar: renderer_init falhou")
			posix.exit(1)
		}
		app.r_ready = true
	} else if !skald.renderer_add_embedded_surface(&app.r, b.win, app.theme.color.bg) {
		fmt.eprintfln("skald-bar: não consegui adicionar a surface de %s", b.name)
		free(b.win)
		delete(b.name)
		b^ = {}
		wb_output_destroy(out)
		return
	}
	fmt.printfln("skald-bar: barra em %s (%dx%d @%.0fx)", b.name, w, h, scale)
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
		fmt.printfln("skald-bar: monitor %s saiu", b.name)
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
	if skald.frame_begin(&app.r, w, app.theme.color.bg) {
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
		v := view(&app.state, b.name, &ctx)
		skald.render_view(&app.r, v, {0, 0}, {f32(w.size_logical.x), f32(w.size_logical.y)})
		skald.render_overlays(&app.r)
		skald.frame_end(&app.r)
	}
	skald.input_begin(w) // zera as bordas de input para o próximo frame
	b.dirty = false
}

main :: proc() {
	app := new(App)
	app.labels = skald.labels_en()

	tw: Theme_Watch
	app.theme, _ = theme_reload(&tw)

	if wb_init(BAR_HEIGHT, "skald-bar") == 0 { posix.exit(1) }
	hypr_init(&app.state.hypr)
	sysinfo_init(&app.state.sys)

	next_tick := time.now()
	for {
		handle_wayland_events(app)

		if hypr_drain_events(&app.state.hypr) {
			hypr_refresh(&app.state.hypr)
			mark_all_dirty(app)
		}

		if time.since(next_tick) >= 0 {
			sysinfo_tick(&app.state.sys)
			if th, changed := theme_reload(&tw); changed { app.theme = th }
			next_tick = time.time_add(next_tick, time.Second)
			if time.since(next_tick) > 0 { next_tick = time.time_add(time.now(), time.Second) }
			mark_all_dirty(app)
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
			for m in app.msgs { update(&app.state, m) }
			clear(&app.msgs)
			mark_all_dirty(app)
		}

		free_all(context.temp_allocator)

		// Espera por Wayland, eventos do Hyprland ou o próximo tick do relógio.
		any_dirty := false
		for b in app.bars { if b.win != nil && b.dirty { any_dirty = true } }
		timeout := i32(0)
		if !any_dirty {
			timeout = i32(max(time.duration_milliseconds(time.diff(time.now(), next_tick)), 0)) + 1
		}

		if wb_before_poll() < 0 { break }
		fds := [2]posix.pollfd{
			{fd = posix.FD(wb_fd()), events = {.IN}},
			{fd = app.state.hypr.events_fd, events = {.IN}},
		}
		nfds := app.state.hypr.events_fd >= 0 ? 2 : 1
		posix.poll(&fds[0], posix.nfds_t(nfds), timeout)
		if wb_after_poll(.IN in fds[0].revents ? 1 : 0) < 0 { break }
	}
	fmt.eprintln("skald-bar: conexão com o compositor caiu")
}
