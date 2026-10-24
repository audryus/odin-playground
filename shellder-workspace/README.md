# shellder-workspace

Workspaces do Hyprland na barra do [Shellder](../shellder), **por monitor**.
Visual do `omarchy.workspaces` (`/usr/share/omarchy/shell/plugins/bar/widgets/Workspaces.qml`),
lista por monitor como no `skald-bar`.

Cada barra mostra os workspaces daquele monitor: os presos a ele por regra do
Hyprland (`workspace = 2, monitor:DP-1, persistent:true`) mais os que existem
nele no momento.

| Estado                 | Aparência |
|------------------------|-----------|
| ativo no monitor       | glifo `󱓻` |
| ocupado                | número, opacidade 1 |
| vazio                  | número, opacidade 0.5 |

| Ação     | O que faz |
|----------|-----------|
| clique   | vai para o workspace |
| scroll   | anterior/próximo workspace daquele monitor |

Atualiza pelos eventos do Hyprland (`socket2`), sem polling. O workspace 10
aparece como `0`, como no Omarchy; workspaces com nome mostram o nome.

## Instalar

```bash
make install   # symlink em ~/.config/shellder/plugins/shellder-workspace
```

Entra sozinho em `bar.layout.left` (`defaultSection`). Só Python 3, sem
dependências.

Usa duas extensões do protocolo do Shellder: atualizações com `"monitor"`
(conteúdo diferente em cada barra) e `"segments"` (um botão por workspace; o
clique traz `"segment": "<id>"`).
