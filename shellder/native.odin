package shellder

import "core:c"
import vk "vendor:vulkan"

// Bindings para o código C em native/ (compilado pelo build.sh em
// build/libshellder_native.a). Ver native/wlbar.h e native/proc.h.

foreign import native {
	"build/libshellder_native.a",
	"system:wayland-client",
	"system:wayland-cursor",
}

foreign import vulkan "system:vulkan"

WB_MAX_OUTPUTS :: 16

WB_Event_Type :: enum i32 {
	None      = 0,
	Configure = 1,
	Closed,
	Enter,
	Leave,
	Motion,
	Button,
	Axis,
}

WB_Event :: struct {
	type: WB_Event_Type,
	out:  i32,
	a, b: i32,
	x, y: f64,
}

@(default_calling_convention = "c")
foreign native {
	wb_init           :: proc(size: i32, position: i32, namespace_: cstring) -> c.int ---
	wb_set_geometry   :: proc(size: i32, position: i32) ---
	wb_set_cursor     :: proc(pointer: i32) ---
	wb_display        :: proc() -> rawptr ---
	wb_surface        :: proc(out: i32) -> rawptr ---
	wb_output_scale   :: proc(out: i32) -> i32 ---
	wb_output_name    :: proc(out: i32) -> cstring ---
	wb_output_destroy :: proc(out: i32) ---
	wb_fd             :: proc() -> c.int ---
	wb_before_poll    :: proc() -> c.int ---
	wb_after_poll     :: proc(readable: c.int) -> c.int ---
	wb_next_event     :: proc(ev: ^WB_Event) -> c.int ---
}

@(default_calling_convention = "c")
foreign native {
	sh_signals_init :: proc() ---
	sh_should_quit  :: proc() -> c.int ---
	sh_spawn        :: proc(argv: [^]cstring, cwd: cstring, extra_env: [^]cstring, in_fd, out_fd: ^i32) -> i32 ---
	sh_kill_group   :: proc(pid: i32) ---
	sh_reap         :: proc(pid: i32) -> c.int ---
	sh_write        :: proc(fd: i32, data: rawptr, len: i32) -> c.int ---
	sh_capture      :: proc(cmd: cstring, out: [^]u8, out_len: i32) -> c.int ---
}

@(default_calling_convention = "c")
foreign vulkan {
	vkGetInstanceProcAddr :: proc(instance: vk.Instance, name: cstring) -> rawptr ---
}

VK_INSTANCE_EXTS := [?]cstring{"VK_KHR_surface", "VK_KHR_wayland_surface"}

// create_wayland_surface é o callback que o Skald chama (com a instância que
// ele mesmo criou) para obter o VkSurfaceKHR de um output. `user` carrega o
// índice do output no shim.
create_wayland_surface :: proc(instance: vk.Instance, user: rawptr) -> (vk.SurfaceKHR, bool) {
	out := i32(uintptr(user))
	info := vk.WaylandSurfaceCreateInfoKHR{
		sType   = .WAYLAND_SURFACE_CREATE_INFO_KHR,
		display = (^vk.wl_display)(wb_display()),
		surface = (^vk.wl_surface)(wb_surface(out)),
	}
	surf: vk.SurfaceKHR
	if vk.CreateWaylandSurfaceKHR(instance, &info, nil, &surf) != .SUCCESS {
		return 0, false
	}
	return surf, true
}
