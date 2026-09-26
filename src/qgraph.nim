## QGraph engine -- WebAssembly entry points.
##
## Strings cross the boundary as UTF-8: the page writes its argument into the
## input buffer (qg_input) and passes the length; string results are left in
## the output buffer (qg_output_ptr / qg_output_len). Painter frames are left
## in the command buffer (qg_cmd_ptr / qg_cmd_len) for the canvas player.

import std/tables
import jsval, host, canvas, painter, stencils, geometry, richtext

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
  if currentCmd == nil or currentCmd[].len == 0: nil else: addr currentCmd[][0]

proc qg_cmd_len(): int32 {.wexport.} =
  if currentCmd == nil: 0 else: int32(currentCmd[].len)

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
  currentCmd = addr p.ctx.buf
  stats = [float64(s.visible), float64(s.total), float64(s.pixelWidth), float64(s.pixelHeight)]

proc qg_painter_draw(h: int32, n: int32) {.wexport.} =
  ## Draws a list of items without clearing or transforming the target.
  let items = parseArg(n)
  var list: seq[Val]
  for it in items:
    if it.isObj: list.add it
  painters[h].drawList(list)
  currentCmd = addr painters[h].ctx.buf

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

# ----------------------------------------------------------------- graph --
# One editor per page. The page's Graph facade (web/js/Graph.js) forwards DOM
# input to the entry points below and every other method through qg_call.

import graph as graphmod

var theGraph: Graph

proc legacyHooks(): GraphHooks =
  ## The page facade (web/js/Graph.js) receives engine callbacks as JSON
  ## host calls.
  result.emit = proc(name: string, data: Val) =
    let payload = newObj()
    payload["name"] = jstr(name)
    if data != nil: payload["data"] = data
    discard hostCall(HostEmit, toJson(payload))
  result.render = proc(view: Val, realtime: bool) =
    discard hostCall(HostRender, toJson(obj(("view", view), ("realtime", jbool(realtime)))))
  result.spacer = proc(width, height: float64) =
    discard hostCall(HostSpacer, toJson(obj(("width", jnum(width)), ("height", jnum(height)))))
  result.rendererSync = proc(media: Val) =
    discard hostCall(HostRendererSync, toJson(obj(("media", media))))
  result.rendererUpsert = proc(ids: seq[string], deferWorker: bool, media: Val) =
    let payload = obj(("ids", idsVal(ids)), ("defer", jbool(deferWorker)))
    if media != nil: payload["media"] = media
    discard hostCall(HostRendererUpsert, toJson(payload))
  result.rendererRemove = proc(ids: seq[string]) =
    discard hostCall(HostRendererRemove, toJson(obj(("ids", idsVal(ids)))))
  result.overlay = proc(ctx: Ctx) = discard hostCall(HostOverlay)
  result.cursor = proc(cursor: string) =
    discard hostCall(HostCursor, toJson(obj(("cursor", jstr(cursor)))))
  result.tooltip = proc(show: bool, id, text: string) =
    if show: discard hostCall(HostTooltip, toJson(obj(("id", jstr(id)), ("text", jstr(text)))))
    else: discard hostCall(HostTooltip, toJson(obj(("hide", jtrue))))
  result.timer = proc(name: string, ms: float64, cancel: bool) =
    if cancel: discard hostCall(HostTimer, toJson(obj(("name", jstr(name)), ("cancel", jtrue))))
    else: discard hostCall(HostTimer, toJson(obj(("name", jstr(name)), ("ms", jnum(ms)))))
  result.openLink = proc(href: string) =
    discard hostCall(HostOpenLink, toJson(obj(("href", jstr(href)))))
  result.textEditorOpen = proc(d: Val) = discard hostCall(HostTextEditorOpen, toJson(d))
  result.textEditorClose = proc(): (string, Val) =
    let reply = hostCall(HostTextEditorClose)
    if reply.len == 0: return ("", nil)
    try:
      let r = parseJson(reply)
      (strOrEmpty(r["plain"]), r["model"])
    except JsonError: ("", nil)

proc qg_graph_new(mobileMode: int32): int32 {.wexport.} =
  ## Creates the editor; returns the handle of its realtime painter, which
  ## shares the editor's scene.
  fromHtmlHook = proc(html: string): Val =
    let reply = hostCall(HostRichFromHtml, html)
    if reply.len == 0: return nil
    try: parseJson(reply) except JsonError: nil
  theGraph = newGraph(mobileMode != 0)
  theGraph.hooks = legacyHooks()
  painters.add theGraph.painter
  int32(painters.len - 1)

proc qg_graph_start() {.wexport.} = theGraph.start()

proc pointerEv(x, y: float64, button, flags: int32): PointerEv =
  PointerEv(screen: pt(x, y), button: button, shift: (flags and 1) != 0,
            ctrl: (flags and 2) != 0, meta: (flags and 4) != 0, alt: (flags and 8) != 0,
            touch: (flags and 16) != 0)

proc qg_pointer(kind: int32, x, y: float64, button, flags: int32): int32 {.wexport.} =
  ## kind: 0 down, 1 move, 2 up/cancel, 3 dblclick, 4 leave.
  let ev = pointerEv(x, y, button, flags)
  case kind
  of 0: int32(theGraph.pointerDown(ev))
  of 1: int32(theGraph.pointerMove(ev))
  of 2: int32(theGraph.pointerUp(ev))
  of 3: int32(theGraph.doubleClick(ev))
  else:
    theGraph.pointerLeave()
    0

proc qg_context_menu(x, y: float64, flags: int32) {.wexport.} =
  setOutput(toJson(theGraph.contextMenu(pointerEv(x, y, 2, flags))))

proc qg_key(down: int32, flags: int32, n: int32): int32 {.wexport.} =
  ## Keyboard input: the argument is "key\tcode".
  let text = arg(n)
  let tab = text.find('\t')
  let key = if tab < 0: text else: text[0 ..< tab]
  let code = if tab < 0: "" else: text[tab + 1 .. ^1]
  if down == 0:
    theGraph.keyUp(code)
    return 0
  int32(theGraph.keyDown(key, code, (flags and 1) != 0, (flags and 2) != 0,
                         (flags and 4) != 0, (flags and 8) != 0))

proc qg_drag_over(x, y: float64, shape: int32) {.wexport.} =
  theGraph.dragOver(pt(x, y), shape != 0)

proc qg_drag_clear() {.wexport.} = theGraph.clearReplaceTarget()

proc qg_drop(x, y: float64, n: int32) {.wexport.} =
  let node = theGraph.drop(pt(x, y), parseArg(n))
  setOutput(if node == nil: "null" else: toJson(node))

proc qg_timer(n: int32) {.wexport.} =
  if arg(n) == "autoscroll": theGraph.dragAutoScrollTick()

proc qg_text_editor_finish(commit: int32) {.wexport.} = theGraph.finishTextEdit(commit != 0)
proc qg_text_editor_tab(backwards: int32) {.wexport.} = theGraph.textEditorTab(backwards != 0)

proc qg_render(force: int32) {.wexport.} = theGraph.render(force != 0)
proc qg_draw_overlay() {.wexport.} = theGraph.drawOverlay()

proc qg_items() {.wexport.} =
  ## JSON of every scene item (the facade's `graph.items`).
  var arr = newArr()
  for it in theGraph.items: arr.push it
  setOutput(toJson(arr))

proc qg_items_by_ids(n: int32) {.wexport.} =
  let ids = parseArg(n)
  var arr = newArr()
  for id in ids:
    let it = theGraph.getItem(if id.isStr: id.s else: str(id))
    if it != nil: arr.push it
  setOutput(toJson(arr))

proc qg_media_items() {.wexport.} =
  ## Items that carry media (for the page's media overlay and playback).
  var arr = newArr()
  for it in theGraph.items:
    if it.tr("src") or it["mediaLayers"].isArr: arr.push it
  setOutput(toJson(arr))

proc qg_painter_sync_graph(h: int32) {.wexport.} =
  ## Syncs a standalone painter (export, outline) with the editor's scene.
  painters[h].sync(theGraph.items)

# The page encodes `undefined` members of an argument as this marker, since
# JSON cannot carry them (applyStyle({key: undefined}) deletes the key).
const UndefinedMarker = "\x01undefined"

proc decodeArgs(v: Val): Val =
  mapStrings(v, proc (s: string): Val =
    if s == UndefinedMarker: nil else: jstr(s))

proc qg_call(n: int32) {.wexport.} =
  ## Generic method call: {"m": name, "a": [args]} -> {"r": result} or
  ## {"error": message}.
  let req = parseArg(n)
  if req == nil:
    setOutput("{\"error\":\"bad request\"}")
    return
  let args = decodeArgs(req["a"])
  var value: Val = nil
  try:
    value = dispatch(theGraph, str(req["m"]), args)
  except CatchableError as e:
    let err = newObj()
    err["error"] = jstr(e.msg)
    setOutput(toJson(err))
    return
  let wrapper = newObj()
  if value != nil: wrapper["r"] = value
  setOutput(toJson(wrapper))
