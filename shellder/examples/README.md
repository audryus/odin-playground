# Examples

- `config/` — a working `~/.config/shellder/` (`shell.json` with the layout of
  every ported Omarchy widget, and `bar.toml`). Copy it there to start from it.
- `manifest.json` — a plugin manifest using every field Shellder reads.

## manifest.json, field by field

| Field | Values |
|---|---|
| `id` | required; the `id` used in `shell.json`'s `bar.layout` |
| `kinds` | required; must include `"bar-widget"` |
| `entryPoints.barWidget` | required; `"file"` (an executable in the folder) or `["cmd", "arg", ...]` (looked up in `PATH`); runs in the plugin folder |
| `entryPoints.panel` | panel program, same format; only with `barWidget.panel: "process"`. Started on a left click, ended when the panel is dismissed; gets `SHELLDER_PANEL=1` |
| `barWidget.icon` | initial icon (Nerd Font glyphs work) |
| `barWidget.defaultSection` | `"left"`, `"center"`, `"right"` (default) — where it goes when `shell.json` does not list it |
| `barWidget.hover` | `"tooltip"` (default), `"event"` (the plugin gets `hover` events and draws its own popup), `"none"` |
| `barWidget.panel` | `"plugin"` (default, the plugin's own window), `"skald"` (the plugin sends `{"panel": ...}` and Shellder draws it), `"process"` (a process alive only while the panel is open) |
| `barWidget.menu` | right-click menu drawn by Shellder. Entry: `id`, `label`, `icon`, `checked` (true/false shows a check mark), `disabled`, `exec` (shell command run by Shellder; without it the plugin gets `{"event":"menu","id":...}`), or `{"type":"separator"}`. The plugin can replace it at runtime with `{"menu": [...]}` |
| `name` | shown in logs (defaults to `id`) |
| `schemaVersion`, `version`, `author`, `description`, `barWidget.displayName`, `barWidget.category` | informational |

`entryPoints.panel` with any `barWidget.panel` other than `"process"` is
reported as an error in the log and ignored.
