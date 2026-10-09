// src/main.odin

package main

import "game"
import "utils/constants"

func main() {
    // Initialize game state
    gameState := game.InitializeGame()

    // Game loop
    for gameState.isRunning {
        game.HandleInput(gameState)
        game.Update(gameState)
        game.Render(gameState)
    }
}