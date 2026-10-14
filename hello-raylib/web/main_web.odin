package main_web

import "base:runtime"
import "core:mem"
import game "../game"

@(private = "file")
web_context: runtime.Context

// Chamado via _start (em main.c), depois que o runtime do Odin foi inicializado.
main :: proc() {
	context.allocator = emscripten_allocator()
	runtime.init_global_temporary_allocator(1 * mem.Megabyte)
	web_context = context

	game.init()
}

// Chamado pelo emscripten_set_main_loop a cada frame.
@(export)
web_update :: proc "c" () {
	context = web_context
	game.update()
}
