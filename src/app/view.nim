## The page side of the diagram engine (the Graph facade).
##
## The scene model, selection, handles, connectors, groups, layers, tables,
## undo history and painting live in the engine (src/graph*.nim). The view
## owns what needs the DOM: the scrolling container and its canvases,
## pointer/keyboard/drag input, the label editor, tooltips, media playback,
## stencil loading and export. It is wired to the engine through GraphHooks,
## so there is no serialisation between the two at all.

import std/[tables, strutils, math]
import ../jsval, ../host, ../geometry, ../painter, ../graph, ../canvas
import ../web/qweb
import jsutil, media, renderer, stencilxml, richhtml, data

const
  AnimationFps = 15.0
  DocumentKey* = "pixel-graph-document"

type
  Listener* = proc(data: Val)

  TextEditorDom = object
    open: bool
    element, field: Node
    range: Node
    tabbable: bool

  View* = ref object
    g*: Graph
    container*: Node
    spacer*, baseCanvas*, mediaLayer*, overlayCanvas*, overlayContext*: Node
    renderer*: Renderer
    listeners: Table[string, seq[Listener]]
    destroyed*: bool
    selectionIds*: seq[string]
    lastClient: Pt
    touches: Table[int, Pt]
    pinching: bool
    pinchMid: Pt
    pinchDist, pinchZoom: float64
    textEditor: TextEditorDom
    keepTextEditorOnBlur: bool
    tooltipElement: Node
    tooltipFor: string
    tooltipTimer: int32
    animationTimer: int32
    animationUsesFrames: bool
    dragAutoScrollTimer: int32
    scrollSettleTimer: int32
    parallaxPointerFrame: int32
    lastView*: Val
    stats*: Val
    overlaySync*: proc(view: Val)   ## the media overlay's per-frame sync
    ownOverlayCursor: string

# ------------------------------------------------------------------ events --

proc on*(v: View, name: string, listener: Listener) =
  v.listeners.mgetOrPut(name, @[]).add listener

proc emit*(v: View, name: string, data: Val = nil) =
  let list = v.listeners.getOrDefault(name, @[])
  for listener in list: listener(data)

# ------------------------------------------------------------ engine calls --

proc call*(v: View, name: string, args: varargs[Val]): Val =
  ## The engine's method table, by name (what the JS facade forwarded).
  var a = newArr()
  for x in args: a.push(if x == nil: nil else: x)
  dispatch(v.g, name, a)

proc zoom*(v: View): float64 = v.g.zoom
proc items*(v: View): seq[Val] = v.g.items
proc getSelection*(v: View): seq[Val] = v.g.getSelection()
proc snapshot*(v: View): string = v.g.snapshot()
proc commit*(v: View, before, label: string) = v.g.commit(before, label)
proc toJSON*(v: View): string = v.g.toJSON()
proc hasAction*(v: View): bool = v.g.action != nil

proc getCommonStyle*(v: View, key: string, fallback: Val): Val = v.g.getCommonStyle(key, fallback)

proc setDiagramOptions*(v: View, changes: Val) = v.g.setDiagramOptions(changes)

proc applyStyle*(v: View, changes: Val, label: string, predicate: proc(item: Val): bool = nil) =
  ## applyStyle with an optional filter over the selection.
  var allowed: Val = nil
  if predicate != nil:
    allowed = newArr()
    for item in v.g.getSelection():
      if predicate(item): allowed.push jstr(idOf(item))
  discard v.call("applyStyle", changes, jstr(label), if allowed == nil: jnull else: allowed)

proc getStyleTargetIds*(v: View, predicate: proc(item: Val): bool = nil): Val =
  var allowed: Val = jnull
  if predicate != nil:
    allowed = newArr()
    for item in v.g.getSelection():
      if predicate(item): allowed.push jstr(idOf(item))
  v.call("getStyleTargetIds", allowed)

proc updateItem*(v: View, id: string, changes: Val, label = "", record = false): Val =
  v.g.updateItem(id, changes, label, record)

proc mediaItems*(v: View): Val =
  result = newArr()
  for it in v.g.items:
    if it.tr("src") or it["mediaLayers"].isArr: result.push it

proc render*(v: View, forceRealtime = false) =
  if v.destroyed: return
  v.g.render(forceRealtime)

proc drawOverlay*(v: View) = v.g.drawOverlay()

# ------------------------------------------------------------ view metrics --

proc containerMetrics(v: View): ViewMetrics =
  let c = v.container
  var dpr = window.getNum("devicePixelRatio")
  if dpr == 0 or dpr != dpr: dpr = 1
  ViewMetrics(clientWidth: c.getNum("clientWidth"), clientHeight: c.getNum("clientHeight"),
              scrollLeft: c.getNum("scrollLeft"), scrollTop: c.getNum("scrollTop"), dpr: dpr)

proc updateCanvasPositions(v: View, view: Val) =
  # Canvases follow the physical scroll position; view.scrollX/Y are logical
  # painter offsets and may be negative on an infinite canvas.
  let left = jsStr(jsNumOr(jnum(v.container.getNum("scrollLeft")), 0)) & "px"
  let top = jsStr(jsNumOr(jnum(v.container.getNum("scrollTop")), 0)) & "px"
  let width = str(view["width"]) & "px"
  let height = str(view["height"]) & "px"
  for c in [v.baseCanvas, v.overlayCanvas]:
    c.style("left", left)
    c.style("top", top)
    c.style("width", width)
    c.style("height", height)
  let dpr = num(view["dpr"])
  let pixelWidth = max(1.0, floor(num(view["width"]) * dpr))
  let pixelHeight = max(1.0, floor(num(view["height"]) * dpr))
  if v.overlayCanvas.getNum("width") != pixelWidth: v.overlayCanvas.setProp("width", pixelWidth)
  if v.overlayCanvas.getNum("height") != pixelHeight: v.overlayCanvas.setProp("height", pixelHeight)

# --------------------------------------------------------------- animation --

proc renderAnimationFrame(v: View)

proc syncAnimation*(v: View, view0: Val = nil): bool =
  ## Animated sources only move if something keeps redrawing them, and only
  ## the page's painter holds live frames, so while one is on screen the
  ## scene repaints through the realtime path; a still diagram costs nothing.
  let view = if view0 != nil: view0 else: v.g.getViewState()
  let state = playback.visibleAnimationState(v.g.painter, view)
  v.renderer.animating = state.any
  v.renderer.parallaxAnimating = state.parallax
  if not state.any:
    if v.animationTimer != 0:
      if v.animationUsesFrames: cancelAnimationFrame(v.animationTimer)
      else: clearTimeout(v.animationTimer)
      v.animationTimer = 0
    return false
  let decoding = playback.hasGifPlayers()
  if v.animationTimer == 0:
    if state.parallax:
      v.animationUsesFrames = true
      v.animationTimer = requestAnimationFrame(proc(now: float64) =
        v.animationTimer = 0
        if v.destroyed: return
        if decoding: discard playback.tickGifs(now)
        v.renderAnimationFrame())
    elif decoding:
      v.animationUsesFrames = true
      v.animationTimer = requestAnimationFrame(proc(now: float64) =
        v.animationTimer = 0
        if v.destroyed: return
        discard playback.tickGifs(now)
        discard v.syncAnimation())
    else:
      v.animationUsesFrames = false
      v.animationTimer = setTimeout(jsRound(1000 / AnimationFps), proc() =
        v.animationTimer = 0
        if v.destroyed: return
        if not v.hasAction(): v.render(true)
        else: discard v.syncAnimation())
  true

proc renderFrame(v: View, view: Val, realtime: bool) =
  ## The engine's render(): present the scene and sync overlays. The engine
  ## redraws the interaction overlay itself.
  if v.destroyed: return
  v.lastView = view
  v.updateCanvasPositions(view)
  let animating = v.syncAnimation(view)
  v.renderer.requestFrame(view, realtime or animating)
  if v.overlaySync != nil: v.overlaySync(view)

proc renderAnimationFrame(v: View) =
  ## Scene-only frame for cursor parallax and scrolling layers.
  if v.destroyed: return
  let view = v.g.getViewState()
  v.updateCanvasPositions(view)
  discard v.syncAnimation(view)
  v.renderer.requestFrame(view, true)

proc renderScrollFrame(v: View) =
  v.render(true)
  clearTimeout(v.scrollSettleTimer)
  v.scrollSettleTimer = setTimeout(90, proc() =
    v.scrollSettleTimer = 0
    if not v.hasAction(): v.render(false))

# ----------------------------------------------------------------- tooltip --

proc showTooltip(v: View, hide: bool, id = "", text = "") =
  clearTimeout(v.tooltipTimer)
  v.tooltipTimer = 0
  if hide:
    v.tooltipFor = ""
    if not v.tooltipElement.isNil: v.tooltipElement.style("display", "none")
    return
  if not v.tooltipElement.isNil and v.tooltipFor == id: return
  let x = v.lastClient.x + 12
  let y = v.lastClient.y + 18
  v.tooltipTimer = setTimeout(500, proc() =
    v.tooltipTimer = 0
    if v.tooltipElement.isNil:
      v.tooltipElement = el("div", "qg-tooltip")
      body.appendChild(v.tooltipElement)
    v.tooltipFor = id
    v.tooltipElement.text = text
    v.tooltipElement.style("left", jsStr(x) & "px")
    v.tooltipElement.style("top", jsStr(y) & "px")
    v.tooltipElement.style("display", "block"))

proc hideTooltip*(v: View) = v.showTooltip(true)

proc getAbsoluteUrl*(href0: string): string =
  ## Resolves a relative link against the page, as the classic
  ## Graph.getAbsoluteUrl did.
  let href = jsTrim(href0)
  if href.len == 0 or href[0] == '#': return href
  var i = 0
  if href[0] in {'a'..'z', 'A'..'Z'}:
    inc i
    while i < href.len and href[i] in {'a'..'z', 'A'..'Z', '0'..'9', '+', '.', '-'}: inc i
    if i < href.len and href[i] == ':': return href
  let u = construct("URL", href, location.getStr("href"))
  if u.isNil: return href
  result = u.getStr("href")
  release(u)

# ------------------------------------------------------------- label editor --

proc prepareRichEditorStyles(field: Node) =
  ## Browser headings scale differently from the rich text model, and an
  ## absolute font size on a run would bypass the heading scale: scale those
  ## runs while editing and restore the logical sizes afterwards.
  for span in field.queryAll("span[style*=\"font-size\"]"):
    let value = jsParseFloat(span.get2("style", "fontSize").toStr)
    if not isFiniteJs(value): continue
    let blk = span.closest("h1,h2,h3")
    var scale = 1.0
    if not blk.isNil:
      case blk.getStr("tagName")
      of "H1": scale = 1.7
      of "H2": scale = 1.4
      of "H3": scale = 1.2
      else: discard
    span.setData("pixelLogicalFontSize", jsStr(value))
    span.style("fontSize", jsStr(value * scale) & "px")

proc restoreRichEditorStyles(field: Node) =
  for sized in field.queryAll("[data-pixel-logical-font-size]"):
    sized.style("fontSize", sized.get2("dataset", "pixelLogicalFontSize").toStr & "px")
    sized.deleteData("pixelLogicalFontSize")

proc finishTextEdit*(v: View, commit = true) =
  if v.destroyed: return
  v.g.finishTextEdit(commit)

proc captureTextSelection*(v: View) =
  if not v.textEditor.open: return
  let selection = document.invoke("getSelection").toNode
  if selection.isNil or selection.getNum("rangeCount") < 1:
    if same(activeElement(), v.textEditor.field): v.textEditor.range = nilNode
    return
  let range = selection.invoke("getRangeAt", 0).toNode
  if range.isNil or range.getBool("collapsed"):
    if same(activeElement(), v.textEditor.field): v.textEditor.range = nilNode
    return
  if not v.textEditor.field.contains(range.getNode("startContainer")) or
      not v.textEditor.field.contains(range.getNode("endContainer")):
    if same(activeElement(), v.textEditor.field): v.textEditor.range = nilNode
    return
  v.textEditor.range = range.invoke("cloneRange").toNode

proc hasSelectedTextRange*(v: View): bool =
  v.textEditor.open and not v.textEditor.range.isNil

proc retainTextEditorForInspector*(v: View) =
  if not v.textEditor.open: return
  v.captureTextSelection()
  v.keepTextEditorOnBlur = v.hasSelectedTextRange()

proc execSelectedTextStyle*(v: View, command: string, value = "", hasValue = false): bool =
  ## Apply an inspector control to the selected words in the open label.
  if not v.hasSelectedTextRange(): return false
  let saved = v.textEditor.range
  v.textEditor.field.focus(preventScroll = true)
  let selection = document.invoke("getSelection").toNode
  if selection.isNil: return false
  selection.call("removeAllRanges")
  selection.call("addRange", saved)
  if command in ["foreColor", "fontName", "fontSizePx", "bold", "italic", "underline", "strikeThrough"]:
    # execCommand rewrites an earlier <font color> wrapper when Bold follows
    # Color in Chromium. Wrap just the saved range instead, then reselect it
    # so another inspector control can format the same words.
    let active = if command in ["bold", "italic", "underline", "strikeThrough"]:
      document.invoke("queryCommandState", command).toBool else: false
    let wrapper = createElement("span")
    case command
    of "foreColor": wrapper.style("color", value)
    of "fontName": wrapper.style("fontFamily", value)
    of "fontSizePx": wrapper.style("fontSize", value & "px")
    of "bold": wrapper.style("fontWeight", if active: "normal" else: "bold")
    of "italic": wrapper.style("fontStyle", if active: "normal" else: "italic")
    of "underline": wrapper.style("textDecoration", if active: "none" else: "underline")
    of "strikeThrough": wrapper.style("textDecoration", if active: "none" else: "line-through")
    else: discard
    let fragment = saved.invoke("extractContents").toNode
    if fragment.isNil: return false
    wrapper.appendChild(fragment)
    saved.call("insertNode", wrapper)
    saved.call("selectNodeContents", wrapper)
    selection.call("removeAllRanges")
    selection.call("addRange", saved)
    result = true
  else:
    result = execCommand(command, value, hasValue)
  v.captureTextSelection()

proc openTextEditor(v: View, d: Val) =
  let editor = el("div", "pixel-text-editor")
  # A child of the scrolling world, so DOM-world coordinates.
  editor.style("left", str(d["left"]) & "px")
  editor.style("top", str(d["top"]) & "px")
  editor.style("width", str(d["width"]) & "px")
  editor.style("height", str(d["height"]) & "px")
  # The box grows with the text instead of scrolling it.
  editor.style("minHeight", str(d["height"]) & "px")
  editor.style("height", "auto")
  editor.style("alignItems", strOrEmpty(d["alignItems"]))

  let field = el("div", "pixel-text-input")
  field.setAttribute("contenteditable", "true")
  field.setAttribute("spellcheck", "false")
  if not nullish(d["html"]):
    field.html = str(d["html"])
    prepareRichEditorStyles(field)
  else:
    field.text = strOrEmpty(d["text"])
  # Explicit sizes matter: .geDiagramContainer sets font-size to 0.
  field.style("fontFamily", strOrEmpty(d["fontFamily"]))
  field.style("fontSize", str(d["fontSize"]) & "px")
  field.style("fontWeight", strOrEmpty(d["fontWeight"]))
  field.style("fontStyle", strOrEmpty(d["fontStyle"]))
  field.style("color", strOrEmpty(d["color"]))
  field.style("textAlign", strOrEmpty(d["textAlign"]))
  field.style("lineHeight", "1.28")
  field.style("width", str(d["fieldWidth"]) & "px")
  field.style("paddingLeft", str(d["padding"]) & "px")
  field.style("paddingRight", str(d["padding"]) & "px")
  field.style("zoom", strOrEmpty(d["zoom"]))
  field.style("textDecoration", strOrEmpty(d["textDecoration"]))
  if truthy(d["transform"]):
    editor.style("transformOrigin", strOrEmpty(d["transformOrigin"]))
    editor.style("transform", strOrEmpty(d["transform"]))
  editor.appendChild(field)
  v.container.appendChild(editor)
  v.textEditor = TextEditorDom(open: true, element: editor, field: field, tabbable: d["tabbable"].isTrue)

  field.focus(preventScroll = true)
  selectContents(field)
  v.captureTextSelection()

  field.on("keydown", proc(e: Event) =
    let key = e.key
    if (e.ctrlKey or e.metaKey) and key == "Enter": v.finishTextEdit(true)
    elif key == "Escape": v.finishTextEdit(false)
    elif key == "Tab" and v.textEditor.open and v.textEditor.tabbable:
      # Tab walks to the next cell, as in a spreadsheet.
      e.preventDefault()
      v.g.textEditorTab(e.shiftKey)
      return
    e.stopPropagation())
  field.on("pointerdown", proc(e: Event) = e.stopPropagation())
  field.on("keyup", proc(e: Event) = v.captureTextSelection())
  field.on("mouseup", proc(e: Event) = v.captureTextSelection())
  field.on("blur", proc(e: Event) =
    if v.keepTextEditorOnBlur:
      v.keepTextEditorOnBlur = false
      return
    let next = e.relatedTarget
    if not next.isNil and not next.closest(".qg-panel-inspector").isNil:
      v.captureTextSelection()
      return
    v.finishTextEdit(true))
  v.emit("texteditstart")

proc closeTextEditor(v: View): (string, Val) =
  ## The engine is committing or cancelling: hand it the field's text and
  ## parsed rich model, and take the editor down.
  let data = v.textEditor
  v.textEditor = TextEditorDom()
  if not data.open: return ("", nil)
  var plain = innerText(data.field)
  plain = plain.replace("\r\n", "\n").replace("\r", "\n").replace("\xC2\xA0", " ")
  var e = plain.len
  while e > 0 and plain[e - 1] == '\n': dec e
  plain.setLen(e)
  # Undo the temporary heading scaling before the HTML bridge turns inline
  # sizes back into logical run sizes.
  restoreRichEditorStyles(data.field)
  let model = htmlToRich(data.field.getStr("innerHTML"))
  data.element.dropTree()
  (plain, model)

proc isEditingText*(v: View): bool = v.textEditor.open

proc execTextCommand*(v: View, command: string, value = "", hasValue = false): bool =
  ## Runs a browser editing command inside the open label.
  if not v.textEditor.open: return false
  if v.hasSelectedTextRange(): return v.execSelectedTextStyle(command, value, hasValue)
  v.textEditor.field.focus(preventScroll = true)
  execCommand(command, value, hasValue)

# ------------------------------------------------------------------- input --

proc screenPoint(v: View, e: Event): Pt =
  let r = rect(v.overlayCanvas)
  pt(e.clientX - r.left, e.clientY - r.top)

proc pointerEv(v: View, e: Event): PointerEv =
  let flags = e.modifiers
  PointerEv(screen: v.screenPoint(e), button: int32(e.button), shift: (flags and 1) != 0,
            ctrl: (flags and 2) != 0, meta: (flags and 4) != 0, alt: (flags and 8) != 0,
            touch: (flags and 16) != 0)

proc setZoom*(v: View, value: float64, screen: Val = nil) =
  discard v.call("setZoom", jnum(value), if screen == nil: jnull else: screen)

proc isShapeDrag(e: Event): bool =
  let dt = e.dataTransfer
  if dt.isNil: return false
  let types = dt.getNode("types")
  if types.isNil: return false
  result = types.invoke("includes", "application/x-pixel-shape").toBool or
    types.invoke("includes", "application/x-pixel-shape-data").toBool
  release(types)

proc clearReplaceTarget(v: View) =
  if v.destroyed: return
  v.g.clearReplaceTarget()

proc insertMedia*(v: View, src, name: string, point: Val = nil, mediaType = ""): Val =
  if src.len == 0: return nil
  let kind = if mediaType.len > 0: mediaType else: mediaTypeFor(src, "")
  v.call("insertMedia", jstr(src), jstr(name), if point == nil: jnull else: point, jstr(kind))

proc drop(v: View, e: Event) =
  e.preventDefault()
  let screen = v.screenPoint(e)
  let dt = e.dataTransfer
  let files = dt.getNode("files")
  if not files.isNil and files.getNum("length") > 0:
    let file = files.invoke("item", 0).toNode
    if file.getStr("type").startsWith("image/"):
      v.clearReplaceTarget()
      let world = v.g.eventWorld(screen)
      let name = file.getStr("name")
      readBlob(file, brDataUrl, proc(ok: bool, text: string) =
        release(file)
        let point = newObj()
        point["x"] = jnum(world.x - 90)
        point["y"] = jnum(world.y - 60)
        discard v.insertMedia(text, name, point, "image"))
      return
  # A saved multi-shape block: the shell inserts it (ids remapped, grouped).
  let blockJson = dt.invoke("getData", "application/x-qgraph-block").toStr
  if blockJson.len > 0:
    v.clearReplaceTarget()
    let world = v.g.eventWorld(screen)
    let payload = newObj()
    payload["json"] = jstr(blockJson)
    payload["x"] = jnum(world.x)
    payload["y"] = jnum(world.y)
    v.emit("dropblock", payload)
    return
  # Scratchpad entries carry their whole definition on the drag.
  let literal = dt.invoke("getData", "application/x-pixel-shape-data").toStr
  var kind = dt.invoke("getData", "application/x-pixel-shape").toStr
  if kind.len == 0: kind = "process"
  var shapeData: Val = nil
  if literal.len > 0:
    try: shapeData = parseJson(literal)
    except JsonError: shapeData = nil
  else:
    shapeData = nodeTemplate(kind)
    if shapeData == nil: shapeData = nodeTemplate("process")
  if shapeData == nil: shapeData = newObj()
  discard v.g.drop(screen, shapeData)

proc setParallaxPointer*(v: View, x, y: float64): bool =
  if not v.g.painter.hasLayeredItems: return false
  v.renderer.setParallaxTarget(x, y)
  if v.parallaxPointerFrame == 0:
    v.parallaxPointerFrame = requestAnimationFrame(proc(now: float64) =
      v.parallaxPointerFrame = 0
      if not v.destroyed: v.render(true))
  true

proc installEvents(v: View) =
  v.container.on("scroll", proc(e: Event) = v.renderScrollFrame(), passive = true)
  window.on("pointermove", proc(e: Event) =
    if not v.g.painter.hasLayeredItems: return
    if e.pointerType == "touch" or not e.isPrimary: return
    let r = rect(v.overlayCanvas)
    if r.width == 0 or r.height == 0: return
    let x = ((e.clientX - r.left) / r.width - 0.5) * 2
    let y = ((e.clientY - r.top) / r.height - 0.5) * 2
    discard v.setParallaxPointer(clamp(x, -1, 1), clamp(y, -1, 1)), capture = true, passive = true)
  # Touch: one finger drives the engine (select, move, or pan on empty
  # canvas); a second finger switches to pinch-zoom and two-finger pan until
  # every finger has lifted.
  proc touchPoint(e: Event): Pt =
    let r = rect(v.container)
    pt(e.clientX - r.left, e.clientY - r.top)
  proc pinchFrame(): (Pt, float64) =
    var a, b: Pt
    var i = 0
    for p in v.touches.values:
      if i == 0: a = p else: b = p
      inc i
    (pt((a.x + b.x) / 2, (a.y + b.y) / 2), max(1.0, hypot(a.x - b.x, a.y - b.y)))
  v.overlayCanvas.on("pointerdown", proc(e: Event) =
    if e.pointerType == "touch":
      v.touches[int(e.pointerId)] = touchPoint(e)
      if v.touches.len >= 2:
        if not v.pinching:
          # Hand the first finger's gesture back to the engine, finished.
          discard v.g.pointerUp(PointerEv(screen: v.screenPoint(e), touch: true))
          v.pinching = true
          let (mid, dist) = pinchFrame()
          v.pinchMid = mid
          v.pinchDist = dist
          v.pinchZoom = v.g.zoom
        v.overlayCanvas.call("setPointerCapture", e.pointerId)
        e.preventDefault()
        return
    if v.pinching: return
    v.container.focus(preventScroll = true)
    v.lastClient = pt(e.clientX, e.clientY)
    let flags = v.g.pointerDown(v.pointerEv(e))
    if (flags and FlagCapture) != 0:
      v.overlayCanvas.call("setPointerCapture", e.pointerId)
    if (flags and FlagPrevent) != 0: e.preventDefault())
  v.overlayCanvas.on("pointermove", proc(e: Event) =
    if e.pointerType == "touch" and v.touches.hasKey(int(e.pointerId)):
      v.touches[int(e.pointerId)] = touchPoint(e)
    if v.pinching:
      if v.touches.len >= 2:
        let (mid, dist) = pinchFrame()
        let screen = newObj()
        screen["x"] = jnum(mid.x)
        screen["y"] = jnum(mid.y)
        v.setZoom(v.pinchZoom * dist / v.pinchDist, screen)
        v.container.setProp("scrollLeft", v.container.getNum("scrollLeft") - (mid.x - v.pinchMid.x))
        v.container.setProp("scrollTop", v.container.getNum("scrollTop") - (mid.y - v.pinchMid.y))
        v.pinchMid = mid
      e.preventDefault()
      return
    v.lastClient = pt(e.clientX, e.clientY)
    let flags = v.g.pointerMove(v.pointerEv(e))
    if (flags and FlagPrevent) != 0: e.preventDefault())
  v.overlayCanvas.on("pointerleave", proc(e: Event) =
    if not v.pinching: v.g.pointerLeave())
  for kind in ["pointerup", "pointercancel"]:
    v.overlayCanvas.on(kind, proc(e: Event) =
      if e.pointerType == "touch": v.touches.del(int(e.pointerId))
      if v.pinching:
        if v.touches.len == 0:
          v.pinching = false
          v.render()
        return
      let flags = v.g.pointerUp(v.pointerEv(e))
      if (flags and FlagRelease) != 0:
        v.overlayCanvas.call("releasePointerCapture", e.pointerId)
      if (flags and FlagPrevent) != 0: e.preventDefault())
  v.overlayCanvas.on("dblclick", proc(e: Event) =
    if v.g.interactionLocked:
      e.preventDefault()
      return
    let flags = v.g.doubleClick(v.pointerEv(e))
    if (flags and FlagPrevent) != 0: e.preventDefault())
  v.overlayCanvas.on("contextmenu", proc(e: Event) =
    var ev = v.pointerEv(e)
    ev.button = 2
    let found = v.g.contextMenu(ev)
    let payload = newObj()
    payload["clientX"] = jnum(e.clientX)
    payload["clientY"] = jnum(e.clientY)
    payload["item"] = if found != nil and truthy(found["item"]): found["item"] else: jnull
    payload["point"] = if found != nil: found["point"] else: jnull
    v.emit("contextmenu", payload)
    e.preventDefault())
  v.container.on("wheel", proc(e: Event) =
    if e.ctrlKey or e.metaKey or e.altKey:
      let r = rect(v.container)
      let screen = newObj()
      screen["x"] = jnum(e.clientX - r.left)
      screen["y"] = jnum(e.clientY - r.top)
      v.setZoom(v.g.zoom * (if e.deltaY < 0: 1.12 else: 1 / 1.12), screen)
      e.preventDefault(), passive = false)
  v.container.on("dragover", proc(e: Event) =
    e.preventDefault()
    v.g.dragOver(v.screenPoint(e), isShapeDrag(e)))
  v.container.on("dragleave", proc(e: Event) =
    # Crossing between the canvas and its own children also fires this.
    let related = e.relatedTarget
    if not related.isNil and v.container.contains(related): return
    v.clearReplaceTarget())
  v.container.on("drop", proc(e: Event) = v.drop(e))
  window.on("dragend", proc(e: Event) = v.clearReplaceTarget())
  v.container.on("keydown", proc(e: Event) =
    let flags = v.g.keyDown(e.key, e.code, e.shiftKey, e.ctrlKey, e.metaKey, e.altKey)
    if (flags and FlagPrevent) != 0: e.preventDefault())
  v.container.on("keyup", proc(e: Event) = v.g.keyUp(e.code))

# ------------------------------------------------------------------- hooks --

proc installHooks(v: View) =
  viewMetricsHook = proc(): ViewMetrics = v.containerMetrics()
  setScrollHook = proc(left, top: float64) =
    if left == left: v.container.setProp("scrollLeft", left)
    if top == top: v.container.setProp("scrollTop", top)
  var h: GraphHooks
  h.emit = proc(name: string, data: Val) =
    if name == "selectionchange":
      v.selectionIds.setLen(0)
      for item in data: v.selectionIds.add idOf(item)
    v.emit(name, data)
  h.render = proc(view: Val, realtime: bool) = v.renderFrame(view, realtime)
  h.spacer = proc(width, height: float64) =
    v.spacer.style("width", jsStr(width) & "px")
    v.spacer.style("height", jsStr(height) & "px")
  h.rendererSync = proc(mediaItems: Val) = v.renderer.sync(mediaItems)
  h.rendererUpsert = proc(ids: seq[string], deferWorker: bool, mediaItems: Val) =
    v.renderer.upsert(ids, deferWorker, mediaItems)
  h.rendererRemove = proc(ids: seq[string]) = v.renderer.remove(ids, v.mediaItems())
  h.overlay = proc(ctx: Ctx) = replay(v.overlayContext, addr ctx.buf)
  h.cursor = proc(cursor: string) = v.overlayCanvas.style("cursor", cursor)
  h.tooltip = proc(show: bool, id, text: string) = v.showTooltip(not show, id, text)
  h.timer = proc(name: string, ms: float64, cancel: bool) =
    if name != "autoscroll": return
    clearTimeout(v.dragAutoScrollTimer)
    v.dragAutoScrollTimer = 0
    if cancel: return
    v.dragAutoScrollTimer = setTimeout(if ms > 0: ms else: 30, proc() =
      v.dragAutoScrollTimer = 0
      if not v.destroyed: v.g.dragAutoScrollTick())
  h.openLink = proc(href: string) =
    window.call("open", getAbsoluteUrl(href), "_blank", "noopener,noreferrer")
  h.textEditorOpen = proc(d: Val) = v.openTextEditor(d)
  h.textEditorClose = proc(): (string, Val) = v.closeTextEditor()
  v.g.hooks = h

# ----------------------------------------------------------------- surface --

proc itemsJson(v: View, ids: seq[string], all: bool): string =
  var arr = newArr()
  if all:
    for it in v.g.items: arr.push it
  else:
    for id in ids:
      let it = v.g.getItem(id)
      if it != nil: arr.push it
  toJson(arr)

proc createSurface(v: View) =
  let c = v.container
  c.html = ""
  c.addClass("pixel-diagram-container")
  c.setAttribute("tabindex", "0")
  v.spacer = el("div", "pixel-world-spacer")
  c.appendChild(v.spacer)
  v.baseCanvas = el("canvas", "pixel-base-canvas")
  v.baseCanvas.setAttribute("aria-label", "Pixel diagram")
  c.appendChild(v.baseCanvas)
  v.mediaLayer = el("div", "pixel-media-layer")
  c.appendChild(v.mediaLayer)
  v.overlayCanvas = el("canvas", "pixel-overlay-canvas")
  v.overlayCanvas.setAttribute("aria-label", "Diagram interactions")
  c.appendChild(v.overlayCanvas)
  v.overlayContext = v.overlayCanvas.context2d(alpha = true, desynchronized = true)
  v.renderer = newRenderer(v.baseCanvas, v.g.painter)
  v.renderer.itemsJson = proc(ids: seq[string], all: bool): string = v.itemsJson(ids, all)
  v.renderer.onStats = proc(stats: Val) =
    v.stats = stats
    v.emit("stats", stats)

proc newView*(container: Node, mobileMode = false): View =
  installMediaHook()
  installRichHtml()
  let v = View(container: container, g: newGraph(mobileMode))
  v.installHooks()
  v.createSurface()
  # A decoded image or frame arrives after the frame that asked for it.
  playback.onImageLoad = proc(src: string) = v.render(false)
  playback.onGifFrame = proc(src: string) = v.render(true)
  playback.onVideoFrame = proc(src: string) =
    if not v.hasAction(): v.render(true)
  v.installEvents()
  let observer = construct("ResizeObserver", callback(proc(e: Event) =
    v.g.updateWorldSize()
    v.render()))
  if not observer.isNil: observer.call("observe", container)
  else:
    window.on("resize", proc(e: Event) =
      v.g.updateWorldSize()
      v.render())
  v.g.start()
  v

# --------------------------------------------------------- stencils, export --

proc loadStencils*(v: View, urls: openArray[string], done: proc() = nil) =
  ## Fetches and registers stencil libraries, then hands the parsed draw
  ## programs to the renderer so the worker can paint them as well.
  var remaining = urls.len
  var added = 0
  if remaining == 0:
    if done != nil: done()
    return
  for url in urls:
    var name = url
    let slash = name.rfind('/')
    if slash >= 0: name = name[slash + 1 .. ^1]
    if name.toLowerAscii().endsWith(".xml"): name.setLen(name.len - 4)
    let libraryName = "mxgraph." & name
    fetchBytes(url, proc(ok: bool, text: string) =
      if ok:
        try: added += parseLibrary(text, libraryName).len
        except CatchableError: discard
      dec remaining
      if remaining == 0:
        if added > 0:
          v.renderer.sendStencils(allPrograms())
          v.render()
          v.emit("stencilsloaded")
        if done != nil: done())

proc renderToCanvas*(v: View, scale0 = 1.0, margin = 20.0): Node =
  ## Paints the whole scene into a detached canvas, for export and print.
  let scale = if scale0 == 0: 1.0 else: scale0
  let bounds = v.g.getAllBounds()
  let p = newScenePainter()
  p.sync(v.g.items)
  let canvas = createElement("canvas")
  var surface = newSurface(canvas)
  let view = newObj()
  view["zoom"] = jnum(scale)
  view["dpr"] = jnum(1)
  view["width"] = jnum(ceil((bounds.width + margin * 2) * scale))
  view["height"] = jnum(ceil((bounds.height + margin * 2) * scale))
  view["scrollX"] = jnum((bounds.x - margin) * scale)
  view["scrollY"] = jnum((bounds.y - margin) * scale)
  view["background"] = jstr(if v.g.backgroundColor.len > 0: v.g.backgroundColor else: "#ffffff")
  view["grid"] = jfalse
  view["pageView"] = jfalse
  discard p.paint(surface, view)
  release(surface.ctx)
  canvas

proc print*(v: View) =
  let canvas = v.renderToCanvas(2)
  let win = window.invoke("open", "", "_blank").toNode
  if win.isNil:
    v.emit("toast", jstr("Allow pop-ups to print this diagram"))
    return
  let doc = win.getNode("document")
  doc.call("write", "<!DOCTYPE html><title>Diagram</title>" &
    "<style>@page{margin:12mm}body{margin:0}img{width:100%}</style>" &
    "<img onload=\"window.focus();window.print()\" src=\"" &
    canvas.invoke("toDataURL", "image/png").toStr & "\">")
  doc.call("close")
  release(doc)
  release(win)

proc downloadBlob*(blob: Node, filename: string) =
  let link = createElement("a")
  let url = createObjectURL(blob)
  link.setProp("href", url)
  link.setProp("download", filename)
  link.click()
  setTimeout(1000, proc() =
    revokeObjectURL(url)
    release(link))

proc exportPng*(v: View, filename = "pixel-diagram.png") =
  ## Exports the whole diagram at 2x, not just the visible viewport.
  let canvas = v.renderToCanvas(2)
  canvasBlob(canvas, "image/png", proc(ok: bool, blob: Node) =
    release(canvas)
    if not ok or blob.isNil: return
    downloadBlob(blob, filename)
    release(blob))

proc fromJSON*(v: View, doc: Val) = discard v.call("fromJSON", doc)

proc saveLocal*(v: View) =
  discard storageSet(DocumentKey, v.g.toJSON())
  v.emit("toast", jstr("Saved in this browser"))

proc loadLocal*(v: View) =
  let (found, text) = storageGet(DocumentKey)
  if found and text.len > 0:
    try: v.fromJSON(parseJson(text))
    except JsonError: v.emit("toast", jstr("No saved diagram found"))
  else: v.emit("toast", jstr("No saved diagram found"))
