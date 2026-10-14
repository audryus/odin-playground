package main_web

import "base:intrinsics"
import "core:c"
import "core:mem"

// O allocator padrão do js_wasm32 cresce a memória por conta própria e brigaria
// com o malloc do Emscripten, então tudo passa pela libc do Emscripten.
foreign import libc "env.o"

@(default_calling_convention = "c")
foreign libc {
	malloc :: proc(size: c.size_t) -> rawptr ---
	calloc :: proc(num, size: c.size_t) -> rawptr ---
	free :: proc(ptr: rawptr) ---
	realloc :: proc(ptr: rawptr, size: c.size_t) -> rawptr ---
	aligned_alloc :: proc(alignment, size: c.size_t) -> rawptr ---
}

// Alinhamento garantido pelo malloc do Emscripten.
MALLOC_ALIGNMENT :: 8

emscripten_allocator :: proc "contextless" () -> mem.Allocator {
	return {emscripten_allocator_proc, nil}
}

emscripten_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	alloc :: proc(size, alignment: int, zero: bool) -> ([]byte, mem.Allocator_Error) {
		ptr: rawptr
		if alignment <= MALLOC_ALIGNMENT {
			ptr = zero ? calloc(1, c.size_t(size)) : malloc(c.size_t(size))
		} else {
			ptr = aligned_alloc(c.size_t(alignment), c.size_t(size))
			if ptr != nil && zero {
				intrinsics.mem_zero(ptr, size)
			}
		}
		if ptr == nil && size > 0 {
			return nil, .Out_Of_Memory
		}
		return mem.byte_slice(ptr, size), nil
	}

	switch mode {
	case .Alloc:
		return alloc(size, alignment, true)
	case .Alloc_Non_Zeroed:
		return alloc(size, alignment, false)
	case .Free:
		free(old_memory)
		return nil, nil
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return alloc(size, alignment, mode == .Resize)
		}
		if alignment <= MALLOC_ALIGNMENT {
			ptr := realloc(old_memory, c.size_t(size))
			if ptr == nil && size > 0 {
				return nil, .Out_Of_Memory
			}
			if mode == .Resize && size > old_size {
				intrinsics.mem_zero(rawptr(uintptr(ptr) + uintptr(old_size)), size - old_size)
			}
			return mem.byte_slice(ptr, size), nil
		}
		data, err := alloc(size, alignment, mode == .Resize)
		if err != nil {
			return nil, err
		}
		intrinsics.mem_copy_non_overlapping(raw_data(data), old_memory, min(old_size, size))
		free(old_memory)
		return data, nil
	case .Free_All:
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}
