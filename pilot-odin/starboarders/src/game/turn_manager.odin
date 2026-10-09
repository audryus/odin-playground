// This file manages the turn-based mechanics of the game.
// It handles the turn order, action points, and the execution of unit actions during each turn.

TurnManager : struct {
    turnOrder : []Unit,
    currentTurnIndex : int,
}

TurnManager.init : proc() {
    // Initialize the turn manager with an empty turn order and set the current turn index to zero.
    self.turnOrder = []Unit{}
    self.currentTurnIndex = 0
}

TurnManager.addUnit : proc(unit : Unit) {
    // Add a unit to the turn order.
    self.turnOrder = append(self.turnOrder, unit)
}

TurnManager.nextTurn : proc() {
    // Move to the next unit's turn in the turn order.
    self.currentTurnIndex = (self.currentTurnIndex + 1) % len(self.turnOrder)
}

TurnManager.getCurrentUnit : proc() -> Unit {
    // Return the unit whose turn it is currently.
    return self.turnOrder[self.currentTurnIndex]
}

TurnManager.executeTurn : proc() {
    // Execute the actions for the current unit's turn.
    currentUnit := self.getCurrentUnit()
    // Logic for executing actions goes here.
}