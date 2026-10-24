package shellder

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// Configuração em <config_dir>/shell.json, no mesmo formato do
// ~/.config/omarchy/shell.json:
//
//   {
//     "bar": {
//       "position": "bottom",
//       "transparent": false,
//       "layout": {
//         "left":   [],
//         "center": [{"id": "shellder.clock", "format": "ddd d MMM HH:mm"}],
//         "right":  []
//       }
//     },
//     "disabled": [],
//     "version": 1
//   }
//
// Cada item do layout é {"id": ..., <preferências do plugin>}. As
// preferências vão para o plugin no evento "config"; quando o plugin manda
// {"settings": {...}} o Shellder grava de volta na entrada dele (como o
// updateEntryInline do Omarchy). config_dir é $SHELLDER_CONFIG_DIR,
// $XDG_CONFIG_HOME/shellder ou ~/.config/shellder.

Position :: enum i32 { Bottom, Top, Left, Right } // mesma ordem de WB_POS_*

POSITION_NAMES := [Position]string{
	.Bottom = "bottom",
	.Top    = "top",
	.Left   = "left",
	.Right  = "right",
}

// Numa barra vertical (position left/right), left = topo, center = meio e
// right = base.
Section :: enum { Left, Center, Right }

SECTION_NAMES := [Section]string{
	.Left   = "left",
	.Center = "center",
	.Right  = "right",
}

Config :: struct {
	dir:         string,
	plugins_dir: string,
	path:        string,
	mtime:       time.Time, // do arquivo como o Shellder o leu/gravou por último

	position:    Position,
	transparent: bool,

	// Documento inteiro: chaves que o Shellder não conhece são preservadas
	// ao gravar.
	doc: json.Object,
}

DEFAULT_SHELL_JSON :: `{
  "bar": {
    "position": "bottom",
    "transparent": false,
    "layout": {
      "left": [],
      "center": [],
      "right": []
    }
  },
  "disabled": [],
  "version": 1
}
`

config_dir :: proc() -> string {
	if d := os.get_env("SHELLDER_CONFIG_DIR", context.allocator); d != "" { return d }
	if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {
		return strings.concatenate({x, "/shellder"})
	}
	home := os.get_env("HOME", context.temp_allocator)
	return strings.concatenate({home, "/.config/shellder"})
}

config_load :: proc() -> Config {
	cfg: Config
	cfg.dir         = config_dir()
	cfg.plugins_dir = strings.concatenate({cfg.dir, "/plugins"})
	cfg.path        = strings.concatenate({cfg.dir, "/shell.json"})

	if !os.exists(cfg.path) {
		os.make_directory_all(cfg.plugins_dir)
		if err := os.write_entire_file(cfg.path, transmute([]u8)string(DEFAULT_SHELL_JSON)); err != nil {
			fmt.eprintfln("shellder: não consegui criar %s: %v", cfg.path, err)
		} else {
			fmt.printfln("shellder: config padrão criada em %s", cfg.path)
		}
		old := strings.concatenate({cfg.dir, "/bar.toml"}, context.temp_allocator)
		if os.exists(old) {
			fmt.eprintfln("shellder: %s não é mais lido; a config agora é %s", old, cfg.path)
		}
	}
	config_read(&cfg)
	return cfg
}

// config_read (re)lê o arquivo. Em erro mantém o documento anterior (ou o
// padrão, na primeira leitura).
config_read :: proc(cfg: ^Config) -> bool {
	if fi, err := os.stat(cfg.path, context.temp_allocator); err == nil {
		cfg.mtime = fi.modification_time
	}
	data, rerr := os.read_entire_file(cfg.path, context.temp_allocator)
	src := string(data)
	if rerr != nil {
		fmt.eprintfln("shellder: não li %s (%v)", cfg.path, rerr)
		src = DEFAULT_SHELL_JSON
	}
	root, perr := json.parse_string(src)
	obj, is_obj := root.(json.Object)
	if perr != nil || !is_obj {
		fmt.eprintfln("shellder: %s inválido (%v)", cfg.path, perr)
		if cfg.doc != nil { return false }
		root, _ = json.parse_string(DEFAULT_SHELL_JSON)
		obj = root.(json.Object)
	}
	if cfg.doc != nil { json.destroy_value(cfg.doc) }
	cfg.doc = obj

	bar := config_bar(cfg)
	cfg.position = .Bottom
	if name, ok := bar["position"].(json.String); ok {
		found := false
		for n, p in POSITION_NAMES {
			if n == name { cfg.position = p; found = true }
		}
		if !found { fmt.eprintfln("shellder: position %q inválida (bottom, top, left, right)", name) }
	}
	cfg.transparent, _ = bar["transparent"].(json.Boolean)
	return true
}

// config_set_transparent grava bar.transparent (o duplo clique na barra).
config_set_transparent :: proc(cfg: ^Config, v: bool) {
	bar := config_bar(cfg)
	if _, had := bar["transparent"]; had {
		bar["transparent"] = json.Boolean(v)
	} else {
		bar[strings.clone("transparent")] = json.Boolean(v)
	}
	cfg.transparent = v
	config_save(cfg)
}

// config_changed_on_disk diz se o arquivo mudou desde a última leitura/gravação.
config_changed_on_disk :: proc(cfg: ^Config) -> bool {
	fi, err := os.stat(cfg.path, context.temp_allocator)
	return err == nil && fi.modification_time != cfg.mtime
}

config_bar :: proc(cfg: ^Config) -> ^json.Object {
	if _, ok := cfg.doc["bar"].(json.Object); !ok {
		cfg.doc[strings.clone("bar")] = make(json.Object)
	}
	return &(&cfg.doc["bar"]).(json.Object)
}

config_section :: proc(cfg: ^Config, s: Section) -> ^json.Array {
	bar := config_bar(cfg)
	if _, ok := bar["layout"].(json.Object); !ok {
		bar[strings.clone("layout")] = make(json.Object)
	}
	layout := &(&bar["layout"]).(json.Object)
	name := SECTION_NAMES[s]
	if _, ok := layout[name].(json.Array); !ok {
		layout[strings.clone(name)] = make(json.Array)
	}
	return &(&layout[name]).(json.Array)
}

entry_id :: proc(v: json.Value) -> string {
	#partial switch e in v {
	case json.Object: if id, ok := e["id"].(json.String); ok { return id }
	case json.String: return e // aceita o id solto também
	}
	return ""
}

// config_entry devolve a entrada do plugin `id` no layout.
config_entry :: proc(cfg: ^Config, id: string) -> (^json.Object, bool) {
	for s in Section {
		for &v in config_section(cfg, s) {
			if entry_id(v) != id { continue }
			if _, is_obj := v.(json.Object); !is_obj {
				// id solto vira objeto para poder guardar preferências.
				json.destroy_value(v)
				o := make(json.Object)
				o[strings.clone("id")] = json.String(strings.clone(id))
				v = o
			}
			return &v.(json.Object), true
		}
	}
	return nil, false
}

config_add_entry :: proc(cfg: ^Config, s: Section, id: string) {
	o := make(json.Object)
	o[strings.clone("id")] = json.String(strings.clone(id))
	append(config_section(cfg, s), o)
}

config_is_disabled :: proc(cfg: ^Config, id: string) -> bool {
	list, _ := cfg.doc["disabled"].(json.Array)
	for v in list {
		if s, ok := v.(json.String); ok && s == id { return true }
	}
	return false
}

// config_entry_settings_json serializa a entrada do plugin sem o "id".
config_entry_settings_json :: proc(cfg: ^Config, id: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	entry, ok := config_entry(cfg, id)
	if !ok {
		strings.write_string(&b, "{}")
		return strings.to_string(b)
	}
	tmp := make(json.Object, len(entry), context.temp_allocator)
	for k, v in entry { if k != "id" { tmp[k] = v } }
	write_json(&b, tmp, 0, compact = true)
	return strings.to_string(b)
}

// config_merge_settings grava na entrada do plugin as preferências que ele
// mandou. Valores null apagam a chave.
config_merge_settings :: proc(cfg: ^Config, id: string, settings: json.Object) -> bool {
	entry, ok := config_entry(cfg, id)
	if !ok { return false }
	for k, v in settings {
		if k == "id" { continue }
		_, is_null := v.(json.Null)
		if old, had := entry[k]; had {
			json.destroy_value(old)
			if is_null {
				dk, _ := delete_key(entry, k)
				delete(dk)
			} else {
				entry[k] = json.clone_value(v)
			}
		} else if !is_null {
			entry[strings.clone(k)] = json.clone_value(v)
		}
	}
	return true
}

config_save :: proc(cfg: ^Config) {
	b := strings.builder_make(context.temp_allocator)
	write_json(&b, cfg.doc, 0)
	strings.write_byte(&b, '\n')
	tmp := strings.concatenate({cfg.path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, b.buf[:]); err != nil {
		fmt.eprintfln("shellder: não consegui gravar %s: %v", cfg.path, err)
		return
	}
	if err := os.rename(tmp, cfg.path); err != nil {
		fmt.eprintfln("shellder: não consegui gravar %s: %v", cfg.path, err)
		return
	}
	if fi, err := os.stat(cfg.path, context.temp_allocator); err == nil {
		cfg.mtime = fi.modification_time
	}
}

// ---------------------------------------------------------------------------

// Ordem das chaves ao gravar: as conhecidas primeiro, como no shell.json do
// Omarchy, depois as demais em ordem alfabética.
@(private = "file")
KEY_ORDER := [?]string{"id", "bar", "position", "transparent", "layout", "left", "center", "right"}

@(private = "file")
key_rank :: proc(k: string) -> int {
	for o, i in KEY_ORDER { if o == k { return i } }
	return len(KEY_ORDER)
}

write_json :: proc(b: ^strings.Builder, v: json.Value, indent: int, compact := false) {
	nl :: proc(b: ^strings.Builder, indent: int, compact: bool) {
		if compact { return }
		strings.write_byte(b, '\n')
		for _ in 0..<indent { strings.write_string(b, "  ") }
	}
	switch x in v {
	case json.Null:    strings.write_string(b, "null")
	case json.Boolean: strings.write_string(b, x ? "true" : "false")
	case json.Integer: fmt.sbprintf(b, "%d", x)
	case json.Float:   fmt.sbprintf(b, "%v", x)
	case json.String:
		s, _ := json.marshal(x, allocator = context.temp_allocator)
		strings.write_string(b, string(s))
	case json.Array:
		if len(x) == 0 { strings.write_string(b, "[]"); return }
		strings.write_byte(b, '[')
		for item, i in x {
			if i > 0 { strings.write_byte(b, ',') }
			nl(b, indent + 1, compact)
			write_json(b, item, indent + 1, compact)
		}
		nl(b, indent, compact)
		strings.write_byte(b, ']')
	case json.Object:
		if len(x) == 0 { strings.write_string(b, "{}"); return }
		keys := make([dynamic]string, 0, len(x), context.temp_allocator)
		for k in x { append(&keys, k) }
		slice.sort_by(keys[:], proc(a, b: string) -> bool {
			ra, rb := key_rank(a), key_rank(b)
			return ra < rb if ra != rb else a < b
		})
		strings.write_byte(b, '{')
		for k, i in keys {
			if i > 0 { strings.write_byte(b, ',') }
			nl(b, indent + 1, compact)
			ks, _ := json.marshal(k, allocator = context.temp_allocator)
			strings.write_string(b, string(ks))
			strings.write_string(b, compact ? ":" : ": ")
			write_json(b, x[k], indent + 1, compact)
		}
		nl(b, indent, compact)
		strings.write_byte(b, '}')
	}
}
