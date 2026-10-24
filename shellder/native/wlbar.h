// wlbar — shim mínimo de Wayland para o Shellder.
//
// Cuida do que o Skald não faz no modo embedded: conectar no compositor,
// criar uma layer-surface (wlr-layer-shell) por wl_output, presa numa das
// bordas da tela,
// e traduzir eventos de ponteiro. O Odin consome tudo via wb_next_event.
#pragma once
#include <stdint.h>

#define WB_MAX_OUTPUTS 16

enum {
	WB_EV_CONFIGURE = 1, // out, a=w, b=h (logical px) — surface pronta/redimensionada
	WB_EV_CLOSED,        // out — monitor removido ou surface fechada pelo compositor
	WB_EV_ENTER,         // out, x, y
	WB_EV_LEAVE,         // out
	WB_EV_MOTION,        // out, x, y
	WB_EV_BUTTON,        // out, a=0 left / 1 middle / 2 right, b=pressed
	WB_EV_AXIS,          // out, x=horizontal, y=vertical (positivo = para baixo)
};

typedef struct {
	int32_t type;
	int32_t out;
	int32_t a, b;
	double  x, y;
} wb_event;

enum { WB_POS_BOTTOM = 0, WB_POS_TOP, WB_POS_LEFT, WB_POS_RIGHT };

// size = espessura da barra (altura se horizontal, largura se vertical).
int         wb_init(int32_t size, int32_t position, const char *namespace_);
// Muda espessura e borda de todas as barras (o compositor manda um novo
// configure para cada uma).
void        wb_set_geometry(int32_t size, int32_t position);
// Cursor sobre a barra: 1 = mão (item clicável), 0 = seta.
void        wb_set_cursor(int32_t pointer);
void       *wb_display(void);
void       *wb_surface(int32_t out);
int32_t     wb_output_scale(int32_t out);
const char *wb_output_name(int32_t out);
void        wb_output_destroy(int32_t out);

int         wb_fd(void);
// Chame antes do poll(); retorna -1 se a conexão caiu.
int         wb_before_poll(void);
// Chame depois do poll(); readable != 0 se o fd tinha dados.
int         wb_after_poll(int readable);
int         wb_next_event(wb_event *ev);
