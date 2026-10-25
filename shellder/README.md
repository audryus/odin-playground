# Shellder

A Hyprland bar written in Odin with [Skald](https://github.com/BuLEEto/Skald).
The bar is only the bar: it starts empty, and everything on it comes from
plugins written in any language.

- One bar per output (layer-shell, any edge, with an exclusive zone).
- Follows the Omarchy theme — colors, font, size, corners — and forwards the
  resolved theme to plugins so popups and the like look the same.
- Plugins are external processes described by a `manifest.json`.

## Run

```bash
make run                # first time clones Skald into vendor/, builds and runs
make install-examples   # copies the example plugins into ~/.config/shellder/plugins
pkill shellder          # quits (plugins are stopped with it)
```

The build applies `patches/` to the Skald clone in `vendor/` and recompiles
the shader with `glslc` (package `shaderc`). There is one patch today: glyphs
are blended like Qt does (in sRGB), without Skald's stem darkening — without
it the text comes out bolder and brighter than the Omarchy bar's, even with
the same font, size and color.

## Configuration

Everything lives in `~/.config/shellder/` (or `$XDG_CONFIG_HOME/shellder`, or
`$SHELLDER_CONFIG_DIR`):

```
~/.config/shellder/
├── shell.json
└── plugins/
    └── <plugin-folder>/
        └── manifest.json
```

`shell.json` has the same shape as `~/.config/omarchy/shell.json` (its `bar`
part). If missing, Shellder creates:

```json
{
  "bar": {
    "position": "bottom",
    "centerAnchor": "shellder.clock",
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
```

| Key               | Description |
|-------------------|-------------|
| `bar.position`    | `bottom`, `top`, `left` or `right` |
| `bar.centerAnchor` | Plugin id kept exactly at the bar's center (Omarchy's key): center items before it grow away to the start, items after it grow to the end, so an expanding item never moves it |
| `bar.transparent` | `true` makes the background transparent and picks the text color with `omarchy-bar-text-color`, like Omarchy. **Double click an empty area of the bar to toggle it** (saved here) |
| `bar.layout.*`    | Items of each section, in order: `{"id": "<plugin id>", <settings>}` |
| `disabled`        | ids of installed plugins that must not show nor run |

Each layout item is a **plugin id** plus its **settings**, as in Omarchy:

```json
"center": [
  {"id": "shellder.clock", "format": "ddd d MMM HH:mm", "formatAlt": "d MMMM 'W'ww yyyy"}
]
```

Settings reach the plugin in the `config` event; when the plugin changes one
(e.g. the clock's format), Shellder writes it back to the entry. An installed
plugin not yet in the layout (nor in `disabled`) is appended to its manifest
`defaultSection` and the file is saved. To remove a plugin from the bar, put
its id in `disabled`.

On a vertical bar (`left`/`right`) the sections become `left` = top,
`center` = middle and `right` = bottom; the icon goes on top and each line of
the plugin text becomes a centered line clipped to the bar width.

## Hot reload

Nothing requires restarting Shellder (checked every second):

| Change | What happens |
|--------|--------------|
| `shell.json` edited | layout, settings, `disabled`, `transparent` and `position` applied immediately |
| new folder in `plugins/` | plugin loaded, started and added to the layout |
| folder removed | plugin stopped and removed from the bar |
| any file of a plugin changes (code, manifest, rebuilt binary) | only that plugin restarts, 0.5 s after the last change |
| Omarchy theme/font | bar and plugins updated |

For plugin reload, changes in `.git`, `__pycache__`, `node_modules`,
`.cache`, `.venv` and editor temp files are ignored. **A plugin must not write
files into its own folder** or it will keep restarting — use
`SHELLDER_CONFIG_DIR`, `$XDG_STATE_HOME` or `$XDG_CACHE_HOME`.

## Theme

Shellder resolves the theme the way the Omarchy shell does
(`/usr/share/omarchy/shell/Commons/{Color,Style}.qml`):

| What            | From |
|-----------------|------|
| Palette         | `~/.local/state/omarchy/current/theme/colors.toml` (foreground, background, accent, urgent, muted, with the same `color0/4/7/8`, `red` fallbacks) |
| Surfaces        | the theme's `shell.toml` + `~/.config/omarchy/shell.toml` on top: `[bar]`, `[popups]`, `[controls]`, `[font]` (including `*-alpha` and references like `hyprland.active-border`) |
| Font            | fontconfig's `monospace` alias (what `omarchy font set` changes), with the size scale derived from `[font] base-size` |
| Size            | `[bar] size-horizontal` / `size-vertical` and the other `Style.bar` tokens, scaled by font size |
| Corners, border | Hyprland's `decoration:rounding` and `general:border_size` |

Shellder has no colors, font or size of its own: to change them, change the
Omarchy theme (or `~/.config/omarchy/shell.toml`). The files are watched:
`omarchy theme set`, `omarchy font set` and `shell.toml` edits update the bar
and plugins within a second. Outside Omarchy the `Color.qml` defaults apply.

Plugin items are drawn like Omarchy's bar buttons (`Ui/WidgetButton.qml`,
`BarIconButton.qml`): no hover background, a hand cursor over clickable items,
8.5 px text margins, icon-only items in an `iconSlot`-wide slot with the
`iconFont` size, items packed with no spacing and 8 px at both bar ends.

## Plugins

A plugin is a folder in `plugins/` with a `manifest.json` (same format as
Omarchy plugins) and an executable in any language. Shellder starts the
executable once, keeps it running and talks to it over **stdin/stdout, one
message per line**.

### manifest.json

```json
{
  "schemaVersion": 1,
  "id": "you.my-plugin",
  "name": "My plugin",
  "version": "1.0.0",
  "author": "you",
  "description": "What it does",
  "kinds": ["bar-widget"],
  "entryPoints": {
    "barWidget": ["python3", "-u", "main.py"]
  },
  "barWidget": {
    "icon": "",
    "defaultSection": "right"
  }
}
```

| Field                         | Required | Description |
|-------------------------------|:--------:|-------------|
| `id`                          | yes | Unique id; it is the `id` of the entry in `shell.json`'s `bar.layout` |
| `kinds`                       | yes | Must include `"bar-widget"` (the only supported kind for now) |
| `entryPoints.barWidget`       | yes | What to run. String: path of an executable inside the folder (needs `chmod +x` and a shebang). Array: command + arguments, looked up in `PATH` (`["node", "index.js"]`, `["./my-binary"]`) |
| `entryPoints.panel`           | no  | The panel program, same format. Requires `barWidget.panel: "process"`: Shellder runs it only while the panel is open (see *Panels in their own process*) |
| `barWidget.icon`              | no  | Initial icon: one or more characters. The Omarchy font is a Nerd Font, so Nerd Font glyphs work |
| `barWidget.defaultSection`    | no  | `left`, `center` or `right` (default `right`); on a vertical bar: top, middle, bottom |
| `barWidget.hover`             | no  | What hovering does: `"tooltip"` (default) — Shellder shows the item/segment `tooltip`; `"event"` — no Shellder tooltip, the plugin gets `hover` events and shows its own popup; `"none"` — nothing. `hover` events are sent in both `tooltip` and `event` modes |
| `barWidget.menu`              | no  | Right-click menu drawn by Shellder (see below). When set, the right click opens it instead of reaching the plugin |
| `barWidget.panel`             | no  | Who draws the plugin's panel: `"plugin"` (default) — the plugin's own window; `"skald"` — the plugin sends `{"panel": ...}` and Shellder draws it (see *Panels drawn by Shellder*); `"process"` — a process that exists only while the panel is open: with `entryPoints.panel`, Shellder starts and ends it (see *Panels in their own process*); without it, the Python kit's `SkaldPanel` draws its nodes with GTK in a child of the plugin. Forwarded to the plugin in `config` as `"panel"` |
| `name`, `version`, `author`, `description`, `schemaVersion`, `barWidget.displayName`, `barWidget.category` | no | Informational |

The process runs with the plugin folder as `cwd` and gets these variables:

| Variable              | Value |
|-----------------------|-------|
| `SHELLDER_PLUGIN_ID`  | the manifest `id` |
| `SHELLDER_PLUGIN_DIR` | the plugin folder |
| `SHELLDER_CONFIG_DIR` | Shellder's config folder |
| `SHELLDER_KIT`        | Shellder's plugin kit folder (see below) |
| `SHELLDER_PANEL`      | `1` in the `entryPoints.panel` program only |

The plugin's stderr goes to Shellder's stderr.

### Plugin → Shellder (stdout)

Each line is an update. It can be a JSON object:

```json
{"text": "23°C", "icon": "", "color": "accent", "tooltip": "Weather", "visible": true}
```

| Field      | Description |
|------------|-------------|
| `text`     | Text next to the icon (`\n` separates lines on a vertical bar) |
| `icon`     | Replaces the icon |
| `color`    | `"#rrggbb[aa]"` or a theme role: `foreground`, `muted`, `accent`, `urgent`, `active` |
| `font`     | Text size: a token of the Omarchy type scale (`caption`, `bodySmall`, `body`, `title`, `icon`, `iconFont`, ...) or px |
| `tooltip`  | Tooltip text |
| `visible`  | `false` hides the item |
| `segments` | Buttons inside the item: `[{"id": "1", "text": "1", "icon": "", "color": "accent", "opacity": 0.5, "width": 20, "font": "caption", "tooltip": "..."}]` (only `id` is required). `"image": "/path/icon.png"` draws a PNG (fit inside an `imageSize` square, default 12 logical px; give it 2× pixels for HiDPI) instead of the text; write a new file name when the picture changes, images are cached by path. `"margin": 6` sets the side margin of a segment without `width` (default 8.5, Omarchy's WidgetButton). `"passive": true` makes a segment a plain drawing (no click, hover or tooltip), e.g. a spacer that only reserves `width`. Replaces the previous list. A click on a segment carries `"segment": "<id>"` |
| `monitor`  | Output connector (`"DP-1"`): the update applies only to that output's bar. Without it, it applies to every bar that has not received its own |
| `settings` | Settings to save in the plugin's `shell.json` entry (`null` deletes a key). Shellder saves them and sends a new `config` |
| `menu`     | Replaces the right-click menu at runtime (same format as `barWidget.menu`; `[]` disables it) |
| `panel`    | Opens or updates the Shellder-drawn panel (`{"width": 380, "items": [...]}`), `null` closes it (see *Panels drawn by Shellder*) |

Missing fields keep their previous value. **Any line that does not start with
`{` becomes the `text`**, so a script that just `echo`s already works.
Remember to flush stdout after each line (`print(..., flush=True)`,
`python3 -u`, `fflush(stdout)`...).

### Shellder → plugin (stdin)

One JSON object per line.

**`config`**: the first line the plugin receives, and again whenever the
theme or its `shell.json` entry changes. It carries the bar, the resolved
Omarchy theme and the settings (`settings`: the layout entry without `id`):

```json
{"event": "config",
 "bar": {"position": "bottom", "size": 26},
 "theme": {
   "font": {"family": "JetBrainsMono Nerd Font",
            "sizes": {"caption": 10, "bodySmall": 11, "body": 12, "subtitle": 13,
                      "title": 14, "heading": 16, "display": 24, "displayLarge": 28,
                      "iconSmall": 11, "icon": 14, "iconLarge": 18}},
   "radius": 0,
   "colors":   {"foreground": "#a9b1d6ff", "background": "#1a1b26ff",
                "accent": "#7aa2f7ff", "urgent": "#f7768eff", "muted": "#414868ff"},
   "bar":      {"background": "#1a1b26ff", "text": "#a9b1d6ff", "active": "#f7768eff",
                "sizeHorizontal": 26, "sizeVertical": 28, "iconSlot": 27,
                "iconCanvas": 16, "iconFont": 13, "statusSlot": 21},
   "popup":    {"background": "#1a1b26ff", "text": "#a9b1d6ff",
                "border": "#7aa2f7ff", "borderWidth": 2},
   "controls": {"normal": "...", "normalBorder": "...", "hover": "#a9b1d614",
                "hoverBorder": "#a9b1d640", "selected": "#a9b1d62e", "...": "..."}
 },
 "settings": {"format": "ddd d MMM HH:mm"}}
```

Colors are `#rrggbbaa`. A plugin that opens windows (popups, panels) should
use these values to look like Omarchy.

**`click`**, **`scroll`** and **`hover`**:

```json
{"event": "click", "button": "left", "monitor": "DP-1",
 "bar":  {"position": "bottom", "width": 1920, "height": 26},
 "item": {"x": 900, "y": 2, "width": 120, "height": 22}}
{"event": "scroll", "direction": "up", "monitor": "DP-1", "bar": {...}, "item": {...}}
{"event": "hover", "hovered": true, "monitor": "DP-1", "bar": {...}, "item": {...}}
{"event": "menu", "id": "calendar", "monitor": "DP-1"}
{"event": "dismiss"}
```

- `button`: `left`, `middle` or `right`. `direction`: `up` or `down`.
- `segment`: the id of the clicked segment (only when the click hit one).
- `monitor`: the connector of the bar's output.
- `bar`: position and size of the bar on that output; `item`: the item rect
  inside the bar (logical px, from the bar's top-left corner) — what a plugin
  needs to open a popup next to the bar, aligned with the item.
- `hover`: the pointer entered (`true`) or left (`false`) the item on that bar;
  `item` is the hovered zone's rect, to place a hover popup. Moving to another
  segment of the item sends `hovered: true` again with the new `segment`. While
  the plugin's right-click menu is open it gets `hovered: false`.

- `dismiss`: close any popup you have open. Only one popup is open at a time:
  this goes to every other plugin when an item is clicked, and to all of them
  when the right-click menu opens or an empty part of the bar is clicked. The
  kit closes its `Panel`/`HoverPopup`s by itself (`on_dismiss` for the rest).

Reading stdin is optional: if the plugin does not read and the pipe fills up,
lines are dropped (a plugin never freezes the bar).

### Tooltips and the right-click menu

Shellder draws both itself, with the Omarchy theme, so they work for plugins
in any language:

- **Tooltip** — as in Omarchy's `Bar.qml`: shown 400 ms after the pointer
  settles on an item, centered on it, 6 px from the bar, `[tooltip]` colors.
  Text comes from the item's or segment's `tooltip`.
- **Menu** — declared in the manifest (or sent as `{"menu": [...]}`):

```json
"barWidget": {
  "menu": [
    {"id": "calendar", "label": "Open calendar", "icon": "󰃭"},
    {"label": "Change timezone…", "exec": "omarchy-menu-timezone"},
    {"type": "separator"},
    {"id": "24h", "label": "24-hour clock", "checked": true},
    {"id": "later", "label": "Not yet", "disabled": true}
  ]
}
```

  An entry with `exec` runs that shell command (detached); any other entry
  sends `{"event": "menu", "id": "<id>", "monitor": "DP-1"}` to the plugin.
  `checked` (`true`/`false`) shows a check column, `icon` an icon column.
  A click outside the menu, or on the bar, closes it; a second right click on
  the same item toggles it.

### Python plugin kit

Shellder exports `SHELLDER_KIT` (the `kit/` folder next to the binary). In
Python:

```python
import os, sys
sys.path.insert(0, os.path.join(os.environ["SHELLDER_KIT"], "python"))
from shellder_kit import Plugin
from shellder_kit import panel as P   # only if the plugin has a popup (GTK4)

class Mine(Plugin):
    def on_config(self, ev): self.emit(icon="󰕾", tooltip="Volume")
    def on_click(self, ev):  self.panel.toggle(ev)

Mine().run()
```

- `Plugin`: the protocol loop; `self.theme`, `self.bar`, `self.settings`;
  `emit()` (does not repeat identical lines; `monitor=` for a single bar),
  `save_settings()`, `every()`, `later()`, `run_cmd()` (async),
  `run_detached()`, `watch_lines()` (long-running process, line by line).
- `panel.Panel`: the popup pattern below, ready to use — override `build()`
  and `refresh()`.
- `panel.HoverPopup`: a passive card (no input, no keyboard) placed like the
  tooltip, for `"hover": "event"` plugins — `show(hover_event)` / `hide()`.
- `on_menu(ev)` receives right-click menu entries without `exec`.
- Widgets with the look of the Omarchy components: `hero`, `section`,
  `separator`, `row`, `action_button`, `button`, `switch`, `slider`.

### Panels drawn by Shellder

With `"panel": "skald"` in the manifest the plugin only describes its panel
and Shellder draws it with the Omarchy theme, so the plugin needs no GUI
toolkit (shellder-audio uses it: ~16 MiB instead of ~30 MiB with GTK).

```json
{"panel": {"width": 380, "spacing": 14, "items": [
  {"type": "hero", "icon": "\uf028", "title": "Audio", "meta": "Steady groove",
   "switch": {"id": "master", "on": true}},
  {"type": "separator"},
  {"type": "group", "spacing": 6, "items": [
    {"type": "section", "text": "OUTPUT", "value": "57%"},
    {"type": "slider", "id": "volume", "value": 0.57, "min": 0, "max": 1, "step": 0.01},
    {"type": "row", "id": "sink:usb", "icon": "\uf025", "text": "USB Audio Device",
     "trailing": "󰄬", "selected": true}]}]}}
```

| Node | Fields |
|---|---|
| `hero` | `icon` (display size), `title` (bold), `meta` (caption, upper case), `switch: {"id", "on"}` on the right |
| `section` | `text` and an optional right-aligned `value` (caption, bold, dimmed) |
| `separator` | a hairline |
| `slider` | `id`, `value`, `min` (0), `max` (1), `step` (0 = continuous) |
| `row` | `text`, `id` (clickable when set), `icon`, `value` (small, dimmed), `trailing` (glyph on the right), `selected`, `disabled`, `action: {"id", "icon"}` (an icon button before the text), `plain` (a line of content: no padding, no hover) |
| `label` | `text`, `style`: `""`, `dim`, `caption`, `small`, `title`, `bold` |
| `group` | `items` with their own `spacing` (default 6) |

The panel opens next to the item the plugin's last click came from, on the
same output, and updates whenever the plugin sends `panel` again (send it on
every state change while open). Shellder sends back:

```json
{"event": "panel", "action": "click",  "id": "sink:usb"}
{"event": "panel", "action": "change", "id": "volume", "value": 0.6}
{"event": "panel", "action": "toggle", "id": "master", "value": false}
{"event": "panel", "action": "closed"}
```

`change` comes while a slider is dragged (at most every 40 ms) and once more
on release; `closed` when Shellder closed it (press outside the card, another
item clicked, the bar's empty area, `Esc`). The panel takes the keyboard
focus when it opens (exclusive until focused, then on-demand, like
KeyboardPanel.qml) so `Esc` closes it. A click on the item itself reaches the
plugin as usual: toggle by sending `{"panel": null}`. Not yet: other keys and
scrolling inside the panel. `shellder_kit.nodes` builds the nodes and
handles the events (`SkaldPanel`).

#### The same panel in the other modes

A `SkaldPanel` also works with `"process"` and `"plugin"`: the plugin code
does not change, only the manifest. Both draw the nodes with GTK4
(`shellder_kit.gtk_nodes`, same look) and send back the same actions:

| Mode | Where GTK runs | Measured with shellder-audio (PSS) |
|---|---|---|
| `"skald"` | nowhere: Shellder draws it | plugin 15.6 MiB, open or closed |
| `"process"` | `python3 -m shellder_kit.panel_process`, started on open and exiting on close | plugin 15.6 MiB; +35 MiB child only while open; opens ~135 ms later than `"skald"` |
| `"plugin"` | the plugin's process | 15.6 MiB until the first open, 36 MiB open, 32.5 MiB after closing (GTK stays loaded) |

The child speaks JSON lines over its stdin/stdout: `{"open": {"event",
"theme", "spec"}}`, then `{"spec": ...}` / `{"theme": ...}` updates and
`{"close": true}` (or EOF); it answers with `{"action": "click" | "change" |
"toggle", "id", "value"}` and `{"action": "closed"}` when closed on its own
side (Esc, a click outside). Updates with the same structure change the
widgets in place, so a slider being dragged keeps its grab.

### Popups and panels

A plugin that needs a window (a calendar, a device list) creates its own
layer surface with the toolkit it prefers, using the click's `bar`/`item` to
position it and the `config` theme to style it. Follow the same design as
Omarchy's `KeyboardPanel.qml` — it is what allows clicking outside to close
**and** using the popup with mouse and keyboard:

1. **One layer covering the output's usable area** (anchored on all 4 edges,
   exclusive zone 0 — so the bar stays outside and clickable), with the card
   drawn inside it, next to the bar and aligned with the item. A click on the
   layer outside the card closes it.
2. **On the other outputs**, an identical transparent layer without keyboard
   that only closes when clicked.
3. **Keyboard: `exclusive` for ~75 ms on open, then `on_demand`.** The initial
   exclusive grab gives the popup focus; keeping it exclusive makes Hyprland
   send *all* pointer input to the layer, so the closing clicks on the other
   outputs never arrive.
4. Do not close on focus loss: focus may change on the way to the card.
5. A click on the bar item itself while the popup is open reaches the plugin
   as a regular `click`: treat it as a toggle.

`shellder_kit.panel.Panel` implements this with GTK4 + gtk4-layer-shell.

### Panels in their own process

A GUI toolkit costs memory for as long as it is loaded: a GTK panel inside
the bar process keeps it there after the first open (shellder-network: 16 MiB
before, 39 MiB open, 36 MiB after closing). With `barWidget.panel:
"process"` and `entryPoints.panel`, the panel is a separate program that
exists only while it is on screen, and the bar process loads no toolkit:

- A **left click** on the item starts it (the bar process does not get that
  click). Its stdin gets the same `config` line as the bar process (again
  when the theme changes), then that `click` — with `monitor`, `bar` and
  `item` to place the window. It runs in the plugin folder with the same
  variables plus `SHELLDER_PANEL=1`; stdout is read and discarded.
- Shellder **ends it** (SIGTERM to its group) on the next click on the item,
  a click on another item or on the bar's empty area, and when another popup
  or menu opens. The program **exits by itself** when its window closes
  (`Esc`, a click outside).
- The two processes share nothing: each reads what it needs from the system.

`shellder_kit.PanelApp` is that program in Python: set `self.panel` (a
`panel.Panel`) in `on_start`; it opens on the click and the process exits
when it closes. shellder-network uses it: 14.8 MiB for the bar, plus ~39 MiB
only while the panel is open.

### Lifecycle

- All plugins start with Shellder and are stopped (SIGTERM to the process
  group) when it exits — even if it dies.
- A plugin that exits is restarted with growing delays: 1s, 2s, 4s... up to
  30s. After 30s running fine, the delay goes back to 1s.
- One process serves every bar. For different content per output, send
  updates with `"monitor"`.

### Examples

Ports of every Omarchy bar widget (each folder has its own README):

| Plugin | Omarchy widget | Shows |
|---|---|---|
| [`shellder-workspace`](../shellder-workspace) | omarchy.workspaces | workspaces per output (standard library only; `monitor`, `segments`) |
| [`shellder-indicators`](../shellder-indicators) | omarchy.indicators | status indicators, revealed on hover (`segments`, `hover`) |
| [`shellder-clock`](../shellder-clock) | omarchy.clock | clock, big-time hover, calendar panel, right-click `menu` |
| [`shellder-keyboard-layout`](../shellder-keyboard-layout) | omarchy.keyboard-layout | xkb layout code (only with several layouts) |
| [`shellder-weather`](../shellder-weather) | omarchy.weather | condition glyph, forecast panel, location search |
| [`shellder-system-update`](../shellder-system-update) | omarchy.system-update | pending Omarchy update glyph |
| [`shellder-tray`](../shellder-tray) | omarchy.tray | StatusNotifierItem tray, drawer, dbusmenu (`image`, `passive`) |
| [`shellder-agents`](../shellder-agents) | omarchy.agents | AI subscription limits and token usage |
| [`shellder-bluetooth`](../shellder-bluetooth) | omarchy.bluetooth | adapter, devices, discovery |
| [`shellder-network`](../shellder-network) | omarchy.network | status glyph, details, DNS, Wi-Fi |
| [`shellder-audio`](../shellder-audio) | omarchy.audio | volume glyph, devices and streams |
| [`shellder-monitor`](../shellder-monitor) | omarchy.monitor | brightness, text size, scale, outputs |
| [`shellder-power`](../shellder-power) | omarchy.power | battery (hidden without one), power profiles |

Small examples:

- `examples/plugins/counter-python/` — interactive: clicks and scroll change a
  counter (JSON both ways).
- `examples/plugins/loadavg-bash/` — just `echo` every 5 seconds.

Minimal shell plugin:

```bash
#!/usr/bin/env bash
while true; do date +%S; sleep 1; done
```

## Architecture

```
main.odin      loop, layout, one bar per output, rendering
plugins.odin   manifest, processes, protocol, hot reload
panel_process.odin  entryPoints.panel programs (started on click, ended on dismiss)
omarchy.odin   Omarchy theme (palette, shell.toml, font, Hyprland)
config.odin    shell.json (read, layout, settings, save)
native.odin    bindings for the C code
native/        C: Wayland layer-shell (wlbar.c) and processes (proc.c)
kit/           plugin kit (kit/python/shellder_kit)
```

`skald.run` uses SDL, which cannot create layer surfaces, so Shellder uses
Skald's *embedded* backend: the C code in `native/` creates one surface per
output and all of them are drawn by the same renderer.

```
popups.odin    Shellder's own popups: tooltip and right-click menu
```

Not there yet: keyboard navigation in the right-click menu (Esc / arrows),
closing the menu by clicking on another output.
