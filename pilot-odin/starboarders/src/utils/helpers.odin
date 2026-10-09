// This file provides utility functions that assist with various tasks in the game.

import "core:math"

// Generates a random integer between min and max (inclusive).
RandomInt : proc(min: int, max: int) -> int {
    return math.random_int(min, max);
}

// Clamps a value between a minimum and maximum range.
Clamp : proc(value: float, min: float, max: float) -> float {
    if value < min {
        return min;
    } else if value > max {
        return max;
    }
    return value;
}

// Checks if a given value is within a specified range.
IsInRange : proc(value: float, min: float, max: float) -> bool {
    return value >= min && value <= max;
}

// Converts degrees to radians.
DegreesToRadians : proc(degrees: float) -> float {
    return degrees * (math.pi / 180.0);
}

// Converts radians to degrees.
RadiansToDegrees : proc(radians: float) -> float {
    return radians * (180.0 / math.pi);
}