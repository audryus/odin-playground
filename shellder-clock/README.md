# shellder-clock

Plugin de relógio para o [Shellder](../shellder), porte do clock do Omarchy
(`/usr/share/omarchy/shell/plugins/panels/clock/`): data/hora na barra e um
calendário ao clicar.

## Na barra

| Ação           | O que faz |
|----------------|-----------|
| —              | Mostra a hora no formato configurado (padrão `dddd HH:mm`; na barra vertical `HH`/`—`/`mm` empilhados). Atualiza na virada do minuto |
| Clique esquerdo | Abre/fecha o calendário |
| Clique direito  | Passa para o próximo formato da lista (e grava) |
| Clique do meio  | `omarchy-menu-timezone` (seletor de fuso) |

Formatos do clique direito — os mesmos do Omarchy:

```
dddd HH:mm        dddd h:mm AP      HH:mm             h:mm AP
ddd d MMM HH:mm   ddd d MMM h:mm AP d MMMM 'W'ww yyyy yyyy-MM-dd HH:mm
```

Vertical: `HH\n—\nmm`, `h\n—\nmm\nAP`, `dd\nMMM\n'W'ww\n''yy`, `HH\nmm`.

## Calendário

- Hoje em destaque; clicar nele volta ao mês atual quando você navegou.
- Progresso do ano. **Dois cliques** no trilho pedem ano de nascimento e
  expectativa de vida (Enter grava, Esc cancela, Tab alterna) e mostram um
  segundo trilho, *LIFE*. Dois cliques nele o escondem.
- Grade fixa de 6 semanas com número da semana ISO. O **W** alterna o início
  da semana entre segunda e domingo (padrão: o do locale).
- Mudar de mês: setas na tela, scroll na grade, `←`/`→` ou `[`/`]`;
  ano: `↑`/`↓` ou `{`/`}`; `t` ou Enter volta para hoje; `w` alterna o início
  da semana; `Esc` ou clicar fora fecha.

O popup segue o desenho do `KeyboardPanel` do Omarchy: uma layer cobrindo a
área útil do monitor (a barra fica de fora) com o card dentro; clicar fora do
card fecha, e o mouse e o teclado funcionam dentro dele.

O visual segue o tema do Omarchy que o Shellder manda no evento `config`:
fonte (alias `monospace`) e escala de tamanhos, cores de popup
(`[popups]` do `shell.toml`), borda (cor e espessura da borda ativa do
Hyprland), cantos (`decoration:rounding`) e o hover dos controles. A distância
até a barra é o `gaps_out` do Hyprland.

## Preferências

Ficam na entrada do plugin em `bar.layout` do `~/.config/shellder/shell.json`,
com as mesmas chaves do `omarchy.clock` no `~/.config/omarchy/shell.json`:

```json
{
  "id": "shellder.clock",
  "format": "ddd d MMM HH:mm",
  "formatAlt": "d MMMM 'W'ww yyyy",
  "verticalFormat": "HH\n—\nmm",
  "verticalFormatAlt": "dd\nMMM\n'W'ww\n''yy",
  "weekStartDay": "monday",
  "birthYear": 1985,
  "lifeExpectancy": 90
}
```

Todas são opcionais. O clique direito, o **W** e o *memento mori* gravam aqui
(o plugin manda `{"settings": ...}` e o Shellder atualiza o arquivo); editar o
arquivo à mão vale na hora.

## Instalar

```bash
make install   # symlink em ~/.config/shellder/plugins/shellder-clock
make test      # testes do modelo (datas, formatos, grade)
```

Depende de Python 3, PyGObject, GTK 4 e gtk4-layer-shell (já presentes no
Omarchy). Sem GTK/layer-shell o rótulo funciona e o calendário fica desligado.

## Arquivos

```
manifest.json  manifest (kinds: bar-widget)
clock.py       entrada: protocolo do Shellder, rótulo, formatos, preferências
panel.py       calendário (GTK4 + gtk4-layer-shell), porte do Panel.qml
model.py       datas e formatos, porte do Model.js (sem GTK, testável)
tests/         testes do model.py
```

O GTK só é carregado quando o calendário abre pela primeira vez.
