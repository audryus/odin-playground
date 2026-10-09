package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"

foo :: proc(task: thread.Task) {
	u := (^ParallelInfo(string))(task.data)^
	fmt.println(time.now(), u.sl)
	time.sleep(5 * time.Second)
	fmt.println(time.now(), u.sl, "end")
}

bar :: proc(task: thread.Task) {
	u := (^ParallelInfo(string))(task.data)^
	time.sleep(1 * time.Second)

	fmt.println(time.now(), u.sl)
	time.sleep(1 * time.Second)
	fmt.println(time.now(), u.sl, "end")
}

ParallelInfo :: struct($T: typeid) {
	sl: T,
}

main :: proc() {
	allocator := context.allocator

	when ODIN_DEBUG {
		fmt.printfln("Debugging mode")
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, os.get_processor_core_count())


	bar_info := new(ParallelInfo(string), allocator)
	bar_info.sl = "barz"

	thread.pool_add_task(&pool, allocator, bar, rawptr(bar_info), 0)

	foo_info := new(ParallelInfo(string), allocator)
	foo_info.sl = "fooz"

	thread.pool_add_task(&pool, allocator, foo, rawptr(foo_info), 0)


	fmt.println(time.now(), "Inicio ...")
	thread.pool_start(&pool)
	time.sleep(1 * time.Second)
	thread.pool_finish(&pool)
	thread.pool_destroy(&pool)

	fmt.println("Main thread finished")
}
