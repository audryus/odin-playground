#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

# Diretório que CONTÉM a pasta `skald/` (não a pasta skald em si).
SKALD_ROOT="vendor/Skald"

odin build . \
    -collection:gui="${SKALD_ROOT}" \
    -debug \
    -out:build/skald_example

if [[ "${1:-}" == "run" ]]; then
    exec ./build/skald_example
fi
