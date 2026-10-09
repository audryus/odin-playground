package lero_test

import "../../src/lero"
import "core:testing"

@(test)
my_test :: proc(t: ^testing.T) {
	lero.sum(1, 2)
}
