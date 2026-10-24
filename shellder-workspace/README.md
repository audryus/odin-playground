# shellder-workspace

Hyprland workspaces on the [Shellder](../shellder) bar, **per output**. Looks
like `omarchy.workspaces` (`/usr/share/omarchy/shell/plugins/bar/widgets/Workspaces.qml`),
lists per output like the `skald-bar` prototype.

Each bar shows that output's workspaces: the ones bound to it by a Hyprland
rule (`workspace = 2, monitor:DP-1, persistent:true`) plus the ones currently
on it.

| State                  | Look |
|------------------------|------|
| active on the output   | glyph `󱓻` |
| occupied               | number, opacity 1 |
| empty                  | number, opacity 0.5 |

| Action   | What it does |
|----------|--------------|
| click    | focus the workspace |
| scroll   | previous/next workspace of that output |

Updates come from Hyprland events (`socket2`), with no polling. Workspace 10
shows as `0`, as in Omarchy; named workspaces show their name.

## Install

```bash
make install   # symlink into ~/.config/shellder/plugins/shellder-workspace
```

It is added to `bar.layout.left` automatically (`defaultSection`). Python 3
only, no dependencies.

Uses two Shellder protocol extensions: updates with `"monitor"` (different
content on each bar) and `"segments"` (one button per workspace; the click
carries `"segment": "<id>"`).
