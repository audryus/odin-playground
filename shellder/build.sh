#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

# Directory that CONTAINS the `skald/` folder (not the skald folder itself).
SKALD_ROOT="vendor/Skald"

# 0. Shellder's patches to Skald (patches/*.patch), idempotent. Currently only
#    the text shader, so the font renders like the Omarchy bar.
for patch in patches/*.patch; do
    [[ -e "$patch" ]] || continue
    if git -C "$SKALD_ROOT" apply --check "../../$patch" 2>/dev/null; then
        git -C "$SKALD_ROOT" apply "../../$patch"
        echo "patch applied: $patch"
    elif ! git -C "$SKALD_ROOT" apply --reverse --check "../../$patch" 2>/dev/null; then
        echo "warning: $patch does not apply to this Skald version" >&2
    fi
done
if [[ "$SKALD_ROOT/skald/shaders/ui.frag" -nt "$SKALD_ROOT/skald/shaders/ui.frag.spv" ]]; then
    if command -v glslc >/dev/null; then
        glslc "$SKALD_ROOT/skald/shaders/ui.frag" -o "$SKALD_ROOT/skald/shaders/ui.frag.spv"
        echo "shader recompiled"
    else
        echo "warning: glslc (shaderc) not found; text shader not recompiled" >&2
    fi
fi

# 1. wlr-layer-shell protocol code + native C code
#    -> build/libshellder_native.a
PROTO=protocols/wlr-layer-shell-unstable-v1.xml
wayland-scanner client-header "$PROTO" build/wlr-layer-shell-unstable-v1-client-protocol.h
wayland-scanner private-code  "$PROTO" build/wlr-layer-shell-unstable-v1-protocol.c

# The protocol references xdg_popup; the generated code needs xdg-shell.
XDG=/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
wayland-scanner private-code "$XDG" build/xdg-shell-protocol.c

CFLAGS="-O2 -Wall -Wextra -fPIC -Ibuild $(pkg-config --cflags wayland-client wayland-cursor)"
cc $CFLAGS -c native/wlbar.c                               -o build/wlbar.o
cc $CFLAGS -c native/proc.c                                -o build/proc.o
cc $CFLAGS -c build/wlr-layer-shell-unstable-v1-protocol.c -o build/layer-shell.o
cc $CFLAGS -c build/xdg-shell-protocol.c                   -o build/xdg-shell.o
rm -f build/libshellder_native.a
ar rcs build/libshellder_native.a build/wlbar.o build/proc.o build/layer-shell.o build/xdg-shell.o

# 2. Shellder itself (Odin)
odin build . \
    -collection:gui="${SKALD_ROOT}" \
    -o:speed \
    -out:build/shellder

if [[ "${1:-}" == "run" ]]; then
    exec ./build/shellder
fi
