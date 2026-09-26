# QGraph

The canvas-based mxGraph-style diagram editor, with its scene engine and
painter rewritten in **Nim and compiled to WebAssembly**. The page looks and
behaves like the JavaScript editor it came from: the same GraphEditor chrome,
the same shapes, handles, connectors, tables, layers and media nodes.

The programming nodes (the Visual Script tab, CScript) are not part of this
build, and neither are PowerPoint paste, the server bridge, or Mobile Lite.

## What runs where

| Nim → `web/js/qgraph.wasm` | JavaScript (`web/js`) |
| --- | --- |
| Scene model, ids, z-order, groups, containers and stack layouts, tables, layers | Menus, toolbar, sidebar, format panel, dialogs (`EditorUi`, `Sidebar`, …) |
| Undo/redo snapshots, clipboard, style copy/paste, defaults | DOM event wiring, the text-editor `contenteditable`, tooltips |
| Hit-testing (spatial grid), selection, rubber band, handles, guides and snapping | `Graph.js`: a facade with the original `Graph` API that forwards to the engine |
| Pointer, keyboard, drag-and-drop and text-edit state machines | Canvas2D replay of the engine's command buffers (`QGraphWasm.js`) |
| Connector routing (orthogonal, elbow, curved), anchors, ports, waypoints | Image, GIF and video decoding, the YouTube and media overlays |
| The painter: every shape, stencil, rich-text layout, grid, page view and overlay | Offscreen render worker, which runs a second engine instance |
| JSON save/load | mxGraph / `.qochart` XML import (`MxGraphFormat.js`) |

The engine draws by recording Canvas2D calls into a `float64` command buffer.
`QGraphWasm.js` replays that buffer onto a real canvas, on the main thread for
realtime frames and inside the worker for settled ones. Text measurement,
`Math` and number formatting are imported from the browser, so layout and
geometry match the JavaScript editor bit for bit.

## Build

Requirements: `clang` and `wasm-ld` (LLVM 11 or newer). If `nim` is not on
`PATH`, the build downloads Nim 2.0.14 into `build/.cache`.

```sh
bash tools/build.sh          # -> web/js/qgraph.wasm
python3 -m http.server 8123  # then open http://localhost:8123/web/
```

There is no emscripten and no WASI. Nim emits C, clang compiles it for a
freestanding `wasm32` target against `build/inc` and `build/libc.c`, and
`wasm-ld` links a single module whose only imports are the small `env` host
interface in `QGraphWasm.js`.

## Tests

```sh
npm install                  # Playwright
python3 -m http.server 8123 &
node tests/ui/golden.js      # 62 scripted scenarios vs. snapshots from the original
```

`tests/ui/scenarios.js` drives the editor with real mouse and keyboard input:

- moving, resizing and rotating shapes, and rubber-band selection
- connecting shapes, dragging edge ends, adding waypoints
- text and table-cell editing
- undo/redo, copy/paste, grouping, locking, align and distribute
- layers, folding, page view, zoom and scroll
- mxGraph import, sidebar drag-and-drop, and export

The goldens in `tests/ui/golden/` were recorded from the original JavaScript
editor. The port must reproduce each resulting document and selection exactly.

Two more harnesses compare against the original directly. They need its
sources, which are kept out of the repository:

- `tests/ui/compare.js` replays the same scenarios in both editors and diffs
  the document JSON and full-page screenshots.
- `tests/parity/run.js` renders a scene that covers every shape with both
  painters and diffs the pixels.

## Layout

```
src/            Nim engine
  jsval.nim       JS-semantics values (undefined/null, ordered keys, exact JSON)
  canvas.nim      Canvas2D command recorder
  painter.nim     scene painter (shapes, text, edges, grid, media slots)
  stencils.nim    mxGraph stencil programs      richtext.nim   rich-text layout
  graph*.nim      model, hit-testing, input, overlay, RPC table
  qgraph.nim      wasm exports
web/            the static site (index.html, js/, styles/, stencils/)
tools/          build.sh, stamp.sh (cache-busting on deploy), gen_decls.py
tests/          Playwright harnesses
```

Pushing to `main` builds the engine, runs the behaviour tests and deploys
`web/` to GitHub Pages (`.github/workflows/deploy.yml`).
