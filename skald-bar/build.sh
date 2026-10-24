#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

# Diretório que CONTÉM a pasta `skald/` (não a pasta skald em si).
SKALD_ROOT="vendor/Skald"

# 1. Código do protocolo wlr-layer-shell + shim Wayland em C -> libwlbar.a
PROTO=protocols/wlr-layer-shell-unstable-v1.xml
wayland-scanner client-header "$PROTO" build/wlr-layer-shell-unstable-v1-client-protocol.h
wayland-scanner private-code  "$PROTO" build/wlr-layer-shell-unstable-v1-protocol.c

# O protocolo referencia xdg_popup; o código gerado precisa do xdg-shell.
XDG=/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
wayland-scanner private-code "$XDG" build/xdg-shell-protocol.c

CFLAGS="-O2 -Wall -Wextra -fPIC -Ibuild $(pkg-config --cflags wayland-client wayland-cursor)"
cc $CFLAGS -c wl/wlbar.c                                -o build/wlbar.o
cc $CFLAGS -c build/wlr-layer-shell-unstable-v1-protocol.c -o build/layer-shell.o
cc $CFLAGS -c build/xdg-shell-protocol.c                -o build/xdg-shell.o
ar rcs build/libwlbar.a build/wlbar.o build/layer-shell.o build/xdg-shell.o

# 2. A barra em Odin
odin build . \
    -collection:gui="${SKALD_ROOT}" \
    -debug \
    -out:build/skald-bar

if [[ "${1:-}" == "run" ]]; then
    exec ./build/skald-bar
fi
