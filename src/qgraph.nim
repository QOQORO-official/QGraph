## QGraph engine -- WebAssembly entry points.
##
## Strings cross the boundary as UTF-8: the page writes its argument into the
## input buffer (qg_input) and passes the length; string results are left in
## the output buffer (qg_output_ptr / qg_output_len). Painter frames are left
## in the command buffer (qg_cmd_ptr / qg_cmd_len) for the canvas player.

import std/tables
import jsval, host, canvas, painter, stencils, geometry

{.pragma: wexport, exportc,
  codegenDecl: "__attribute__((export_name(\"$2\"))) $1 $2$3".}

proc NimMain() {.importc, cdecl.}

var initialized = false

proc qg_init() {.wexport.} =
  ## Runs Nim's module initialisers once; the page calls this first.
  if not initialized:
    initialized = true
    NimMain()

var inbuf: string
var outbuf: string
var cmd: ptr seq[float64]
var stats: array[4, float64]

proc qg_input(n: int32): pointer {.wexport.} =
  ## Buffer for the next string argument (n bytes).
  inbuf.setLen(n)
  if n == 0: nil else: addr inbuf[0]

proc arg(n: int32): string {.inline.} =
  result = inbuf
  result.setLen(n)

proc setOutput(s: sink string) {.inline.} = outbuf = s

proc qg_output_ptr(): pointer {.wexport.} =
  if outbuf.len == 0: nil else: addr outbuf[0]

proc qg_output_len(): int32 {.wexport.} = int32(outbuf.len)

proc qg_cmd_ptr(): pointer {.wexport.} =
  if cmd == nil or cmd[].len == 0: nil else: addr cmd[][0]

proc qg_cmd_len(): int32 {.wexport.} =
  if cmd == nil: 0 else: int32(cmd[].len)

proc qg_stats_ptr(): pointer {.wexport.} = addr stats[0]

proc parseArg(n: int32): Val =
  try: parseJson(arg(n))
  except JsonError: nil

# -------------------------------------------------------------- painters --

var painters: seq[ScenePainter]

proc qg_painter_new(): int32 {.wexport.} =
  painters.add newScenePainter()
  int32(painters.len - 1)

proc qg_painter_free(h: int32) {.wexport.} =
  if h >= 0 and h < painters.len: painters[h] = newScenePainter()

proc qg_painter_sync(h: int32, n: int32) {.wexport.} =
  let items = parseArg(n)
  var list: seq[Val]
  for it in items:
    if it.isObj: list.add it
  painters[h].sync(list)

proc qg_painter_upsert(h: int32, n: int32) {.wexport.} =
  let items = parseArg(n)
  var list: seq[Val]
  for it in items:
    if it.isObj: list.add it
  painters[h].upsert(list)

proc qg_painter_remove(h: int32, n: int32) {.wexport.} =
  let ids = parseArg(n)
  painters[h].remove(toStrSeq(ids))

proc qg_painter_render(h: int32, n: int32) {.wexport.} =
  ## Renders one frame; the commands are left in the command buffer and
  ## [visible, total, pixelWidth, pixelHeight] in the stats array.
  let view = parseArg(n)
  let p = painters[h]
  let s = p.render(view)
  cmd = addr p.ctx.buf
  stats = [float64(s.visible), float64(s.total), float64(s.pixelWidth), float64(s.pixelHeight)]

proc qg_painter_has_layered(h: int32): int32 {.wexport.} =
  if painters[h].hasLayeredItems: 1 else: 0

proc qg_painter_visible_media(h: int32, n: int32) {.wexport.} =
  ## Visible items that carry media (src or mediaLayers), for the page's
  ## animation bookkeeping.
  let view = parseArg(n)
  let arr = newArr()
  for item in painters[h].getVisibleItems(view):
    if item.tr("src") or item["mediaLayers"].isArr:
      let o = newObj()
      o["id"] = item["id"]
      for k in ["src", "mediaType", "mediaLoop", "mediaLayers"]:
        let v = item.get(k)
        if v != nil: o.put(k, v)
      arr.push o
  setOutput(toJson(arr))

proc qg_register_stencils(n: int32) {.wexport.} =
  stencils.register(parseArg(n))

proc qg_reset_strings() {.wexport.} = resetInterning()

proc qg_item_bounds(n: int32) {.wexport.} =
  ## PixelGeometry.itemBounds for the page: {item, items} -> bounds JSON.
  let arg = parseArg(n)
  var scene = initTable[string, Val]()
  for it in arg["items"]:
    if it.isObj: scene[idOf(it)] = it
  setOutput(toJson(rectVal(itemBounds(arg["item"], scene))))
