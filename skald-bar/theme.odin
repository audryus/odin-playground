package skald_bar

import "core:os"
import "core:strings"
import "core:time"
import "gui:skald"

// Lê a paleta do tema atual do Omarchy (o mesmo arquivo que a barra do
// quickshell usa) e mapeia para os papéis do Skald. Recarrega quando o
// arquivo muda — `omarchy-theme-set` troca o tema ao vivo.

THEME_REL :: ".local/state/omarchy/current/theme/colors.toml"

Theme_Watch :: struct {
	path:  string,
	mtime: time.Time,
}

theme_path :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	return strings.concatenate({home, "/", THEME_REL})
}

// theme_reload devolve (tema, true) se o arquivo mudou desde a última leitura.
theme_reload :: proc(tw: ^Theme_Watch) -> (th: skald.Theme, changed: bool) {
	if tw.path == "" { tw.path = theme_path() }

	fi, serr := os.stat(tw.path, context.temp_allocator)
	if serr != nil {
		if tw.mtime == {} {
			tw.mtime = time.from_nanoseconds(1)
			return theme_from_palette(nil), true
		}
		return
	}
	if fi.modification_time == tw.mtime { return }
	tw.mtime = fi.modification_time

	data, err := os.read_entire_file(tw.path, context.temp_allocator)
	if err != nil { return theme_from_palette(nil), true }

	pal := make(map[string]skald.Color, 32, context.temp_allocator)
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		eq := strings.index_byte(line, '=')
		if eq < 0 { continue }
		key := strings.trim_space(line[:eq])
		val := strings.trim(strings.trim_space(line[eq+1:]), "\"")
		if c, ok := skald.hex_to_color(val); ok { pal[key] = c }
	}
	return theme_from_palette(pal), true
}

theme_from_palette :: proc(pal: map[string]skald.Color) -> skald.Theme {
	th := skald.theme_dark()
	set :: proc(dst: ^skald.Color, pal: map[string]skald.Color, keys: ..string) {
		for k in keys {
			if c, ok := pal[k]; ok { dst^ = c; return }
		}
	}
	set(&th.color.bg,         pal, "background")
	set(&th.color.surface,    pal, "lighter_background", "selection")
	set(&th.color.elevated,   pal, "selection", "lighter_background")
	set(&th.color.border,     pal, "muted")
	set(&th.color.fg,         pal, "foreground")
	set(&th.color.fg_muted,   pal, "dark_foreground", "muted")
	set(&th.color.primary,    pal, "accent")
	set(&th.color.on_primary, pal, "background")
	set(&th.color.success,    pal, "green")
	set(&th.color.warning,    pal, "yellow")
	set(&th.color.danger,     pal, "red")
	return th
}
