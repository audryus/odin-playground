# Hello World em Odin + raylib, para desktop e web (WebAssembly via Emscripten).
#
#   make run      compila e roda no desktop
#   make build    só compila o binário desktop em build/
#   make emsdk    baixa e instala o Emscripten em vendor/emsdk (uma vez só)
#   make web      compila para web em build/web/
#   make serve    compila para web e serve em http://localhost:8080
#   make clean    apaga build/

ODIN       := odin
ODIN_ROOT  := $(shell $(ODIN) root)
OUT_DIR    := build
WEB_DIR    := $(OUT_DIR)/web
PORT       := 8080

EMSDK_REPO := https://github.com/emscripten-core/emsdk.git
EMSDK_DIR  := vendor/emsdk
# Carrega o emcc do emsdk local antes de cada comando que precisa dele.
EMSDK_ENV  := EMSDK_QUIET=1 . $(EMSDK_DIR)/emsdk_env.sh &&

# O build web linka com a raylib compilada para wasm que já vem com o Odin.
EMCC_FLAGS := -sUSE_GLFW=3 -sALLOW_MEMORY_GROWTH -sASSERTIONS \
              -sWARN_ON_UNDEFINED_SYMBOLS=0 \
              --shell-file web/index.html

.PHONY: all build run emsdk web serve clean

all: build

build:
	mkdir -p $(OUT_DIR)
	$(ODIN) build . -out:$(OUT_DIR)/hello-raylib

run:
	mkdir -p $(OUT_DIR)
	$(ODIN) run . -out:$(OUT_DIR)/hello-raylib

emsdk: $(EMSDK_DIR)/.installed

$(EMSDK_DIR)/.installed:
	mkdir -p vendor
	[ -d $(EMSDK_DIR) ] || git clone --depth 1 $(EMSDK_REPO) $(EMSDK_DIR)
	cd $(EMSDK_DIR) && ./emsdk install latest && ./emsdk activate latest
	touch $@

# 1. Odin gera um objeto wasm (js_wasm32) com o jogo.
# 2. emcc linka esse objeto + raylib + main.c e gera index.html/js/wasm.
# 3. odin.js fornece os imports que o runtime do Odin espera.
web: emsdk
	mkdir -p $(WEB_DIR)
	$(ODIN) build web -target:js_wasm32 -build-mode:obj \
		-define:RAYLIB_WASM_LIB=env.o -out:$(WEB_DIR)/game.wasm.o
	cp $(ODIN_ROOT)/core/sys/wasm/js/odin.js $(WEB_DIR)/
	$(EMSDK_ENV) emcc -o $(WEB_DIR)/index.html web/main.c $(WEB_DIR)/game.wasm.o \
		$(ODIN_ROOT)/vendor/raylib/wasm/libraylib.web.a $(EMCC_FLAGS)
	rm $(WEB_DIR)/game.wasm.o

# Precisa de um servidor HTTP: o navegador não carrega .wasm via file://.
serve: web
	python -m http.server $(PORT) --directory $(WEB_DIR)

clean:
	rm -rf $(OUT_DIR)
