# QGraph

A canvas diagram editor written in **Nim and compiled to WebAssembly**. The
whole application is Nim: the GraphEditor-style UI (menus, toolbar, shape
sidebar, format panel, dialogs, layers and outline windows), the diagram
engine, the painter, the file formats and the media pipeline. The page ships
one small, generic JavaScript host (`web/js/qweb.js`) and one module
(`web/js/qgraph.wasm`).

Layout, behaviour and pixels match the JavaScript mxGraph-style editor it
replaces. The programming nodes (Visual Script, CScript), PowerPoint paste,
the server bridge and Mobile Lite are not part of this build.

Live: https://qoqoro-official.github.io/QGraph/

## Architecture

```
index.html ── qweb.js (generic host, no app logic) ── qgraph.wasm (everything else)
                    │                                        │
                    ├── Web Worker × N  render bands  ───────┤ same module, role = render
                    └── Web Worker      GIF / file encode ───┘ same module, role = media
```

**qweb: bindweb-style DOM.** Nim never calls the DOM one method at a time.
DOM mutations (create, append, attributes, styles, classes, text, listeners)
are appended to a byte command buffer, and element handles are integers that
Nim allocates itself. Building the whole shell, including hundreds of SVG
palette thumbnails, takes a handful of `flush()` calls. Reads such as layout,
form values and queries flush first and then answer synchronously. Events
are dispatched straight into Nim, so Nim decides `preventDefault` and
`stopPropagation`. Typed reflection (`get`, `invoke`, `construct`) covers the
long tail of browser APIs: video, iframes, fullscreen, clipboard and
`ResizeObserver`.

**Memory.** Scene values, rich-text runs and command lists are Nim objects
under ARC, freed deterministically. There is no JS object graph and no
JSON boundary between the UI and the engine: the chrome calls engine procs
directly.

**Rendering.** The painter records Canvas2D calls into a `float64` command
buffer that the host replays. Full-resolution frames are painted by a pool of
render workers, one per spare core, up to four. Each worker holds its own copy
of the scene and paints one horizontal band of the viewport, so a heavy frame
is rasterised on every core at once. The bands come back as transferable
`ImageBitmap`s, are stitched and presented through WebGL. During a gesture the
main-thread painter, which shares the live scene, draws realtime frames.
`?bands=N` sets the pool size and `?renderer=canvas2d` forces the Canvas2D
presenter.

**Media.** GIFs are decoded one frame at a time (LZW and compositing in Nim)
in a media worker. Files picked for embedding are base64-encoded there too.
Video and YouTube overlays are driven from Nim.

**Formats, all in Nim:**
- a strict XML parser
- mxGraph / `.qochart` import and round-trip export
- stencil libraries
- an SVG-to-diagram converter
- HTML-to-rich-text conversion, with the browser's HTML parser supplying the
  tree snapshot

## Build

Requirements: `clang` and `wasm-ld` (LLVM 11 or newer). If `nim` is not on
`PATH`, the build downloads Nim 2.0.14 into `build/.cache`.

```sh
bash tools/build.sh          # -> web/js/qgraph.wasm
python3 -m http.server 8123  # then open http://localhost:8123/web/
```

There is no emscripten and no WASI. Nim emits C, clang compiles it for a
freestanding `wasm32` target against `build/inc` and `build/libc.c`, and
`wasm-ld` links one module. `bash tools/check.sh` type-checks without
compiling.

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

The goldens were recorded from the original JavaScript editor; each resulting
document and selection must match exactly. Scripts reach the Nim application
through the automation proxies `window.graph` and `window.editorUi`.

`tests/ui/compare.js` replays the scenarios against the original editor, whose
sources are kept out of the repository, and diffs the full-page screenshots
as well.

## Layout

```
src/              engine
  jsval.nim         JS-semantics values (undefined/null, ordered keys, exact JSON)
  canvas.nim        Canvas2D command recorder
  painter.nim       scene painter      stencils.nim, richtext.nim
  graph*.nim        model, hit-testing, input state machines, overlay, method table
src/web/qweb.nim  bindings for the host: DOM buffer, events, timers, I/O, workers
src/app/          the application
  main.nim          qw_main / qw_worker_main, automation surface
  editorui.nim      shell; includes ui_shell, ui_format, ui_windows, ui_dialogs,
                    actions, toolbar, sidebar, editor_doc
  view.nim          canvas view: surface, input, label editor, export
  renderer.nim      presentation and the band-parallel render pool
  worker.nim        worker roles (render bands, GIF decode, file encoding)
  media.nim, overlay.nim, gif.nim            images, GIF, video, YouTube
  xml.nim, legacy.nim, mxformat.nim, stencilxml.nim, svgconvert.nim,
  htmltree.nim, richhtml.nim, shapesvg.nim   formats and previews
web/              index.html, js/qweb.js, js/qgraph.wasm, styles, stencils
tools/            build.sh, check.sh, stamp.sh (cache-busting on deploy)
tests/ui/         Playwright harnesses and goldens
```

Pushing to `main` builds the module, runs the behaviour tests and deploys
`web/` to GitHub Pages (`.github/workflows/deploy.yml`).
