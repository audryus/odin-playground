#define _GNU_SOURCE
#include "wlbar.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include <wayland-cursor.h>

#include "wlr-layer-shell-unstable-v1-client-protocol.h"

#define BTN_LEFT   0x110
#define BTN_RIGHT  0x111
#define BTN_MIDDLE 0x112

typedef struct {
	int                           used;
	uint32_t                      global;
	struct wl_output             *output;
	char                          name[64];
	int32_t                       scale;
	int                           done;     // received the first wl_output.done
	struct wl_surface            *surface;
	struct zwlr_layer_surface_v1 *layer;
	int                           closed;
} Output;

typedef struct {
	int                           used;
	int                           out;
	int                           kind;
	struct wl_surface            *surface;
	struct zwlr_layer_surface_v1 *layer;
	int                           closed;
} Popup;

static struct {
	struct wl_display          *display;
	struct wl_registry         *registry;
	struct wl_compositor       *compositor;
	struct wl_shm              *shm;
	struct wl_seat             *seat;
	struct wl_pointer          *pointer;
	struct zwlr_layer_shell_v1 *layer_shell;

	struct wl_cursor_theme *cursor_theme;
	struct wl_surface      *cursor_surface;

	int32_t     size;
	int32_t     position;
	const char *ns;
	int         ready; // initial globals received

	Output outputs[WB_MAX_OUTPUTS];
	Popup  popups[WB_MAX_POPUPS];
	int    pointer_out;

	wb_event *events;
	int       ev_len, ev_cap, ev_head;
} S = {.pointer_out = -1};

static void push(wb_event ev) {
	if (S.ev_len == S.ev_cap) {
		S.ev_cap = S.ev_cap ? S.ev_cap * 2 : 64;
		S.events = realloc(S.events, sizeof(wb_event) * S.ev_cap);
	}
	S.events[S.ev_len++] = ev;
}

static int out_index(Output *o) { return (int)(o - S.outputs); }

static int out_by_surface(struct wl_surface *s) {
	for (int i = 0; i < WB_MAX_OUTPUTS; i++)
		if (S.outputs[i].used && S.outputs[i].surface == s) return i;
	for (int i = 0; i < WB_MAX_POPUPS; i++)
		if (S.popups[i].used && S.popups[i].surface == s) return WB_MAX_OUTPUTS + i;
	return -1;
}

// Popup or bar behind an id; the popup's output for output-level queries.
static Popup *popup_by_id(int32_t id) {
	int i = id - WB_MAX_OUTPUTS;
	if (i < 0 || i >= WB_MAX_POPUPS || !S.popups[i].used) return NULL;
	return &S.popups[i];
}

static int32_t output_of(int32_t id) {
	if (id >= 0 && id < WB_MAX_OUTPUTS) return id;
	Popup *p = popup_by_id(id);
	return p ? p->out : -1;
}

// ---- layer surface ---------------------------------------------------------

static void layer_configure(void *data, struct zwlr_layer_surface_v1 *ls,
                            uint32_t serial, uint32_t w, uint32_t h) {
	Output *o = data;
	zwlr_layer_surface_v1_ack_configure(ls, serial);
	push((wb_event){.type = WB_EV_CONFIGURE, .out = out_index(o), .a = (int32_t)w, .b = (int32_t)h});
}

static void layer_closed(void *data, struct zwlr_layer_surface_v1 *ls) {
	(void)ls;
	Output *o = data;
	if (o->closed) return;
	o->closed = 1;
	push((wb_event){.type = WB_EV_CLOSED, .out = out_index(o)});
}

static const struct zwlr_layer_surface_v1_listener layer_listener = {
	.configure = layer_configure,
	.closed    = layer_closed,
};

static void popup_configure(void *data, struct zwlr_layer_surface_v1 *ls,
                            uint32_t serial, uint32_t w, uint32_t h) {
	Popup *p = data;
	zwlr_layer_surface_v1_ack_configure(ls, serial);
	push((wb_event){.type = WB_EV_CONFIGURE, .out = WB_MAX_OUTPUTS + (int32_t)(p - S.popups),
	                .a = (int32_t)w, .b = (int32_t)h});
}

static void popup_closed(void *data, struct zwlr_layer_surface_v1 *ls) {
	(void)ls;
	Popup *p = data;
	if (p->closed) return;
	p->closed = 1;
	push((wb_event){.type = WB_EV_CLOSED, .out = WB_MAX_OUTPUTS + (int32_t)(p - S.popups)});
}

static const struct zwlr_layer_surface_v1_listener popup_listener = {
	.configure = popup_configure,
	.closed    = popup_closed,
};

static void apply_geometry(Output *o);

static void create_bar(Output *o) {
	if (o->surface || !o->done || !S.compositor || !S.layer_shell) return;
	o->surface = wl_compositor_create_surface(S.compositor);
	wl_surface_set_buffer_scale(o->surface, o->scale);
	o->layer = zwlr_layer_shell_v1_get_layer_surface(
		S.layer_shell, o->surface, o->output, ZWLR_LAYER_SHELL_V1_LAYER_TOP, S.ns);
	apply_geometry(o);
	zwlr_layer_surface_v1_set_keyboard_interactivity(o->layer,
		ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
	zwlr_layer_surface_v1_add_listener(o->layer, &layer_listener, o);
	// Commit without a buffer to request the first configure. The Vulkan
	// swapchain is only created after it (on the Odin side).
	wl_surface_commit(o->surface);
}

static void apply_geometry(Output *o) {
	uint32_t anchor, w = 0, h = 0;
	switch (S.position) {
	case WB_POS_TOP:
		anchor = ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
		         ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
		h = (uint32_t)S.size;
		break;
	case WB_POS_LEFT:
		anchor = ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
		         ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
		w = (uint32_t)S.size;
		break;
	case WB_POS_RIGHT:
		anchor = ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT | ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
		         ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
		w = (uint32_t)S.size;
		break;
	default:
		anchor = ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
		         ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
		h = (uint32_t)S.size;
	}
	// 0 on an axis anchored at both ends = span the whole edge.
	zwlr_layer_surface_v1_set_anchor(o->layer, anchor);
	zwlr_layer_surface_v1_set_size(o->layer, w, h);
	zwlr_layer_surface_v1_set_exclusive_zone(o->layer, S.size);
}

// ---- wl_output -------------------------------------------------------------

static void out_geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph,
                         int32_t sp, const char *make, const char *model, int32_t tr) {
	(void)d; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)sp; (void)make; (void)model; (void)tr;
}
static void out_mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r) {
	(void)d; (void)o; (void)f; (void)w; (void)h; (void)r;
}
static void out_done(void *data, struct wl_output *wo) {
	(void)wo;
	Output *o = data;
	o->done = 1;
	if (S.ready) create_bar(o);
}
static void out_scale(void *data, struct wl_output *wo, int32_t factor) {
	(void)wo;
	Output *o = data;
	o->scale = factor > 0 ? factor : 1;
}
static void out_name(void *data, struct wl_output *wo, const char *name) {
	(void)wo;
	Output *o = data;
	snprintf(o->name, sizeof o->name, "%s", name);
}
static void out_description(void *d, struct wl_output *o, const char *desc) {
	(void)d; (void)o; (void)desc;
}

static const struct wl_output_listener output_listener = {
	.geometry    = out_geometry,
	.mode        = out_mode,
	.done        = out_done,
	.scale       = out_scale,
	.name        = out_name,
	.description = out_description,
};

// ---- wl_pointer ------------------------------------------------------------

// Current cursor (cursor theme name) and the serial of the last enter, which
// wl_pointer_set_cursor requires.
static const char *cursor_name = "default";
static uint32_t    enter_serial;

static void apply_cursor(void) {
	if (!S.cursor_theme || !S.cursor_surface || !S.pointer) return;
	struct wl_cursor *c = wl_cursor_theme_get_cursor(S.cursor_theme, cursor_name);
	// Older themes use the X11 names.
	if (!c && strcmp(cursor_name, "pointer") == 0) c = wl_cursor_theme_get_cursor(S.cursor_theme, "hand2");
	if (!c) c = wl_cursor_theme_get_cursor(S.cursor_theme, "default");
	if (!c) c = wl_cursor_theme_get_cursor(S.cursor_theme, "left_ptr");
	if (!c || c->image_count == 0) return;
	struct wl_cursor_image *img = c->images[0];
	struct wl_buffer *buf = wl_cursor_image_get_buffer(img);
	if (!buf) return;
	wl_pointer_set_cursor(S.pointer, enter_serial, S.cursor_surface,
	                      (int32_t)img->hotspot_x, (int32_t)img->hotspot_y);
	wl_surface_attach(S.cursor_surface, buf, 0, 0);
	wl_surface_damage(S.cursor_surface, 0, 0, (int32_t)img->width, (int32_t)img->height);
	wl_surface_commit(S.cursor_surface);
}

static void set_cursor(uint32_t serial) {
	enter_serial = serial;
	cursor_name = "default";
	apply_cursor();
}

void wb_set_cursor(int32_t pointer) {
	const char *want = pointer ? "pointer" : "default";
	if (strcmp(want, cursor_name) == 0 || S.pointer_out < 0) return;
	cursor_name = want;
	apply_cursor();
	wl_display_flush(S.display);
}

static void ptr_enter(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s,
                      wl_fixed_t x, wl_fixed_t y) {
	(void)d; (void)p;
	S.pointer_out = out_by_surface(s);
	set_cursor(serial);
	if (S.pointer_out >= 0)
		push((wb_event){.type = WB_EV_ENTER, .out = S.pointer_out,
		                .x = wl_fixed_to_double(x), .y = wl_fixed_to_double(y)});
}
static void ptr_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s) {
	(void)d; (void)p; (void)serial;
	int o = out_by_surface(s);
	if (o >= 0) push((wb_event){.type = WB_EV_LEAVE, .out = o});
	S.pointer_out = -1;
}
static void ptr_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) {
	(void)d; (void)p; (void)t;
	if (S.pointer_out < 0) return;
	push((wb_event){.type = WB_EV_MOTION, .out = S.pointer_out,
	                .x = wl_fixed_to_double(x), .y = wl_fixed_to_double(y)});
}
static void ptr_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t t,
                       uint32_t button, uint32_t state) {
	(void)d; (void)p; (void)serial; (void)t;
	if (S.pointer_out < 0) return;
	int b;
	switch (button) {
	case BTN_LEFT:   b = 0; break;
	case BTN_MIDDLE: b = 1; break;
	case BTN_RIGHT:  b = 2; break;
	default: return;
	}
	push((wb_event){.type = WB_EV_BUTTON, .out = S.pointer_out, .a = b,
	                .b = state == WL_POINTER_BUTTON_STATE_PRESSED});
}
static void ptr_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t axis, wl_fixed_t value) {
	(void)d; (void)p; (void)t;
	if (S.pointer_out < 0) return;
	double v = wl_fixed_to_double(value);
	wb_event ev = {.type = WB_EV_AXIS, .out = S.pointer_out};
	if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL) ev.y = v; else ev.x = v;
	push(ev);
}
static void ptr_frame(void *d, struct wl_pointer *p) { (void)d; (void)p; }
static void ptr_axis_source(void *d, struct wl_pointer *p, uint32_t s) { (void)d; (void)p; (void)s; }
static void ptr_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a) {
	(void)d; (void)p; (void)t; (void)a;
}
static void ptr_axis_discrete(void *d, struct wl_pointer *p, uint32_t a, int32_t v) {
	(void)d; (void)p; (void)a; (void)v;
}

static const struct wl_pointer_listener pointer_listener = {
	.enter         = ptr_enter,
	.leave         = ptr_leave,
	.motion        = ptr_motion,
	.button        = ptr_button,
	.axis          = ptr_axis,
	.frame         = ptr_frame,
	.axis_source   = ptr_axis_source,
	.axis_stop     = ptr_axis_stop,
	.axis_discrete = ptr_axis_discrete,
};

// ---- wl_seat ---------------------------------------------------------------

static void seat_caps(void *d, struct wl_seat *seat, uint32_t caps) {
	(void)d;
	int has = (caps & WL_SEAT_CAPABILITY_POINTER) != 0;
	if (has && !S.pointer) {
		S.pointer = wl_seat_get_pointer(seat);
		wl_pointer_add_listener(S.pointer, &pointer_listener, NULL);
	} else if (!has && S.pointer) {
		wl_pointer_release(S.pointer);
		S.pointer = NULL;
	}
}
static void seat_name(void *d, struct wl_seat *s, const char *n) { (void)d; (void)s; (void)n; }

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_caps,
	.name         = seat_name,
};

// ---- registry --------------------------------------------------------------

static uint32_t minu(uint32_t a, uint32_t b) { return a < b ? a : b; }

static void reg_global(void *d, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t ver) {
	(void)d;
	if (strcmp(iface, wl_compositor_interface.name) == 0) {
		S.compositor = wl_registry_bind(reg, name, &wl_compositor_interface, minu(ver, 4));
	} else if (strcmp(iface, wl_shm_interface.name) == 0) {
		S.shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	} else if (strcmp(iface, wl_seat_interface.name) == 0 && !S.seat) {
		S.seat = wl_registry_bind(reg, name, &wl_seat_interface, minu(ver, 5));
		wl_seat_add_listener(S.seat, &seat_listener, NULL);
	} else if (strcmp(iface, zwlr_layer_shell_v1_interface.name) == 0) {
		S.layer_shell = wl_registry_bind(reg, name, &zwlr_layer_shell_v1_interface, minu(ver, 4));
	} else if (strcmp(iface, wl_output_interface.name) == 0) {
		if (ver < 4) {
			fprintf(stderr, "wlbar: wl_output v%u has no name event; ignoring\n", ver);
		}
		for (int i = 0; i < WB_MAX_OUTPUTS; i++) {
			Output *o = &S.outputs[i];
			if (o->used) continue;
			memset(o, 0, sizeof *o);
			o->used   = 1;
			o->global = name;
			o->scale  = 1;
			o->output = wl_registry_bind(reg, name, &wl_output_interface, minu(ver, 4));
			wl_output_add_listener(o->output, &output_listener, o);
			return;
		}
		fprintf(stderr, "wlbar: too many outputs (max %d)\n", WB_MAX_OUTPUTS);
	}
}

static void reg_global_remove(void *d, struct wl_registry *reg, uint32_t name) {
	(void)d; (void)reg;
	for (int i = 0; i < WB_MAX_OUTPUTS; i++) {
		Output *o = &S.outputs[i];
		if (!o->used || o->global != name || o->closed) continue;
		o->closed = 1;
		// Actual teardown happens in wb_output_destroy: Odin must drop the
		// VkSurfaceKHR before the wl_surface goes away.
		push((wb_event){.type = WB_EV_CLOSED, .out = i});
	}
}

static const struct wl_registry_listener registry_listener = {
	.global        = reg_global,
	.global_remove = reg_global_remove,
};

// ---- API -------------------------------------------------------------------

int wb_init(int32_t size, int32_t position, const char *ns) {
	S.size     = size;
	S.position = position;
	S.ns     = ns;
	S.display = wl_display_connect(NULL);
	if (!S.display) {
		fprintf(stderr, "wlbar: could not connect to Wayland (WAYLAND_DISPLAY?)\n");
		return 0;
	}
	S.registry = wl_display_get_registry(S.display);
	wl_registry_add_listener(S.registry, &registry_listener, NULL);
	wl_display_roundtrip(S.display); // globals
	wl_display_roundtrip(S.display); // output/seat events

	if (!S.compositor || !S.layer_shell) {
		fprintf(stderr, "wlbar: compositor sem wl_compositor/zwlr_layer_shell_v1\n");
		return 0;
	}

	if (S.shm) {
		const char *theme = getenv("XCURSOR_THEME");
		const char *size_s = getenv("XCURSOR_SIZE");
		int size = size_s ? atoi(size_s) : 24;
		if (size <= 0) size = 24;
		S.cursor_theme   = wl_cursor_theme_load(theme, size, S.shm);
		S.cursor_surface = wl_compositor_create_surface(S.compositor);
	}

	S.ready = 1;
	for (int i = 0; i < WB_MAX_OUTPUTS; i++)
		if (S.outputs[i].used) create_bar(&S.outputs[i]);
	wl_display_roundtrip(S.display); // first configures
	return 1;
}

void wb_set_geometry(int32_t size, int32_t position) {
	if (size == S.size && position == S.position) return;
	S.size     = size;
	S.position = position;
	for (int i = 0; i < WB_MAX_OUTPUTS; i++) {
		Output *o = &S.outputs[i];
		if (!o->used || !o->layer || o->closed) continue;
		apply_geometry(o);
		wl_surface_commit(o->surface);
	}
	wl_display_flush(S.display);
}

void *wb_display(void) { return S.display; }

void *wb_surface(int32_t out) {
	Popup *p = popup_by_id(out);
	if (p) return p->surface;
	if (out < 0 || out >= WB_MAX_OUTPUTS) return NULL;
	return S.outputs[out].surface;
}

int32_t wb_output_scale(int32_t out) {
	out = output_of(out);
	if (out < 0) return 1;
	return S.outputs[out].scale;
}

const char *wb_output_name(int32_t out) {
	out = output_of(out);
	if (out < 0) return "";
	return S.outputs[out].name;
}

int32_t wb_popup_open(int32_t out, int32_t kind, int32_t edges,
                      int32_t mt, int32_t mr, int32_t mb, int32_t ml,
                      int32_t w, int32_t h) {
	if (out < 0 || out >= WB_MAX_OUTPUTS || !S.outputs[out].used || S.outputs[out].closed) return -1;
	int slot = -1;
	for (int i = 0; i < WB_MAX_POPUPS; i++)
		if (!S.popups[i].used) { slot = i; break; }
	if (slot < 0) return -1;

	Popup *p = &S.popups[slot];
	memset(p, 0, sizeof *p);
	p->used = 1;
	p->out  = out;
	p->kind = kind;
	p->surface = wl_compositor_create_surface(S.compositor);
	wl_surface_set_buffer_scale(p->surface, S.outputs[out].scale);
	if (kind == WB_POPUP_TOOLTIP) {
		// Empty input region: the pointer goes straight through to the bar.
		struct wl_region *none = wl_compositor_create_region(S.compositor);
		wl_surface_set_input_region(p->surface, none);
		wl_region_destroy(none);
	}
	p->layer = zwlr_layer_shell_v1_get_layer_surface(S.layer_shell, p->surface,
		S.outputs[out].output, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
		kind == WB_POPUP_TOOLTIP ? "shellder-tooltip" : "shellder-menu");
	uint32_t anchor = 0;
	if (edges & WB_EDGE_TOP)    anchor |= ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP;
	if (edges & WB_EDGE_BOTTOM) anchor |= ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
	if (edges & WB_EDGE_LEFT)   anchor |= ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
	if (edges & WB_EDGE_RIGHT)  anchor |= ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
	zwlr_layer_surface_v1_set_anchor(p->layer, anchor);
	zwlr_layer_surface_v1_set_margin(p->layer, mt, mr, mb, ml);
	zwlr_layer_surface_v1_set_size(p->layer, (uint32_t)(w > 0 ? w : 0), (uint32_t)(h > 0 ? h : 0));
	// Exclusive zone 0: placed inside the usable area, so it never covers the bar.
	zwlr_layer_surface_v1_set_exclusive_zone(p->layer, 0);
	zwlr_layer_surface_v1_set_keyboard_interactivity(p->layer,
		ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
	zwlr_layer_surface_v1_add_listener(p->layer, &popup_listener, p);
	wl_surface_commit(p->surface);
	wl_display_flush(S.display);
	return WB_MAX_OUTPUTS + slot;
}

void wb_popup_destroy(int32_t id) {
	Popup *p = popup_by_id(id);
	if (!p) return;
	if (S.pointer_out == id) S.pointer_out = -1;
	if (p->layer)   zwlr_layer_surface_v1_destroy(p->layer);
	if (p->surface) wl_surface_destroy(p->surface);
	memset(p, 0, sizeof *p);
	wl_display_flush(S.display);
}

void wb_output_destroy(int32_t out) {
	if (out < 0 || out >= WB_MAX_OUTPUTS) return;
	Output *o = &S.outputs[out];
	if (!o->used) return;
	if (S.pointer_out == out) S.pointer_out = -1;
	if (o->layer)   zwlr_layer_surface_v1_destroy(o->layer);
	if (o->surface) wl_surface_destroy(o->surface);
	if (o->output)  wl_output_release(o->output);
	memset(o, 0, sizeof *o);
	wl_display_flush(S.display);
}

int wb_fd(void) { return wl_display_get_fd(S.display); }

int wb_before_poll(void) {
	while (wl_display_prepare_read(S.display) != 0) {
		if (wl_display_dispatch_pending(S.display) < 0) return -1;
	}
	if (wl_display_flush(S.display) < 0 && errno != EAGAIN) {
		wl_display_cancel_read(S.display);
		return -1;
	}
	return 0;
}

int wb_after_poll(int readable) {
	if (readable) {
		if (wl_display_read_events(S.display) < 0) return -1;
	} else {
		wl_display_cancel_read(S.display);
	}
	if (wl_display_dispatch_pending(S.display) < 0) return -1;
	return 0;
}

int wb_next_event(wb_event *ev) {
	if (S.ev_head >= S.ev_len) {
		S.ev_head = S.ev_len = 0;
		return 0;
	}
	*ev = S.events[S.ev_head++];
	return 1;
}
