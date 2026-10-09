package skald_example

import "core:fmt"
import "core:strings"
import "gui:skald"

// Exemplo pequeno de Skald (arquitetura Elm em Odin):
//   State  -> os dados da app
//   Msg    -> tudo que o usuário pode fazer
//   update -> (estado antigo, msg) -> estado novo
//   view   -> estado -> árvore de widgets (reconstruída todo frame)
//
// Aqui juntamos um campo de texto (nome) com um contador de "acenos".

State :: struct {
	name:  string,
	waves: int,
}

Msg :: union {
	Name_Changed,
	Wave,
	Unwave,
	Reset,
}

Name_Changed :: distinct string
Wave         :: struct{}
Unwave       :: struct{}
Reset        :: struct{}

init :: proc() -> State {
	// Clonamos para que o primeiro `update` tenha memória própria para liberar.
	return {name = strings.clone("")}
}

update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	switch v in m {
	case Name_Changed:
		// A string recebida é temporária; guardamos uma cópia nossa.
		delete(out.name)
		out.name = strings.clone(string(v))
	case Wave:
		out.waves += 1
	case Unwave:
		out.waves = max(out.waves - 1, 0)
	case Reset:
		delete(out.name)
		out.name = strings.clone("")
		out.waves = 0
	}
	return out, {}
}

on_name :: proc(s: string) -> Msg { return Name_Changed(s) }

view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme

	who := len(s.name) > 0 ? s.name : "estranho"
	// tprintf usa o temp_allocator, que o skald.run limpa a cada frame.
	greeting := fmt.tprintf("Olá, %s! 👋 x%d", who, s.waves)

	return skald.col(
		skald.text("Skald — Exemplo", th.color.fg_muted, th.font.size_md),
		skald.spacer(th.spacing.sm),
		skald.text(greeting, th.color.fg, th.font.size_display),

		skald.spacer(th.spacing.xl),

		skald.text_input(ctx, s.name, on_name, placeholder = "Seu nome...", width = 320),

		skald.spacer(th.spacing.md),

		skald.row(
			skald.button(ctx, "−", Unwave{},
				bg = th.color.surface, fg = th.color.fg, width = 64),
			skald.button(ctx, "Reset", Reset{},
				bg = th.color.surface, fg = th.color.fg_muted, width = 96),
			skald.button(ctx, "Acenar", Wave{},
				bg = th.color.primary, fg = th.color.on_primary, width = 120),
			spacing     = th.spacing.md,
			cross_align = .Center,
		),

		spacing     = 0,
		padding     = th.spacing.xl,
		main_align  = .Center,
		cross_align = .Center,
	)
}

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald Example",
		size   = {640, 420},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
