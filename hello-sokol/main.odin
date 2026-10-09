package main

import sapp "../sokol-odin/sokol/app"
import shelpers "../sokol-odin/sokol/helpers"
import "base:runtime"
import "core:log"

default_context: runtime.Context

main :: proc() {
	context.logger = log.create_console_logger()
	default_context = context

	sapp.run(
		{
			width = 800,
			height = 600,
			window_title = "Hello, Sokol!",
			allocator = sapp.Allocator(shelpers.allocator(&default_context)),
			logger = sapp.Logger(shelpers.logger(&default_context)),
			init_cb = init_cb,
			frame_cb = frame_cb,
			cleanup_cb = cleanup_cb,
			event_cb = event_cb,
		},
	)

}
init_cb :: proc "c" () {
	context = default_context
}
frame_cb :: proc "c" () {
	context = default_context
}
cleanup_cb :: proc "c" () {
	context = default_context
}
event_cb :: proc "c" (ev: ^sapp.Event) {
	context = default_context
}
