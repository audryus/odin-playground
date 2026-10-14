package main

import "game"

main :: proc() {
	game.init()
	defer game.shutdown()

	for game.should_run() {
		game.update()
	}
}
