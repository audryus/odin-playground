package main

import "core:fmt"
import "lero"

foo :: proc {
	sum,
	addAll,
}

NumNum :: struct {
	a, b: int,
}

Add :: struct {
	using base: NumNum,
}

add :: proc(a: Add) -> int {
	return sum(a.a, a.b)
}

addAll :: proc(a: ..NumNum) -> int {
	total := 0
	for num in a {
		total = total + (num.a + num.b)
	}
	return total
}

sum :: proc(a: int, b: int) -> int {
	return a + b
}

main :: proc() {
	x: [dynamic][dynamic]bool


	fmt.println(lero.sum(2, 5))

	fmt.println(foo(1, 2))
	fmt.println(foo(Add{a = 2, b = 2}))

	fmt.println(foo(Add{a = 2, b = 2}, Add{a = 5, b = 8}))
}
