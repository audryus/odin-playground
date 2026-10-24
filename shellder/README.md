# Shellder

Uma barra para Hyprland, feita em Odin com [Skald](https://github.com/BuLEEto/Skald).
A barra é só a barra: vem vazia, e tudo o que aparece nela vem de plugins,
escritos em qualquer linguagem.

- Uma barra por monitor (layer-shell, em qualquer borda, com exclusive zone).
- Segue o tema do Omarchy — cores, fonte, tamanho, cantos — e repassa o tema
  resolvido para os plugins, para que popups e afins tenham o mesmo visual.
- Plugins são processos externos descritos por um `manifest.json`.

## Rodar

```bash
make run                # 1ª vez clona o Skald em vendor/, compila e executa
make install-examples   # copia os plugins de exemplo para ~/.config/shellder/plugins
pkill shellder          # encerra (os plugins são encerrados junto)
```

O build aplica os patches de `patches/` no Skald clonado em `vendor/` e
recompila o shader com `glslc` (pacote `shaderc`). Hoje há um patch: o texto é
misturado como no Qt (em sRGB), sem o "stem darkening" do Skald — sem ele a
fonte sai mais grossa e mais clara que a da barra do Omarchy, apesar de ser a
mesma fonte, tamanho e cor.

## Configuração

Tudo fica em `~/.config/shellder/` (ou `$XDG_CONFIG_HOME/shellder`, ou
`$SHELLDER_CONFIG_DIR`):

```
~/.config/shellder/
├── shell.json
└── plugins/
    └── <pasta-do-plugin>/
        └── manifest.json
```

`shell.json` tem o mesmo formato do `~/.config/omarchy/shell.json` (a parte
`bar`). Se não existir, o Shellder cria:

```json
{
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
```

| Chave             | Descrição |
|-------------------|-----------|
| `bar.position`    | `bottom`, `top`, `left` ou `right` |
| `bar.transparent` | `true` deixa o fundo transparente e escolhe a cor do texto com o `omarchy-bar-text-color`, como o Omarchy. **Duplo clique numa área vazia da barra alterna** (e grava aqui) |
| `bar.layout.*`    | Itens de cada seção, na ordem: `{"id": "<id do plugin>", <preferências>}` |
| `disabled`        | ids de plugins instalados que não devem aparecer nem rodar |

Cada item do layout é o **id de um plugin** mais as **preferências** dele, como
no Omarchy:

```json
"center": [
  {"id": "shellder.clock", "format": "ddd d MMM HH:mm", "formatAlt": "d MMMM 'W'ww yyyy"}
]
```

As preferências vão para o plugin no evento `config`; quando o plugin muda
alguma (ex.: o clique direito do relógio troca o formato), o Shellder grava de
volta na entrada. Um plugin instalado que ainda não está no layout (nem em
`disabled`) é adicionado no fim da `defaultSection` do manifest e o arquivo é
gravado. Para tirar um plugin da barra, ponha o id em `disabled`.

Em barra vertical (`left`/`right`), as seções viram `left` = topo,
`center` = meio e `right` = base; o ícone fica em cima e cada linha do texto
do plugin vira uma linha centrada, cortada na largura da barra.

## Hot reload

Nada exige reiniciar o Shellder (checagem a cada segundo):

| Mudança | O que acontece |
|---------|----------------|
| `shell.json` editado | layout, preferências, `disabled`, `transparent` e `position` aplicados na hora |
| pasta nova em `plugins/` | plugin carregado, iniciado e adicionado ao layout |
| pasta removida | plugin parado e tirado da barra |
| qualquer arquivo de um plugin muda (código, manifest, binário recompilado) | só aquele plugin é reiniciado, 0,5 s depois da última mudança |
| tema/fonte do Omarchy | barra e plugins atualizados |

Para o reload de plugin, mudanças em `.git`, `__pycache__`, `node_modules`,
`.cache`, `.venv` e temporários de editor são ignoradas. **Um plugin não deve
gravar arquivos na própria pasta**, ou vai se reiniciar sem parar — use
`SHELLDER_CONFIG_DIR`, `$XDG_STATE_HOME` ou `$XDG_CACHE_HOME`.

## Tema

O Shellder resolve o tema como o shell do Omarchy faz
(`/usr/share/omarchy/shell/Commons/{Color,Style}.qml`):

| O quê          | De onde |
|----------------|---------|
| Paleta         | `~/.local/state/omarchy/current/theme/colors.toml` (foreground, background, accent, urgent, muted, com os mesmos fallbacks `color0/4/7/8`, `red`) |
| Superfícies    | `shell.toml` do tema + `~/.config/omarchy/shell.toml` por cima: `[bar]`, `[popups]`, `[controls]`, `[font]` (inclui `*-alpha` e referências como `hyprland.active-border`) |
| Fonte          | alias `monospace` do fontconfig (o que `omarchy font set` troca), com a escala de tamanhos derivada de `[font] base-size` |
| Tamanho        | `[bar] size-horizontal` / `size-vertical`, escalados pela fonte |
| Cantos e borda | `decoration:rounding` e `general:border_size` do Hyprland |

Não há cores, fonte ou tamanho próprios no Shellder: para mudar, mude o tema
do Omarchy (ou o `~/.config/omarchy/shell.toml`). Os arquivos são vigiados:
`omarchy theme set`, `omarchy font set` e edições no `shell.toml` atualizam a
barra e os plugins em até 1 segundo. Fora do Omarchy valem os padrões do
`Color.qml`.

## Plugins

Um plugin é uma pasta em `plugins/` com um `manifest.json` (mesmo formato dos
plugins do Omarchy) e um executável em qualquer linguagem. O Shellder inicia o
executável uma vez, mantém ele rodando e conversa por **stdin/stdout, uma linha
por mensagem**.

### manifest.json

```json
{
  "schemaVersion": 1,
  "id": "voce.meu-plugin",
  "name": "Meu plugin",
  "version": "1.0.0",
  "author": "você",
  "description": "O que ele faz",
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

| Campo                         | Obrigatório | Descrição |
|-------------------------------|:-----------:|-----------|
| `id`                          | sim | Identificador único; é o `id` da entrada em `bar.layout` do `shell.json` |
| `kinds`                       | sim | Precisa conter `"bar-widget"` (único tipo suportado por enquanto) |
| `entryPoints.barWidget`       | sim | O que executar. String: caminho de um executável dentro da pasta (precisa de `chmod +x` e shebang). Array: comando + argumentos, procurado no `PATH` (`["node", "index.js"]`, `["./meu-binario"]`) |
| `barWidget.icon`              | não | Ícone inicial: um ou mais caracteres. A fonte do Omarchy é uma Nerd Font, então glyphs de Nerd Font funcionam |
| `barWidget.defaultSection`    | não | `left`, `center` ou `right` (padrão `right`); na barra vertical: topo, meio, base |
| `name`, `version`, `author`, `description`, `schemaVersion`, `barWidget.displayName`, `barWidget.category` | não | Informativos |

O processo roda com o diretório do plugin como `cwd` e recebe as variáveis:

| Variável                   | Valor |
|----------------------------|-------|
| `SHELLDER_PLUGIN_ID`       | o `id` do manifest |
| `SHELLDER_PLUGIN_DIR`      | a pasta do plugin |
| `SHELLDER_CONFIG_DIR`      | a pasta de config do Shellder |

O stderr do plugin vai para o stderr do Shellder.

### Plugin → Shellder (stdout)

Cada linha é uma atualização. Pode ser um objeto JSON:

```json
{"text": "23°C", "icon": "", "color": "accent", "visible": true}
```

| Campo     | Descrição |
|-----------|-----------|
| `text`    | Texto ao lado do ícone (`\n` separa linhas na barra vertical) |
| `icon`    | Troca o ícone |
| `color`   | `"#rrggbb[aa]"` ou um papel do tema: `foreground`, `muted`, `accent`, `urgent`, `active` |
| `visible` | `false` esconde o item |
| `segments` | Lista de botões dentro do item: `[{"id": "1", "text": "1", "icon": "", "color": "accent", "opacity": 0.5, "width": 20}]` (só `id` é obrigatório). Substitui a lista anterior. O clique num segmento traz `"segment": "<id>"` |
| `monitor` | Conector (`"DP-1"`): a atualização vale só para a barra desse monitor. Sem ele, vale para todas as que não receberam atualização própria |
| `settings` | Objeto com preferências a gravar na entrada do plugin no `shell.json` (`null` apaga a chave). O Shellder grava e manda um `config` novo |

Campos ausentes mantêm o valor anterior. **Qualquer linha que não começa com
`{` vira o `text`**, então um script que só faz `echo` já funciona. Lembre de
dar flush no stdout a cada linha (`print(..., flush=True)`, `python3 -u`,
`fflush(stdout)`...).

### Shellder → plugin (stdin)

Um objeto JSON por linha.

**`config`**: a primeira linha que o plugin recebe, e de novo sempre que o tema
ou a entrada dele no `shell.json` muda. Traz a barra, o tema do Omarchy já
resolvido e as preferências (`settings`: a entrada do layout sem o `id`):

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
   "bar":      {"background": "#1a1b26ff", "text": "#a9b1d6ff", "active": "#f7768eff"},
   "popup":    {"background": "#1a1b26ff", "text": "#a9b1d6ff",
                "border": "#7aa2f7ff", "borderWidth": 2},
   "controls": {"hover": "#a9b1d614", "hoverBorder": "#a9b1d640", "selected": "#a9b1d62e"}
 },
 "settings": {"format": "ddd d MMM HH:mm"}}
```

Cores em `#rrggbbaa`. Um plugin que abre janelas (popups, painéis) deve usar
esses valores para ficar com o visual do Omarchy.

**`click`** e **`scroll`**:

```json
{"event": "click", "button": "left", "monitor": "DP-1",
 "bar":  {"position": "bottom", "width": 1920, "height": 26},
 "item": {"x": 900, "y": 2, "width": 120, "height": 22}}
{"event": "scroll", "direction": "up", "monitor": "DP-1", "bar": {...}, "item": {...}}
```

- `button`: `left`, `middle` ou `right`. `direction`: `up` ou `down`.
- `segment`: o `id` do segmento clicado (só quando o clique foi num segmento).
- `monitor`: o conector do monitor da barra.
- `bar`: posição e tamanho da barra nesse monitor; `item`: retângulo do item
  dentro da barra (px lógicos, a partir do canto superior esquerdo da barra).
  É o que o plugin precisa para abrir um popup encostado na barra, alinhado ao
  item.

Ler o stdin é opcional: se o plugin não lê e o pipe enche, as linhas são
descartadas (a barra nunca trava por causa de um plugin).

### Popups e painéis

O Shellder não desenha nada além da barra. Um plugin que precisa de uma
janela (um calendário, um menu) cria a própria layer-surface, com o toolkit
que preferir, usando o `bar`/`item` do clique para posicionar e o tema do
evento `config` para o visual. Siga o mesmo desenho do `KeyboardPanel.qml` do
Omarchy — é o que permite clicar fora para fechar **e** usar o popup com o
mouse e o teclado:

1. **Uma layer que cobre a área útil do monitor** (âncora nas 4 bordas,
   exclusive zone 0 — assim a barra fica de fora e continua clicável), com o
   card desenhado dentro dela, encostado na barra e alinhado ao item. Clique
   na layer fora do card fecha.
2. **Nos outros monitores**, uma layer transparente igual, sem teclado, que
   só fecha ao ser clicada.
3. **Teclado: `exclusive` por ~75 ms ao abrir, depois `on_demand`.** O
   exclusive inicial dá o foco ao popup; mantê-lo exclusive faz o Hyprland
   mandar *todo* o ponteiro para a layer, e aí os cliques de fechar nos outros
   monitores nunca chegam.
4. Não feche ao perder o foco: no caminho do mouse até o card o foco pode
   mudar.
5. Clique no próprio item da barra com o popup aberto chega ao plugin como
   `click` normal: trate como toggle.

O [shellder-clock](../shellder-clock) (`panel.py`) implementa isso com GTK4 +
gtk4-layer-shell.

### Ciclo de vida

- Todos os plugins sobem junto com o Shellder e são encerrados (SIGTERM no
  grupo de processos) quando ele sai — inclusive se ele morrer.
- Se um plugin sair, ele é reiniciado com espera crescente: 1s, 2s, 4s... até
  30s. Depois de 30s rodando bem, a espera volta para 1s.
- Um único processo atende todas as barras. Para conteúdo diferente em cada
  monitor, mande atualizações com `"monitor"`.

### Exemplos

- [`../shellder-clock`](../shellder-clock) — porte do clock do Omarchy, com
  calendário (Python + GTK4).
- [`../shellder-workspace`](../shellder-workspace) — workspaces por monitor
  (Python, só biblioteca padrão; usa `monitor` e `segments`).
- `examples/plugins/counter-python/` — interativo: clique e scroll mudam um
  contador (JSON nos dois sentidos).
- `examples/plugins/loadavg-bash/` — só `echo` a cada 5 segundos.

Shell mínimo:

```bash
#!/usr/bin/env bash
while true; do date +%S; sleep 1; done
```

## Arquitetura

```
main.odin      loop, layout, barras por monitor, render
plugins.odin   manifest, processos, protocolo
omarchy.odin   tema do Omarchy (paleta, shell.toml, fonte, Hyprland)
config.odin    shell.json (leitura, layout, preferências, gravação)
native.odin    bindings para o C
native/        C: Wayland layer-shell (wlbar.c) e processos (proc.c)
```

O `skald.run` usa SDL, que não cria layer-surfaces; por isso o Shellder usa o
backend *embedded* do Skald: o C em `native/` cria uma surface por monitor e
todas são desenhadas pelo mesmo renderer.

Ainda não há: tooltips na barra e entrada de teclado na barra.
