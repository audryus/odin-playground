#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

# Diretório que CONTÉM a pasta `skald/` (não a pasta skald em si).
SKALD_ROOT="vendor/Skald"

# 0. Patches do Shellder no Skald (patches/*.patch), idempotentes. Hoje só o
#    shader de texto, para a fonte ficar igual à da barra do Omarchy.
for patch in patches/*.patch; do
    [[ -e "$patch" ]] || continue
    if git -C "$SKALD_ROOT" apply --check "../../$patch" 2>/dev/null; then
        git -C "$SKALD_ROOT" apply "../../$patch"
        echo "patch aplicado: $patch"
    elif ! git -C "$SKALD_ROOT" apply --reverse --check "../../$patch" 2>/dev/null; then
        echo "aviso: $patch não aplica nesta versão do Skald" >&2
    fi
done
if [[ "$SKALD_ROOT/skald/shaders/ui.frag" -nt "$SKALD_ROOT/skald/shaders/ui.frag.spv" ]]; then
    if command -v glslc >/dev/null; then
        glslc "$SKALD_ROOT/skald/shaders/ui.frag" -o "$SKALD_ROOT/skald/shaders/ui.frag.spv"
        echo "shader recompilado"
    else
        echo "aviso: glslc (shaderc) não encontrado; shader do texto não recompilado" >&2
    fi
fi

# 1. Código do protocolo wlr-layer-shell + código nativo em C
#    -> build/libshellder_native.a
PROTO=protocols/wlr-layer-shell-unstable-v1.xml
wayland-scanner client-header "$PROTO" build/wlr-layer-shell-unstable-v1-client-protocol.h
wayland-scanner private-code  "$PROTO" build/wlr-layer-shell-unstable-v1-protocol.c

# O protocolo referencia xdg_popup; o código gerado precisa do xdg-shell.
XDG=/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
wayland-scanner private-code "$XDG" build/xdg-shell-protocol.c

CFLAGS="-O2 -Wall -Wextra -fPIC -Ibuild $(pkg-config --cflags wayland-client wayland-cursor)"
cc $CFLAGS -c native/wlbar.c                               -o build/wlbar.o
cc $CFLAGS -c native/proc.c                                -o build/proc.o
cc $CFLAGS -c build/wlr-layer-shell-unstable-v1-protocol.c -o build/layer-shell.o
cc $CFLAGS -c build/xdg-shell-protocol.c                   -o build/xdg-shell.o
rm -f build/libshellder_native.a
ar rcs build/libshellder_native.a build/wlbar.o build/proc.o build/layer-shell.o build/xdg-shell.o

# 2. O Shellder em Odin
odin build . \
    -collection:gui="${SKALD_ROOT}" \
    -o:speed \
    -out:build/shellder

if [[ "${1:-}" == "run" ]]; then
    exec ./build/shellder
fi
