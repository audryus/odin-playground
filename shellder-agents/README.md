# shellder-agents

Port of Omarchy's `omarchy.agents` bar widget (`/usr/share/omarchy/shell/plugins/agents/`)
for Shellder: usage limits and token counts of your AI coding subscriptions.

- **Bar**: `󱚣`, drawn in the bar's `active` color when a limit window is at 90%+ or a
  prepaid balance is under 10%. Hidden while no agent has any recorded usage.
- **Left click**: dashboard with the agent's mark, name and plan, subscription chips when
  several are enabled, BALANCE (prepaid agents), LIMITS (meters + reset countdown),
  TOKENS BY DAY (last 7 days, today in bold) and TOKENS BY MODEL.
  Keys: `h`/`l` (or arrows) switch subscription, `r`/Enter refreshes, Esc closes.
- **Right click**: `omarchy-agent --pick`.
- **Middle click**: next subscription.

Display only, like the original: records come from `omarchy-agent-usage-update`, which
writes `~/.local/state/omarchy/agents/usage/*.json`. The plugin runs it on start, every
`refreshIntervalSec` and on `r`, and reloads whenever a record file changes.

## Settings (`shell.json`, same keys as omarchy.agents)

```json
{ "id": "shellder.agents", "settings": {
    "refreshIntervalSec": 900,
    "providers": { "codex": { "enabled": false } } } }
```

Not ported: cross-device sync (`syncMode` / `syncDir`).

## Install / test

```sh
make install                          # symlink into ~/.config/shellder/plugins/
python3 -m unittest discover -s tests
```
