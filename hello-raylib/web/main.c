#include <emscripten/emscripten.h>

// Exportados pelo Odin.
extern void _start(void);     // inicializa o runtime do Odin e chama main
extern void web_update(void); // desenha um frame

int main(void) {
	_start();
	emscripten_set_main_loop(web_update, 0, 1);
	return 0;
}
