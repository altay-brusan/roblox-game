#!/usr/bin/env bash
# Builds the editable place file.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="/c/Projects/roblox/tools/bin"
cd "$ROOT"
mkdir -p build
"$BIN/rojo.exe" build default.project.json --output build/LastSignal.rbxlx
ls -lh build/LastSignal.rbxlx
