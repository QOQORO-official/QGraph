# Included from editorui.nim: the Layers and Outline panels (floating cards
# on wide screens, bottom sheets on phones).

proc floatingCard(ui: EditorUi, key: string, right, top: float64): Node =
  ## A draggable floating card on the canvas that hosts a panel.
  let card = div0("qg-floatcard")
  card.setData("card", key)
  card.style("right", px(right))
  card.style("top", px(top))
  card.hidden = true
  ui.floatLayer.appendChild(card)
  # Drag by the panel header, kept inside the stage.
  var dragging = false
  var startX, startY, startLeft, startTop: float64
  card.on("pointerdown", proc(e: Event) =
    let target = e.target
    if target.closest(".qg-panel-head").isNil or not target.closest("button").isNil: return
    let r = rect(card)
    let stage = rect(ui.stage)
    dragging = true
    startX = e.clientX
    startY = e.clientY
    startLeft = r.left - stage.left
    startTop = r.top - stage.top
    card.call("setPointerCapture", e.pointerId))
  card.on("pointermove", proc(e: Event) =
    if not dragging: return
    card.style("right", "auto")
    card.style("left", px(max(0.0, startLeft + e.clientX - startX)))
    card.style("top", px(max(0.0, startTop + e.clientY - startY))))
  card.on("pointerup", proc(e: Event) = dragging = false)
  card

# ------------------------------------------------------------------ layers --

proc refreshLayers(ui: EditorUi) =
  if ui.layersBody.isNil: return
  let gv = ui.graph
  let g = gv.g
  let content = ui.layersBody
  content.dropChildren()
  # Topmost layer first, matching how the classic dialog reads.
  var layers: seq[Val]
  for layer in g.layers: layers.add layer
  for i in countdown(layers.len - 1, 0):
    let layer = layers[i]
    let id = str(layer["id"])
    let row = div0("qg-layer" & (if id == g.activeLayer: " is-active" else: ""))

    let visible = el("input", "qg-check")
    visible.typ = "checkbox"
    visible.checked = not layer["visible"].isFalse
    visible.title = "Visible"
    visible.on("change", proc(e: Event) =
      g.updateLayer(id, o1("visible", jbool(visible.checked))))

    let name = el("span", "qg-layer-name")
    var count = 0
    for item in g.items:
      if item["layer"].isStrVal(id): inc count
    name.text = valStr(layer["name"]) & " (" & $count & ")"
    name.on("click", proc(e: Event) =
      g.activeLayer = id
      ui.refreshLayers())
    let layerName = valStr(layer["name"])
    name.on("dblclick", proc(e: Event) =
      let (ok, value) = prompt("Layer name", layerName)
      if ok and value.len > 0: g.updateLayer(id, o1("name", jstr(value))))

    let locked = truthy(layer["locked"])
    let lock = iconButton(if locked: "lock" else: "unlock", if locked: "Unlock layer" else: "Lock layer")
    lock.on("click", proc(e: Event) = g.updateLayer(id, o1("locked", jbool(not locked))))

    let up = iconButton("chevronDown", "Move layer up", "qg-flip-y")
    up.on("click", proc(e: Event) = g.moveLayer(id, 1))

    let down = iconButton("chevronDown", "Move layer down")
    down.on("click", proc(e: Event) = g.moveLayer(id, -1))

    let remove = iconButton("trash", "Delete layer and its objects")
    remove.on("click", proc(e: Event) = g.removeLayer(id))

    for child in [visible, name, lock, up, down, remove]: row.appendChild(child)
    content.appendChild(row)

proc showLayers*(ui: EditorUi) =
  ui.openPanel("layers")
  ui.refreshLayers()

# ----------------------------------------------------------------- outline --

proc refreshOutline(ui: EditorUi) =
  if ui.outlineCanvas.isNil or ui.outlinePanel.getNode("parentNode").isNil: return
  let gv = ui.graph
  let g = gv.g
  let canvas = ui.outlineCanvas
  var width = canvas.getNum("clientWidth")
  if width == 0: width = 200
  var height = canvas.getNum("clientHeight")
  if height == 0: height = 140
  var dpr = window.getNum("devicePixelRatio")
  if dpr == 0 or dpr != dpr: dpr = 1
  let ratio = min(2.0, dpr)
  canvas.setProp("width", jsRound(width * ratio))
  canvas.setProp("height", jsRound(height * ratio))

  let ctx = newCtx()
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0)
  ctx.fillStyle = if g.backgroundColor.len > 0: g.backgroundColor else: "#ffffff"
  ctx.fillRect(0, 0, width, height)

  let bounds = g.getAllBounds()
  const margin = 12.0
  let scale = min((width - margin * 2) / max(1.0, bounds.width),
                  (height - margin * 2) / max(1.0, bounds.height))
  let originX = bounds.x - margin / scale
  let originY = bounds.y - margin / scale
  ui.outlineMapping = (originX, originY, scale)
  ui.hasOutlineMapping = true

  if ui.outlinePainter == nil: ui.outlinePainter = newScenePainter()
  ui.outlinePainter.sync(g.items)
  ctx.save()
  ctx.scale(scale, scale)
  ctx.translate(-originX, -originY)
  let hidden = g.hiddenLayerIds()
  var shown: seq[Val]
  for item in g.items:
    if item["visible"].isFalse or truthy(item["foldedAway"]): continue
    if not nullish(item["layer"]) and str(item["layer"]) in hidden: continue
    shown.add item
  ui.outlinePainter.drawList(shown)
  ctx.buf.add ui.outlinePainter.ctx.buf[0 ..< max(0, ui.outlinePainter.ctx.buf.len - 1)]
  ctx.restore()

  # Viewport rectangle.
  let container = gv.container
  let zoom = g.zoom
  let ox = if g.pageView: 0.0 else: g.worldOriginX
  let oy = if g.pageView: 0.0 else: g.worldOriginY
  let vx = container.getNum("scrollLeft") / zoom - ox
  let vy = container.getNum("scrollTop") / zoom - oy
  let vw = container.getNum("clientWidth") / zoom
  let vh = container.getNum("clientHeight") / zoom
  ctx.strokeStyle = "#00a8ff"
  ctx.lineWidth = 1.5
  ctx.fillStyle = "rgba(0, 168, 255, .12)"
  let r = [(vx - originX) * scale, (vy - originY) * scale, vw * scale, vh * scale]
  ctx.fillRect(r[0], r[1], r[2], r[3])
  ctx.strokeRect(r[0], r[1], r[2], r[3])
  ctx.finish()
  replay(ui.outlineContext, addr ctx.buf)

proc toggleOutline*(ui: EditorUi) =
  if ui.layout != lmPhone and not ui.outlineCard.hidden:
    ui.outlineCard.hidden = true
    return
  ui.openPanel("outline")
  ui.refreshOutline()

proc buildWindows(ui: EditorUi) =
  # Layers.
  let (layersRoot, layersContent) = panel("Layers", "layers", proc() =
    if ui.layout == lmPhone: ui.closeSheet() else: ui.layersCard.hidden = true)
  ui.layersPanel = layersRoot
  ui.layersBody = div0("qg-layer-list")
  layersContent.appendChild(ui.layersBody)
  let footer = div0("qg-button-row")
  let add = textButton("Add layer", "qg-btn qg-btn-soft", "plus")
  add.on("click", proc(e: Event) = discard ui.graph.g.addLayer(""))
  let move = textButton("Move selection here", "qg-btn qg-btn-soft", "arrange")
  move.setAttribute("title", "Move the selection to the active layer")
  move.on("click", proc(e: Event) = ui.graph.g.moveSelectionToLayer(ui.graph.g.activeLayer))
  footer.appendChild(add)
  footer.appendChild(move)
  layersContent.appendChild(footer)
  ui.graph.on("layerchange", proc(d: Val) = ui.refreshLayers())
  ui.layersCard = ui.floatingCard("layers", 16, 66)
  ui.layersCard.appendChild(layersRoot)

  # Outline.
  let (outlineRoot, outlineContent) = panel("Outline", "outline", proc() =
    if ui.layout == lmPhone: ui.closeSheet() else: ui.outlineCard.hidden = true)
  ui.outlinePanel = outlineRoot
  ui.outlineBody = outlineContent
  ui.outlineCanvas = el("canvas", "qg-outline-canvas")
  outlineContent.appendChild(ui.outlineCanvas)
  ui.outlineContext = ui.outlineCanvas.context2d()
  # Click or drag inside the thumbnail to scroll the diagram.
  proc scrollTo(e: Event) =
    let g = ui.graph.g
    let r = rect(ui.outlineCanvas)
    if not ui.hasOutlineMapping or r.width == 0: return
    let (mx, my, scale) = ui.outlineMapping
    let wx = mx + (e.clientX - r.left) / scale
    let wy = my + (e.clientY - r.top) / scale
    let ox = if g.pageView: 0.0 else: g.worldOriginX
    let oy = if g.pageView: 0.0 else: g.worldOriginY
    let container = ui.graph.container
    container.setProp("scrollLeft", (wx + ox) * g.zoom - container.getNum("clientWidth") / 2)
    container.setProp("scrollTop", (wy + oy) * g.zoom - container.getNum("clientHeight") / 2)
  var dragging = false
  ui.outlineCanvas.on("pointerdown", proc(e: Event) =
    dragging = true
    ui.outlineCanvas.call("setPointerCapture", e.pointerId)
    scrollTo(e))
  ui.outlineCanvas.on("pointermove", proc(e: Event) =
    if dragging: scrollTo(e))
  ui.outlineCanvas.on("pointerup", proc(e: Event) = dragging = false)
  ui.outlineCard = ui.floatingCard("outline", 16, 380)
  ui.outlineCard.appendChild(outlineRoot)
  var queued = false
  let redraw = proc(d: Val) =
    if queued or ui.outlineCard.hidden and not ui.sheetOpen: return
    queued = true
    requestAnimationFrame(proc(now: float64) =
      queued = false
      ui.refreshOutline())
  ui.graph.on("change", redraw)
  ui.graph.on("zoomchange", redraw)
  ui.graph.on("stats", redraw)
  ui.graph.container.on("scroll", proc(e: Event) = redraw(nil), passive = true)
