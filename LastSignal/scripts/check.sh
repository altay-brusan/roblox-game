#!/usr/bin/env bash
# Static verification for LAST SIGNAL.
#   1. rojo sourcemap  -> lets the analyzer resolve require() across modules
#   2. luau-lsp analyze -> full type check against the real Roblox API surface
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="/c/Projects/roblox/tools/bin"
DEFS="C:/Projects/roblox/tools/dl/globalTypes.d.luau"
cd "$ROOT"

echo "== sourcemap =="
"$BIN/rojo.exe" sourcemap default.project.json --output sourcemap.json || exit 1

echo "== syntax (luau-compile) =="
fail=0
while IFS= read -r f; do
  if ! "$BIN/luau-compile.exe" --binary -O0 "$f" > /dev/null 2>&1; then
    echo "SYNTAX FAIL: $f"
    "$BIN/luau-compile.exe" --binary -O0 "$f" 2>&1 | head -5
    fail=1
  fi
done < <(find src -name '*.luau')
[ $fail -eq 0 ] && echo "all files compile"

echo "== analyze (luau-lsp) =="
"$BIN/luau-lsp.exe" analyze \
  --definitions="$DEFS" \
  --sourcemap=sourcemap.json \
  --settings=.luaurc.analyze.json \
  --ignore="**/_Index/**" \
  src
echo "analyze exit=$?"
