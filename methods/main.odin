package main

import "core:fmt"
import "vendor:raylib"

Foo :: struct {
	bar: proc(_: ^Foo),
}

barz :: proc(foo: ^Foo) {
	fmt.println("barz")
}

fooz :: proc(foo: ^Foo) {
	fmt.println("fooz")
}

main :: proc() {
	fmt.println("Hello, World!")
	foo := Foo {
		bar = barz,
	}
	foo->bar()

	foo.bar = fooz
	foo->bar()
	foo.bar(&foo)
}
