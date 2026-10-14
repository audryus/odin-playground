package game

import rl "vendor:raylib"

init :: proc() {
	rl.InitWindow(800, 450, "Hello, Raylib!")
	rl.SetTargetFPS(60)
}

update :: proc() {
	rl.BeginDrawing()
	defer rl.EndDrawing()

	rl.ClearBackground(rl.RAYWHITE)
	rl.DrawText("Hello, World!", 280, 200, 40, rl.DARKGRAY)
}

shutdown :: proc() {
	rl.CloseWindow()
}

should_run :: proc() -> bool {
	// No navegador o loop é controlado pelo browser; WindowShouldClose
	// chamaria emscripten_sleep, que exige ASYNCIFY.
	when ODIN_OS == .JS {
		return true
	} else {
		return !rl.WindowShouldClose()
	}
}
