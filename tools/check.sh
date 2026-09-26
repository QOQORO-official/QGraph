#!/usr/bin/env bash
# Fast type-check of the Nim sources (no C compilation or linking).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/tools/gen_decls.py" >/dev/null
"$ROOT/build/.cache/nim-2.0.14/bin/nim" check --cpu:wasm32 --os:any --mm:arc -d:useMalloc \
  --exceptions:goto --panics:on --noMain:on --hints:off "$ROOT/${2:-src/app/main.nim}" 2>&1 | grep -v "Warning" | head -${1:-15}
