// wlbar — minimal Wayland shim for Shellder.
//
// Does what Skald's embedded mode leaves to the host: connect to the
// compositor, create one layer surface (wlr-layer-shell) per wl_output
// anchored to a screen edge, and translate pointer events. Odin consumes
// everything through wb_next_event.
#pragma once
#include <stdint.h>

#define WB_MAX_OUTPUTS 16

enum {
	WB_EV_CONFIGURE = 1, // out, a=w, b=h (logical px) — surface ready/resized
	WB_EV_CLOSED,        // out — output removed or surface closed by the compositor
	WB_EV_ENTER,         // out, x, y
	WB_EV_LEAVE,         // out
	WB_EV_MOTION,        // out, x, y
	WB_EV_BUTTON,        // out, a=0 left / 1 middle / 2 right, b=pressed
	WB_EV_AXIS,          // out, x=horizontal, y=vertical (positive = down)
};

typedef struct {
	int32_t type;
	int32_t out;
	int32_t a, b;
	double  x, y;
} wb_event;

enum { WB_POS_BOTTOM = 0, WB_POS_TOP, WB_POS_LEFT, WB_POS_RIGHT };

// size = bar thickness (height when horizontal, width when vertical).
int         wb_init(int32_t size, int32_t position, const char *namespace_);
// Changes thickness and edge of every bar (the compositor sends a new
// configure for each).
void        wb_set_geometry(int32_t size, int32_t position);
// Cursor over the bar: 1 = hand (clickable item), 0 = arrow.
void        wb_set_cursor(int32_t pointer);
void       *wb_display(void);
void       *wb_surface(int32_t out);
int32_t     wb_output_scale(int32_t out);
const char *wb_output_name(int32_t out);
void        wb_output_destroy(int32_t out);

int         wb_fd(void);
// Call before poll(); returns -1 if the connection dropped.
int         wb_before_poll(void);
// Call after poll(); readable != 0 if the fd had data.
int         wb_after_poll(int readable);
int         wb_next_event(wb_event *ev);
