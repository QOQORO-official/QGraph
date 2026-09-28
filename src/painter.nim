## Retained scene painter (PixelScenePainter).
##
## Owns a copy of the scene (id -> item, spatial index, connector adjacency),
## culls to the viewport and paints every visible object into a Canvas2D
## command list. The same code runs for the main-thread realtime painter,
## the render worker, the outline window and exports.

import std/[tables, sets, math, algorithm, strutils]
import jsval, geometry, spatial, canvas, richtext, stencils, host

type
  ScenePainter* = ref object
    items*: Scene
    index*: SpatialGrid
    edgesByNode: Table[string, HashSet[string]]
    layeredIds: HashSet[string]
    hasLayeredItems*: bool
    ctx*: Ctx

  RenderStats* = object
    visible*, total*: int
    pixelWidth*, pixelHeight*: int

proc newScenePainter*(): ScenePainter =
  ScenePainter(items: initTable[string, Val](), index: initSpatialGrid(256), ctx: newCtx())

# --------------------------------------------------------- media nodes --
# Pictures, GIFs and video are decoded and sampled on the page; the painter
# emits one media op carrying the fields drawImageNode needs. Sources can be
# multi-megabyte data URIs, so they are interned once per string object.

var srcCache = initTable[int, (Val, int32)]()

proc srcId(v: Val): float64 =
  if v == nil or v.kind != vStr: return -1
  let key = cast[int](v)
  if srcCache.hasKey(key):
    let (held, id) = srcCache[key]
    if held == v: return float64(id)
  if srcCache.len > 4096: srcCache.clear()
  let id = strId(v.s)
  srcCache[key] = (v, id)
  float64(id)

var mediaHook*: proc(ctx: Ctx, node: Val)
  ## Draws an image/video node's picture (installed by the application);
  ## without it the node is handed to the page as a media op.

proc mediaJson(node: Val): string =
  let o = newObj()
  for k in ["x", "y", "width", "height"]:
    o.put(k, node.get(k))
  o["src"] = jnum(srcId(node["src"]))
  for k in ["mediaType", "mediaLoop", "imageFit", "imageOpacity", "imageAlign",
            "imageVerticalAlign"]:
    let v = node.get(k)
    if v != nil: o.put(k, v)
  let layers = node["mediaLayers"]
  if layers.isArr and layers.len > 0:
    let outArr = newArr()
    for layer in layers:
      if not layer.isObj:
        outArr.push jnull
        continue
      let l = newObj()
      l["src"] = jnum(srcId(layer["src"]))
      for k in ["mediaType", "depth", "opacity", "scrollX", "scrollY"]:
        let v = layer.get(k)
        if v != nil: l.put(k, v)
      outArr.push l
    o["mediaLayers"] = outArr
  toJson(o)

# ------------------------------------------------------------ scene sync --

proc hasLayers(item: Val): bool =
  let l = item["mediaLayers"]
  l.isArr and l.len > 0

proc registerEdge(p: ScenePainter, edge: Val) =
  let id = idOf(edge)
  for k in ["sourceId", "targetId"]:
    let ref0 = edge.get(k)
    if not truthy(ref0): continue
    let key = str(ref0)
    p.edgesByNode.mgetOrPut(key, initHashSet[string]()).incl id

proc unregisterEdge(p: ScenePainter, edge: Val) =
  let id = idOf(edge)
  for k in ["sourceId", "targetId"]:
    let ref0 = edge.get(k)
    let key = if nullish(ref0): "" else: str(ref0)
    if p.edgesByNode.hasKey(key):
      p.edgesByNode[key].excl id
      if p.edgesByNode[key].len == 0: p.edgesByNode.del(key)

proc reindexAll(p: ScenePainter) =
  p.index.clear()
  for id, item in p.items:
    p.index.update(id, itemBounds(item, p.items))

proc sync*(p: ScenePainter, items: openArray[Val]) =
  p.items.clear()
  p.index.clear()
  p.edgesByNode.clear()
  p.layeredIds.clear()
  for it in items:
    p.items[idOf(it)] = it
    if hasLayers(it): p.layeredIds.incl idOf(it)
  p.hasLayeredItems = p.layeredIds.len > 0
  for it in items:
    if it.eqs("type", "edge"): p.registerEdge(it)
  p.reindexAll()

proc upsert*(p: ScenePainter, items: openArray[Val]) =
  var changedNodes: seq[string]
  for it in items:
    let id = idOf(it)
    let existing = p.items.getOrDefault(id, nil)
    if existing != nil and existing.eqs("type", "edge") and existing != it:
      p.unregisterEdge(existing)
    p.items[id] = it
    if hasLayers(it): p.layeredIds.incl id
    else: p.layeredIds.excl id
    if not it.eqs("type", "edge"): changedNodes.add id
    elif existing == nil or existing != it: p.registerEdge(it)
  for it in items:
    p.index.update(idOf(it), itemBounds(it, p.items))
  p.hasLayeredItems = p.layeredIds.len > 0
  for nodeId in changedNodes:
    if p.edgesByNode.hasKey(nodeId):
      for edgeId in p.edgesByNode[nodeId]:
        let edge = p.items.getOrDefault(edgeId, nil)
        if edge != nil: p.index.update(edgeId, itemBounds(edge, p.items))

proc remove*(p: ScenePainter, ids: openArray[string]) =
  for id in ids:
    let item = p.items.getOrDefault(id, nil)
    p.layeredIds.excl id
    if item != nil and item.eqs("type", "edge"): p.unregisterEdge(item)
    p.items.del(id)
    p.index.remove(id)
  p.hasLayeredItems = p.layeredIds.len > 0

proc worldBounds(view: Val): Rect =
  let overscan = if view.nul("overscan"): 100.0 else: max(12.0, view.nm("overscan"))
  let zoom = view.nm("zoom")
  rect(view.nm("scrollX") / zoom - overscan / zoom,
       view.nm("scrollY") / zoom - overscan / zoom,
       view.nm("width") / zoom + overscan * 2 / zoom,
       view.nm("height") / zoom + overscan * 2 / zoom)

proc compareZ(a, b: Val): int =
  let za = a.fo("z", 0)
  let zb = b.fo("z", 0)
  if za != zb: return (if za - zb < 0: -1 else: 1)
  let ta = a.eqs("type", "edge")
  let tb = b.eqs("type", "edge")
  if not strictEq(a["type"], b["type"]): return (if ta: 1 else: -1)
  jsCompareStr(idOf(a), idOf(b))

proc getVisibleItems*(p: ScenePainter, view: Val): seq[Val] =
  let wb = worldBounds(view)
  let ids = p.index.query(wb)
  let hidden = view["hiddenLayers"]
  for id in ids:
    let item = p.items.getOrDefault(id, nil)
    if item == nil: continue
    if item["visible"].isFalse or item.tr("foldedAway"): continue
    let layer = item["layer"]
    if not nullish(layer) and hidden.isArr:
      var isHidden = false
      for h in hidden:
        if strictEq(h, layer):
          isHidden = true
          break
      if isHidden: continue
    if intersects(itemBounds(item, p.items), wb): result.add item
  result.sort(compareZ)

# ------------------------------------------------------------- helpers --

proc orV(v: Val, d: Val): Val {.inline.} = (if truthy(v): v else: d)

proc dashPattern(item: Val): seq[float64] =
  let d = item["dashPattern"]
  if d.isArr and d.len > 0:
    for x in d: result.add num(x)
  else: result = @[6.0, 4.0]

proc roundedRect(ctx: Ctx, x, y, width, height, radius: float64) =
  let r = jsMax(0, jsMin(if truthy(jnum(radius)): radius else: 0.0, width / 2, height / 2))
  ctx.beginPath()
  ctx.moveTo(x + r, y)
  ctx.lineTo(x + width - r, y)
  ctx.quadraticCurveTo(x + width, y, x + width, y + r)
  ctx.lineTo(x + width, y + height - r)
  ctx.quadraticCurveTo(x + width, y + height, x + width - r, y + height)
  ctx.lineTo(x + r, y + height)
  ctx.quadraticCurveTo(x, y + height, x, y + height - r)
  ctx.lineTo(x, y + r)
  ctx.quadraticCurveTo(x, y, x + r, y)
  ctx.closePath()

proc polygon(ctx: Ctx, points: openArray[Pt]) =
  ctx.beginPath()
  ctx.moveTo(points[0].x, points[0].y)
  for i in 1 ..< points.len: ctx.lineTo(points[i].x, points[i].y)
  ctx.closePath()

proc wrapText(ctx: Ctx, text: string, maxWidth: float64): seq[string] =
  for paragraph in text.split('\n'):
    let words = splitSpaces(paragraph)
    var line = ""
    for w in words:
      let test = if line.len > 0: line & " " & w else: w
      if line.len > 0 and ctx.measureText(test) > maxWidth:
        result.add line
        line = w
      else:
        line = test
    result.add line


proc applyNodeFill(ctx: Ctx, node: Val, fill: string) =
  ## Solid fill unless the node carries a gradient colour and direction.
  if not node.tr("gradient") or not node.tr("gradientDirection"):
    ctx.fillStyle = fill
    return
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  let dir = str(node["gradientDirection"])
  var g: Gradient
  if dir == "radial":
    g = ctx.createRadialGradient(x + w / 2, y + h / 2, jsMin(w, h) / 10,
                                 x + w / 2, y + h / 2, jsMax(w, h) / 1.5)
  elif dir == "horizontal": g = ctx.createLinearGradient(x, y, x + w, y)
  elif dir == "diagonal": g = ctx.createLinearGradient(x, y, x + w, y + h)
  else: g = ctx.createLinearGradient(x, y, x, y + h)
  g.addColorStop(0, fill)
  g.addColorStop(1, str(node["gradient"]))
  ctx.setFillGradient(g)

# --------------------------------------------------------------- grid --

proc drawGrid*(p: ScenePainter, ctx: Ctx, view: Val) =
  let zoom = view.nm("zoom")
  let minor = max(2.0, view.fo("gridSize", 10))
  let major = minor * 10
  let left = view.nm("scrollX") / zoom
  let top = view.nm("scrollY") / zoom
  let right = left + view.nm("width") / zoom
  let bottom = top + view.nm("height") / zoom

  ctx.save()
  if view.tr("pageView"):
    let columns = max(1.0, view.nor("pageColumns", 1))
    let rows = max(1.0, view.nor("pageRows", 1))
    let pageWidth = view.fo("pageWidth", 827)
    let pageHeight = view.fo("pageHeight", 1169)
    let pageStartX = view.fo("pageStartColumn", 0) * pageWidth
    let pageStartY = view.fo("pageStartRow", 0) * pageHeight
    ctx.beginPath()
    ctx.rect(pageStartX, pageStartY, pageWidth * columns, pageHeight * rows)
    ctx.clip()
  ctx.lineWidth = 1 / zoom

  if zoom >= 0.45:
    ctx.strokeStyle = view.so("gridMinorColor", "#eef1f5")
    ctx.beginPath()
    var x = floor(left / minor) * minor
    while x <= right:
      ctx.moveTo(x, top)
      ctx.lineTo(x, bottom)
      x += minor
    var y = floor(top / minor) * minor
    while y <= bottom:
      ctx.moveTo(left, y)
      ctx.lineTo(right, y)
      y += minor
    ctx.stroke()

  ctx.strokeStyle = view.so("gridColor", "#dfe4ea")
  ctx.beginPath()
  var mx = floor(left / major) * major
  while mx <= right:
    ctx.moveTo(mx, top)
    ctx.lineTo(mx, bottom)
    mx += major
  var my = floor(top / major) * major
  while my <= bottom:
    ctx.moveTo(left, my)
    ctx.lineTo(right, my)
    my += major
  ctx.stroke()
  ctx.restore()

# -------------------------------------------------------------- edges --

proc drawArrow(ctx: Ctx, point, previous: Pt, kind: string, size: float64,
               color: string, strokeWidth: float64) =
  if kind == "none": return
  let angle = arctan2(point.y - previous.y, point.x - previous.x)
  let markerStroke = jsMax(0.5, (if truthy(jnum(strokeWidth)): strokeWidth else: 1.0))
  let endOffset = markerStroke * 1.118
  let length = size + markerStroke
  let tip = -endOffset
  ctx.save()
  ctx.translate(point.x, point.y)
  ctx.rotate(angle)
  ctx.strokeStyle = color
  ctx.fillStyle = color
  ctx.lineWidth = markerStroke
  ctx.lineJoin = "miter"
  if kind == "open":
    ctx.beginPath()
    ctx.moveTo(tip - length, -length * 0.5)
    ctx.lineTo(tip, 0)
    ctx.lineTo(tip - length, length * 0.5)
    ctx.stroke()
  elif kind == "oval":
    ctx.beginPath()
    ctx.ellipse(-size * 0.45, 0, size * 0.48, size * 0.36, 0, 0, PI * 2)
    ctx.fill()
    ctx.stroke()
  elif kind == "diamond":
    polygon(ctx, [pt(tip, 0), pt(tip - size * 0.65, -size * 0.45),
                  pt(tip - size * 1.3, 0), pt(tip - size * 0.65, size * 0.45)])
    ctx.fill()
    ctx.stroke()
  elif kind == "classic" or kind == "classicThin":
    let half = if kind == "classicThin": length / 3 else: length / 2
    polygon(ctx, [pt(tip, 0), pt(tip - length, -half), pt(tip - length * 0.75, 0),
                  pt(tip - length, half)])
    ctx.fill()
    ctx.stroke()
  else:
    polygon(ctx, [pt(tip, 0), pt(tip - length, -length * 0.5), pt(tip - length, length * 0.5)])
    ctx.fill()
    ctx.stroke()
  ctx.restore()

proc markerInset(kind: string, size, strokeWidth: float64): float64 =
  if kind == "none": return 0
  let sw = jsMax(0.5, (if truthy(jnum(strokeWidth)): strokeWidth else: 1.0))
  if kind == "open": return sw * 2.236
  if kind == "oval": return size / 2
  if kind == "diamond": return size * 1.3
  if kind == "classic" or kind == "classicThin": return (size + sw) * 0.75 + sw * 1.118
  size + sw + sw * 1.118

proc insetTerminal(point, neighbor: Pt, amount0: float64): Pt =
  let dx = neighbor.x - point.x
  let dy = neighbor.y - point.y
  let distance = hypot(dx, dy)
  if distance < 0.01 or amount0 <= 0: return point
  let amount = jsMin(amount0, distance * 0.8)
  pt(point.x + dx / distance * amount, point.y + dy / distance * amount)

proc arrowKind(v: Val, d: string): string =
  ## `edge.endArrow == null ? d : edge.endArrow` / `edge.startArrow || d`
  if nullish(v): d else: str(v)

proc middleOf(points: seq[Pt]): Pt =
  var m = points[points.len div 2]
  if points.len mod 2 == 0:
    let prev = points[points.len div 2 - 1]
    m = pt((m.x + prev.x) / 2, (m.y + prev.y) / 2)
  m

proc portTypeColor(dataType: string): string =
  case dataType
  of "float", "number", "int": "#06b6d4"
  of "bool", "boolean": "#818cf8"
  of "text", "string": "#eab308"
  else: "#38bdf8"

proc drawPortDot(ctx: Ctx, x, y: float64, color: string) =
  ctx.beginPath()
  ctx.arc(x, y, 5.5, 0, PI * 2)
  ctx.fillStyle = "#ffffff"
  ctx.fill()
  ctx.strokeStyle = color
  ctx.lineWidth = 2
  ctx.stroke()

proc namedPortColor(node, anchor: Val): (bool, string) =
  ## The colour of the named socket an edge endpoint is plugged into, or
  ## false when the endpoint is not a socket (an ordinary anchor/side).
  if node == nil or anchor == nil or not node.tr("portsEnabled"): return (false, "")
  let direction = anchor.so("portKind", "")
  if direction notin ["input", "output"] or not anchor["portIndex"].isNum: return (false, "")
  let entries = portLabels(node, direction)
  let index = int(num(anchor["portIndex"]))
  if index < 0 or index >= entries.len: return (false, "")
  (true, portTypeColor(entries[index][1]))

proc portWireColor(p: ScenePainter, edge: Val): (bool, string) =
  ## A wire plugged into a typed socket at either end takes that type's
  ## colour, the same convention as the socket dot itself.
  let (sOk, sColor) = namedPortColor(lookup(p.items, edge["sourceId"]), edge["sourceAnchor"])
  if sOk: return (true, sColor)
  namedPortColor(lookup(p.items, edge["targetId"]), edge["targetAnchor"])

proc bezierPoint(p0, c1, c2, p3: Pt, t: float64): Pt =
  let mt = 1.0 - t
  let a = mt * mt * mt
  let b = 3 * mt * mt * t
  let c = 3 * mt * t * t
  let d = t * t * t
  pt(a * p0.x + b * c1.x + c * c2.x + d * p3.x, a * p0.y + b * c1.y + c * c2.y + d * p3.y)

proc drawMidArrow(ctx: Ctx, at, back: Pt, size: float64, color: string) =
  let angle = arctan2(at.y - back.y, at.x - back.x)
  ctx.save()
  ctx.translate(at.x, at.y)
  ctx.rotate(angle)
  ctx.beginPath()
  ctx.moveTo(0, 0)
  ctx.lineTo(-size, size * 0.55)
  ctx.lineTo(-size, -size * 0.55)
  ctx.closePath()
  ctx.fillStyle = color
  ctx.fill()
  ctx.restore()

proc drawPortWire(p: ScenePainter, ctx: Ctx, edge: Val, p0, p3: Pt, color: string) =
  ## A data connection between two named sockets: a smooth curve (the
  ## dataflow-editor "noodle" convention) with a single arrowhead at its
  ## midpoint showing which way the value flows -- the tip needs no arrow of
  ## its own, since the socket dot it plugs into already marks the end.
  let pull = jsMax(40.0, abs(p3.x - p0.x) * 0.5)
  let c1 = pt(p0.x + pull, p0.y)
  let c2 = pt(p3.x - pull, p3.y)
  ctx.save()
  ctx.globalAlpha = if edge.nul("opacity"): 1.0 else: clamp(edge.nm("opacity"), 0, 1)
  ctx.beginPath()
  ctx.moveTo(p0.x, p0.y)
  ctx.bezierCurveTo(c1.x, c1.y, c2.x, c2.y, p3.x, p3.y)
  ctx.strokeStyle = color
  ctx.lineWidth = edge.fo("strokeWidth", 2)
  ctx.lineJoin = "round"
  ctx.lineCap = "round"
  ctx.stroke()
  let mid = bezierPoint(p0, c1, c2, p3, 0.5)
  let near = bezierPoint(p0, c1, c2, p3, 0.42)
  drawMidArrow(ctx, mid, near, edge.fo("arrowSize", 9), color)
  ctx.restore()

proc drawEdge*(p: ScenePainter, ctx: Ctx, edge: Val) =
  let points = edgePoints(edge, p.items)
  if points.len < 2: return
  block:
    let (hasPortColor, portColor) = p.portWireColor(edge)
    if hasPortColor:
      p.drawPortWire(ctx, edge, points[0], points[^1], portColor)
      return
  let circular = if edge.eqs("lineStyle", "circular"): circularArc(edge, p.items) else: CircArc()
  let paintPoints = if circular.valid: circular.samples else: points
  var strokePoints = paintPoints
  let arrowSize = edge.fo("arrowSize", 9)
  let edgeWidth = edge.fo("strokeWidth", 2)
  let endKind = arrowKind(edge["endArrow"], "classic")
  let startKind = if truthy(edge["startArrow"]): str(edge["startArrow"]) else: "none"

  if not circular.valid and not edge.eqs("lineStyle", "curved") and strokePoints.len >= 2:
    strokePoints[0] = insetTerminal(strokePoints[0], strokePoints[1],
                                    markerInset(startKind, arrowSize, edgeWidth))
    let last = strokePoints.len - 1
    strokePoints[last] = insetTerminal(strokePoints[last], strokePoints[last - 1],
                                       markerInset(endKind, arrowSize, edgeWidth))

  ctx.save()
  ctx.globalAlpha = if edge.nul("opacity"): 1.0 else: clamp(edge.nm("opacity"), 0, 1)
  ctx.beginPath()
  ctx.moveTo(strokePoints[0].x, strokePoints[0].y)
  if circular.valid:
    ctx.arc(circular.center.x, circular.center.y, circular.radius,
            circular.startAngle, circular.endAngle, circular.anticlockwise)
  elif edge.eqs("lineStyle", "curved") and points.len > 2:
    for i in 1 ..< points.len - 1:
      let midpoint = pt((points[i].x + points[i + 1].x) / 2, (points[i].y + points[i + 1].y) / 2)
      ctx.quadraticCurveTo(points[i].x, points[i].y, midpoint.x, midpoint.y)
    ctx.lineTo(points[^1].x, points[^1].y)
  else:
    for j in 1 ..< strokePoints.len: ctx.lineTo(strokePoints[j].x, strokePoints[j].y)
  var color = edge.so("stroke", "#4f5968")
  block:
    let (hasPortColor, portColor) = p.portWireColor(edge)
    if hasPortColor: color = portColor
  ctx.strokeStyle = color
  ctx.lineWidth = edge.fo("strokeWidth", 2)
  ctx.lineJoin = "round"
  ctx.lineCap = "round"
  if edge.tr("dashed"): ctx.setLineDash(dashPattern(edge))
  ctx.stroke()
  ctx.setLineDash([])

  drawArrow(ctx, paintPoints[^1], paintPoints[^2], endKind, arrowSize, color, edgeWidth)
  drawArrow(ctx, paintPoints[0], paintPoints[1], startKind, arrowSize, color, edgeWidth)

  if edge.eqs("edgeSymbol", "message"):
    let symbolAt = if circular.valid: circular.middle else: middleOf(points)
    ctx.beginPath()
    ctx.rect(symbolAt.x - 10, symbolAt.y - 7, 20, 14)
    ctx.fillStyle = edge.so("symbolFill", "#ffffff")
    ctx.fill()
    ctx.strokeStyle = color
    ctx.lineWidth = 1
    ctx.stroke()
    ctx.beginPath()
    ctx.moveTo(symbolAt.x - 10, symbolAt.y - 7)
    ctx.lineTo(symbolAt.x, symbolAt.y)
    ctx.lineTo(symbolAt.x + 10, symbolAt.y - 7)
    ctx.stroke()

  if edge.tr("sourceLabel") or edge.tr("targetLabel"):
    ctx.font = edge.so("fontWeight", "400") & " " & edge.so("fontSize", "11") & "px " &
      edge.so("fontFamily", "Arial, sans-serif")
    ctx.textBaseline = "bottom"
    ctx.fillStyle = edge.so("textColor", color)
    if edge.tr("sourceLabel"):
      ctx.textAlign = "left"
      ctx.fillText(str(edge["sourceLabel"]), points[0].x + 6, points[0].y - 4)
    if edge.tr("targetLabel"):
      ctx.textAlign = "right"
      ctx.fillText(str(edge["targetLabel"]), points[^1].x - 6, points[^1].y - 4)

  if edge.tr("text"):
    let middle = if circular.valid: circular.middle else: middleOf(points)
    ctx.font = edge.so("fontWeight", "400") & " " & edge.so("fontSize", "12") & "px " &
      edge.so("fontFamily", "Arial, sans-serif")
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    let text = str(edge["text"])
    let width = ctx.measureText(text)
    ctx.fillStyle = edge.so("labelBackground", "rgba(255,255,255,.92)")
    ctx.fillRect(middle.x - width / 2 - 4, middle.y - 9, width + 8, 18)
    ctx.fillStyle = edge.so("textColor", color)
    ctx.fillText(text, middle.x, middle.y)
  ctx.restore()

# -------------------------------------------------------------- nodes --

proc isStrokeOnly(shape: Val): bool =
  if shape == nil or shape.kind != vStr: return false
  shape.s in ["text", "actor", "umlDestroy", "requiredInterface", "curlyBracket",
              "crossbar", "line", "parallelMarker"]

proc traceNode*(p: ScenePainter, ctx: Ctx, node: Val) =
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  let cx = x + w / 2
  let cy = y + h / 2
  let shape = node.so("shape", "rect")
  template size(d: float64): float64 = node.nn("shapeSize", d)

  case shape
  of "text":
    ctx.beginPath()
  of "ellipse":
    ctx.beginPath()
    ctx.ellipse(cx, cy, w / 2, h / 2, 0, 0, PI * 2)
  of "diamond":
    polygon(ctx, [pt(cx, y), pt(x + w, cy), pt(cx, y + h), pt(x, cy)])
  of "triangle":
    polygon(ctx, [pt(cx, y), pt(x + w, y + h), pt(x, y + h)])
  of "hexagon":
    let s = clamp(size(0.22), 0, 0.48)
    polygon(ctx, [pt(x + w * s, y), pt(x + w * (1 - s), y), pt(x + w, cy),
                  pt(x + w * (1 - s), y + h), pt(x + w * s, y + h), pt(x, cy)])
  of "parallelogram":
    let s = clamp(size(0.18), 0, 0.48)
    polygon(ctx, [pt(x + w * s, y), pt(x + w, y), pt(x + w * (1 - s), y + h), pt(x, y + h)])
  of "trapezoid":
    let s = clamp(size(0.18), 0, 0.48)
    polygon(ctx, [pt(x + w * s, y), pt(x + w * (1 - s), y), pt(x + w, y + h), pt(x, y + h)])
  of "chevron":
    let s = clamp(size(0.28), 0, 0.48)
    polygon(ctx, [pt(x, y), pt(x + w * (1 - s), y), pt(x + w, cy), pt(x + w * (1 - s), y + h),
                  pt(x, y + h), pt(x + w * s, cy)])
  of "step":
    let s = clamp(size(0.25), 0, 0.48)
    polygon(ctx, [pt(x, y), pt(x + w * (1 - s), y), pt(x + w, cy), pt(x + w * (1 - s), y + h),
                  pt(x, y + h), pt(x + w * s, cy)])
  of "isoCube2":
    let isoAngle = clamp(node.nn("isoAngle", 15), 0.01, 94) * PI / 200
    let isoHeight = jsMin(w * tan(isoAngle), h * 0.5)
    polygon(ctx, [pt(cx, y), pt(x + w, y + isoHeight), pt(x + w, y + h - isoHeight),
                  pt(cx, y + h), pt(x, y + h - isoHeight), pt(x, y + isoHeight)])
  of "isoRectangle":
    let isoWidth = jsMin(w, h / tan(PI / 6))
    let isoX = x + (w - isoWidth) / 2
    polygon(ctx, [pt(isoX, cy), pt(isoX + isoWidth / 2, y), pt(isoX + isoWidth, cy),
                  pt(isoX + isoWidth / 2, y + h)])
  of "line":
    ctx.beginPath()
    if node.eqs("direction", "south") or node.eqs("direction", "north"):
      ctx.moveTo(cx, y)
      ctx.lineTo(cx, y + h)
    else:
      ctx.moveTo(x, cy)
      ctx.lineTo(x + w, cy)
  of "curlyBracket":
    ctx.beginPath()
    ctx.moveTo(x + w, y)
    ctx.bezierCurveTo(x, y, x + w, cy - h * 0.12, x, cy)
    ctx.bezierCurveTo(x + w, cy + h * 0.12, x, y + h, x + w, y + h)
  of "crossbar":
    ctx.beginPath()
    ctx.moveTo(x, cy)
    ctx.lineTo(x + w, cy)
    ctx.moveTo(x, y)
    ctx.lineTo(x, y + h)
    ctx.moveTo(x + w, y)
    ctx.lineTo(x + w, y + h)
  of "manualInput":
    let manualSize = jsMin(h, size(30))
    polygon(ctx, [pt(x, y + manualSize), pt(x + w, y), pt(x + w, y + h), pt(x, y + h)])
  of "loopLimit":
    let loopSize = clamp(size(20), 0, w / 2)
    let loopDrop = clamp(node.nn("dy", loopSize * 0.8), 0, h)
    polygon(ctx, [pt(x + loopSize, y), pt(x + w - loopSize, y), pt(x + w, y + loopDrop),
                  pt(x + w, y + h), pt(x, y + h), pt(x, y + loopDrop)])
  of "offPageConnector":
    let connectorSize = h * clamp(size(3 / 8), 0, 1)
    polygon(ctx, [pt(x, y), pt(x + w, y), pt(x + w, y + h - connectorSize), pt(cx, y + h),
                  pt(x, y + h - connectorSize)])
  of "display":
    let displayDx = jsMin(w, h / 2)
    let displaySize = jsMin(w - displayDx, jsMax(0, size(0.25)) * w)
    ctx.beginPath()
    ctx.moveTo(x, cy)
    ctx.lineTo(x + displaySize, y)
    ctx.lineTo(x + w - displayDx, y)
    ctx.quadraticCurveTo(x + w, y, x + w, cy)
    ctx.quadraticCurveTo(x + w, y + h, x + w - displayDx, y + h)
    ctx.lineTo(x + displaySize, y + h)
    ctx.closePath()
  of "singleArrow", "doubleArrow":
    let direction = node.so("direction", "east")
    let vertical = direction == "north" or direction == "south"
    let arrowW = if vertical: h else: w
    let arrowH = if vertical: w else: h
    let arrowWidth = arrowH * clamp(node.nn("arrowWidth", 0.3), 0, 1)
    let arrowSize = arrowW * clamp(node.nn("arrowSize", 0.2), 0, 1)
    let top = (arrowH - arrowWidth) / 2
    let bottom = top + arrowWidth
    proc ap(u, v: float64): Pt =
      if direction == "west": pt(x + w - u, y + h - v)
      elif direction == "north": pt(x + v, y + h - u)
      elif direction == "south": pt(x + w - v, y + u)
      else: pt(x + u, y + v)
    if shape == "singleArrow":
      polygon(ctx, [ap(0, top), ap(arrowW - arrowSize, top), ap(arrowW - arrowSize, 0),
                    ap(arrowW, arrowH / 2), ap(arrowW - arrowSize, arrowH),
                    ap(arrowW - arrowSize, bottom), ap(0, bottom)])
    else:
      polygon(ctx, [ap(0, arrowH / 2), ap(arrowSize, 0), ap(arrowSize, top),
                    ap(arrowW - arrowSize, top), ap(arrowW - arrowSize, 0), ap(arrowW, arrowH / 2),
                    ap(arrowW - arrowSize, arrowH), ap(arrowW - arrowSize, bottom),
                    ap(arrowSize, bottom), ap(arrowSize, arrowH)])
  of "cross":
    let crossSize = jsMin(w, h) * clamp(size(0.2), 0, 1)
    let crossTop = y + (h - crossSize) / 2
    let crossBottom = crossTop + crossSize
    let crossLeft = x + (w - crossSize) / 2
    let crossRight = crossLeft + crossSize
    polygon(ctx, [pt(x, crossTop), pt(crossLeft, crossTop), pt(crossLeft, y), pt(crossRight, y),
                  pt(crossRight, crossTop), pt(x + w, crossTop), pt(x + w, crossBottom),
                  pt(crossRight, crossBottom), pt(crossRight, y + h), pt(crossLeft, y + h),
                  pt(crossLeft, crossBottom), pt(x, crossBottom)])
  of "corner":
    let cdx = jsMin(w, size(20))
    let cdy = jsMin(h, size(20))
    polygon(ctx, [pt(x, y), pt(x + w, y), pt(x + w, y + cdy), pt(x + cdx, y + cdy),
                  pt(x + cdx, y + h), pt(x, y + h)])
  of "tee":
    let tdx = jsMin(w, size(20))
    let tdy = jsMin(h, size(20))
    polygon(ctx, [pt(x, y), pt(x + w, y), pt(x + w, y + tdy), pt(cx + tdx / 2, y + tdy),
                  pt(cx + tdx / 2, y + h), pt(cx - tdx / 2, y + h), pt(cx - tdx / 2, y + tdy),
                  pt(x, y + tdy)])
  of "tapeData", "orEllipse", "sumEllipse", "lineEllipse":
    ctx.beginPath()
    ctx.ellipse(cx, cy, w / 2, h / 2, 0, 0, PI * 2)
  of "sortShape":
    polygon(ctx, [pt(cx, y), pt(x + w, cy), pt(cx, y + h), pt(x, cy)])
  of "datastore":
    let cap = jsMin(h / 2, jsRound(h / 8) + node.fo("strokeWidth", 1) - 1)
    ctx.beginPath()
    ctx.moveTo(x, y + cap)
    ctx.bezierCurveTo(x, y - cap / 3, x + w, y - cap / 3, x + w, y + cap)
    ctx.lineTo(x + w, y + h - cap)
    ctx.bezierCurveTo(x + w, y + h + cap / 3, x, y + h + cap / 3, x, y + h - cap)
    ctx.closePath()
  of "switch":
    ctx.beginPath()
    ctx.moveTo(x, y)
    ctx.quadraticCurveTo(cx, y + h * 0.5, x + w, y)
    ctx.quadraticCurveTo(x + w * 0.5, cy, x + w, y + h)
    ctx.quadraticCurveTo(cx, y + h * 0.5, x, y + h)
    ctx.quadraticCurveTo(x + w * 0.5, cy, x, y)
    ctx.closePath()
  of "collate":
    ctx.beginPath()
    ctx.moveTo(x, y)
    ctx.lineTo(x + w, y)
    ctx.lineTo(cx, cy)
    ctx.closePath()
    ctx.moveTo(x, y + h)
    ctx.lineTo(x + w, y + h)
    ctx.lineTo(cx, cy)
    ctx.closePath()
  of "partialRectangle":
    ctx.beginPath()
    ctx.rect(x, y, w, h)
  of "delay":
    let delayDx = jsMin(w, h / 2)
    ctx.beginPath()
    ctx.moveTo(x, y)
    ctx.lineTo(x + w - delayDx, y)
    ctx.quadraticCurveTo(x + w, y, x + w, cy)
    ctx.quadraticCurveTo(x + w, y + h, x + w - delayDx, y + h)
    ctx.lineTo(x, y + h)
    ctx.closePath()
  of "document":
    ctx.beginPath()
    ctx.moveTo(x, y)
    ctx.lineTo(x + w, y)
    ctx.lineTo(x + w, y + h * 0.82)
    ctx.bezierCurveTo(x + w * 0.75, y + h * 0.65, x + w * 0.55, y + h * 1.05, x + w * 0.3, y + h * 0.86)
    ctx.bezierCurveTo(x + w * 0.18, y + h * 0.77, x + w * 0.08, y + h * 0.8, x, y + h * 0.88)
    ctx.closePath()
  of "note":
    let fold = jsMin(w, h) * clamp(size(0.28), 0.08, 0.5)
    polygon(ctx, [pt(x, y), pt(x + w - fold, y), pt(x + w, y + fold), pt(x + w, y + h), pt(x, y + h)])
  of "cube":
    let depth = jsMin(w, h) * clamp(size(0.2), 0, 0.45)
    polygon(ctx, [pt(x, y + depth), pt(x + depth, y), pt(x + w, y), pt(x + w, y + h - depth),
                  pt(x + w - depth, y + h), pt(x, y + h)])
  of "cylinder":
    let cap = h * clamp(size(0.1875), 0, 0.5)
    ctx.beginPath()
    ctx.moveTo(x, y + cap)
    ctx.bezierCurveTo(x, y - cap * 0.17, x + w, y - cap * 0.17, x + w, y + cap)
    ctx.lineTo(x + w, y + h - cap)
    ctx.bezierCurveTo(x + w, y + h + cap * 0.17, x, y + h + cap * 0.17, x, y + h - cap)
    ctx.closePath()
  of "cloud":
    ctx.beginPath()
    ctx.moveTo(x + w * 0.2, y + h * 0.78)
    ctx.bezierCurveTo(x - w * 0.05, y + h * 0.76, x, y + h * 0.42, x + w * 0.2, y + h * 0.4)
    ctx.bezierCurveTo(x + w * 0.18, y + h * 0.16, x + w * 0.48, y + h * 0.06, x + w * 0.58, y + h * 0.27)
    ctx.bezierCurveTo(x + w * 0.78, y + h * 0.08, x + w * 1.02, y + h * 0.28, x + w * 0.9, y + h * 0.5)
    ctx.bezierCurveTo(x + w * 1.08, y + h * 0.7, x + w * 0.82, y + h * 0.94, x + w * 0.63, y + h * 0.79)
    ctx.bezierCurveTo(x + w * 0.5, y + h * 1.02, x + w * 0.28, y + h * 0.96, x + w * 0.2, y + h * 0.78)
    ctx.closePath()
  of "actor":
    ctx.beginPath()
    ctx.ellipse(cx, y + h * 0.13, w * 0.09, h * 0.1, 0, 0, PI * 2)
    ctx.moveTo(cx, y + h * 0.23)
    ctx.lineTo(cx, y + h * 0.62)
    ctx.moveTo(x + w * 0.22, y + h * 0.38)
    ctx.lineTo(x + w * 0.78, y + h * 0.38)
    ctx.moveTo(cx, y + h * 0.62)
    ctx.lineTo(x + w * 0.28, y + h)
    ctx.moveTo(cx, y + h * 0.62)
    ctx.lineTo(x + w * 0.72, y + h)
  of "blockArrow":
    let arrowSize = clamp(node.nor("arrowSize", 0.38), 0.1, 0.8)
    let arrowWidth = clamp(node.nor("arrowWidth", 0.44), 0.1, 1)
    let neck = x + w * (1 - arrowSize)
    let shaftTop = y + h * (1 - arrowWidth) / 2
    let shaftBottom = y + h * (1 + arrowWidth) / 2
    polygon(ctx, [pt(x, shaftTop), pt(neck, shaftTop), pt(neck, y), pt(x + w, cy),
                  pt(neck, y + h), pt(neck, shaftBottom), pt(x, shaftBottom)])
  of "speech":
    roundedRect(ctx, x, y, w, h * 0.78, jsMin(10, h * 0.12))
    ctx.moveTo(x + w * 0.28, y + h * 0.78)
    ctx.lineTo(x + w * 0.2, y + h)
    ctx.lineTo(x + w * 0.48, y + h * 0.78)
    ctx.closePath()
  of "plus":
    polygon(ctx, [pt(x + w * 0.35, y), pt(x + w * 0.65, y), pt(x + w * 0.65, y + h * 0.35),
                  pt(x + w, y + h * 0.35), pt(x + w, y + h * 0.65), pt(x + w * 0.65, y + h * 0.65),
                  pt(x + w * 0.65, y + h), pt(x + w * 0.35, y + h), pt(x + w * 0.35, y + h * 0.65),
                  pt(x, y + h * 0.65), pt(x, y + h * 0.35), pt(x + w * 0.35, y + h * 0.35)])
  of "umlBoundary":
    ctx.beginPath()
    ctx.ellipse(x + w / 6 + (w * 5 / 6) / 2, cy, (w * 5 / 6) / 2, h / 2, 0, 0, PI * 2)
  of "umlEntity":
    ctx.beginPath()
    ctx.ellipse(cx, cy, w / 2, h / 2, 0, 0, PI * 2)
  of "umlControl":
    ctx.beginPath()
    ctx.ellipse(cx, y + h / 8 + (h * 7 / 8) / 2, w / 2, (h * 7 / 8) / 2, 0, 0, PI * 2)
  of "umlDestroy":
    ctx.beginPath()
    ctx.moveTo(x + w, y)
    ctx.lineTo(x, y + h)
    ctx.moveTo(x, y)
    ctx.lineTo(x + w, y + h)
  of "umlLifeline":
    let head = jsMax(0, jsMin(h, size(40)))
    roundedRect(ctx, x, y, w, head, node.nn("radius", 0))
  of "umlFrame":
    ctx.beginPath()
    ctx.rect(x, y, w, h)
  of "umlState":
    roundedRect(ctx, x, y, w, h, node.nn("radius", 10))
  of "module", "component":
    let jettyW = node.nor("jettyWidth", (if shape == "module": 20.0 else: 32.0))
    let jettyH = node.nor("jettyHeight", (if shape == "module": 10.0 else: 12.0))
    let jx0 = jettyW / 2
    let jy0 = if shape == "module": jsMin(jettyH, h - jettyH) else: 0.3 * h - jettyH / 2
    let jy1 = if shape == "module": jsMin(jy0 + 2 * jettyH, h - jettyH) else: 0.7 * h - jettyH / 2
    polygon(ctx, [pt(x + jx0, y), pt(x + w, y), pt(x + w, y + h), pt(x + jx0, y + h),
                  pt(x + jx0, y + jy1 + jettyH), pt(x, y + jy1 + jettyH), pt(x, y + jy1),
                  pt(x + jx0, y + jy1), pt(x + jx0, y + jy0 + jettyH), pt(x, y + jy0 + jettyH),
                  pt(x, y + jy0), pt(x + jx0, y + jy0)])
  of "folder":
    let tabW = jsMax(0, jsMin(w, node.nn("tabWidth", 60)))
    let tabH = jsMax(0, jsMin(h, node.nn("tabHeight", 20)))
    if node.eqs("tabPosition", "left"):
      polygon(ctx, [pt(x, y), pt(x + tabW, y), pt(x + tabW, y + tabH), pt(x + w, y + tabH),
                    pt(x + w, y + h), pt(x, y + h)])
    else:
      polygon(ctx, [pt(x + w - tabW, y), pt(x + w, y), pt(x + w, y + h), pt(x, y + h),
                    pt(x, y + tabH), pt(x + w - tabW, y + tabH)])
  of "providedRequiredInterface":
    let inset = node.nn("inset", 2) + node.nn("strokeWidth", 1)
    let iw = jsMax(0, w - 2 * inset)
    let ih = jsMax(0, h - 2 * inset)
    ctx.beginPath()
    ctx.ellipse(x + iw / 2, y + inset + ih / 2, iw / 2, ih / 2, 0, 0, PI * 2)
  of "requiredInterface":
    ctx.beginPath()
    ctx.moveTo(x, y)
    ctx.quadraticCurveTo(x + w, y, x + w, cy)
    ctx.quadraticCurveTo(x + w, y + h, x, y + h)
  of "endState", "startState":
    let inset = if shape == "endState": jsMin(4, jsMin(w / 5, h / 5)) else: 0.0
    ctx.beginPath()
    ctx.ellipse(cx, cy, jsMax(0, w / 2 - inset), jsMax(0, h / 2 - inset), 0, 0, PI * 2)
  of "message":
    ctx.beginPath()
    ctx.rect(x, y, w, h)
  of "parallelMarker":
    let barW = w / 5
    ctx.beginPath()
    ctx.rect(x, y, barW, h)
    ctx.rect(x + 2 * barW, y, barW, h)
    ctx.rect(x + 4 * barW, y, barW, h)
  of "card":
    let cardSize = clamp(size(30), 0, w)
    let cardDrop = clamp(node.nn("dy", cardSize), 0, h)
    polygon(ctx, [pt(x + cardSize, y), pt(x + w, y), pt(x + w, y + h), pt(x, y + h), pt(x, y + cardDrop)])
  of "tape":
    let tapeDy = h * clamp(size(0.4), 0, 1)
    let curve = 1.4
    ctx.beginPath()
    ctx.moveTo(x, y + tapeDy / 2)
    ctx.quadraticCurveTo(x + w / 4, y + tapeDy * curve, cx, y + tapeDy / 2)
    ctx.quadraticCurveTo(x + w * 3 / 4, y + tapeDy * (1 - curve), x + w, y + tapeDy / 2)
    ctx.lineTo(x + w, y + h - tapeDy / 2)
    ctx.quadraticCurveTo(x + w * 3 / 4, y + h - tapeDy * curve, cx, y + h - tapeDy / 2)
    ctx.quadraticCurveTo(x + w / 4, y + h - tapeDy * (1 - curve), x, y + h - tapeDy / 2)
    ctx.closePath()
  of "dataStorage":
    let storage = w * clamp(size(0.1), 0, 1)
    ctx.beginPath()
    ctx.moveTo(x + storage, y)
    ctx.lineTo(x + w, y)
    ctx.quadraticCurveTo(x + w - storage * 2, cy, x + w, y + h)
    ctx.lineTo(x + storage, y + h)
    ctx.quadraticCurveTo(x - storage, cy, x + storage, y)
    ctx.closePath()
  of "xor", "or":
    ctx.beginPath()
    ctx.moveTo(x, y)
    ctx.quadraticCurveTo(x + w, y, x + w, cy)
    ctx.quadraticCurveTo(x + w, y + h, x, y + h)
    if shape == "xor": ctx.quadraticCurveTo(x + w / 2, cy, x, y)
    ctx.closePath()
  else:
    roundedRect(ctx, x, y, w, h, node.nn("radius", 4))

proc drawNodeDecorations(p: ScenePainter, ctx: Ctx, node: Val) =
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  let shape = if node["shape"].isStr: node["shape"].s else: ""
  template size(d: float64): float64 = node.nn("shapeSize", d)
  ctx.save()
  ctx.strokeStyle = node.so("stroke", "#4a5564")
  ctx.lineWidth = node.nn("strokeWidth", 1.5)

  if shape == "cylinder":
    let cap = h * clamp(size(0.1875), 0, 0.5)
    ctx.beginPath()
    ctx.moveTo(x, y + cap)
    ctx.bezierCurveTo(x, y + cap * 2.17, x + w, y + cap * 2.17, x + w, y + cap)
    ctx.stroke()
  elif shape == "isoCube2":
    let isoAngle = clamp(node.nn("isoAngle", 15), 0.01, 94) * PI / 200
    let isoHeight = jsMin(w * tan(isoAngle), h * 0.5)
    ctx.beginPath()
    ctx.moveTo(x, y + isoHeight)
    ctx.lineTo(x + w / 2, y + 2 * isoHeight)
    ctx.lineTo(x + w, y + isoHeight)
    ctx.moveTo(x + w / 2, y + 2 * isoHeight)
    ctx.lineTo(x + w / 2, y + h)
    ctx.stroke()
  elif node.tr("double") and (shape == "rect" or shape == "ellipse"):
    let inset = jsMin(6, jsMin(w, h) / 6)
    ctx.beginPath()
    if shape == "ellipse":
      ctx.ellipse(x + w / 2, y + h / 2, jsMax(0, w / 2 - inset), jsMax(0, h / 2 - inset), 0, 0, PI * 2)
    else:
      roundedRect(ctx, x + inset, y + inset, jsMax(0, w - 2 * inset), jsMax(0, h - 2 * inset),
                  jsMax(0, node.fo("radius", 0) - inset / 2))
    ctx.stroke()
  elif shape == "note":
    let fold = jsMin(w, h) * clamp(size(0.28), 0.08, 0.5)
    ctx.beginPath()
    ctx.moveTo(x + w - fold, y)
    ctx.lineTo(x + w - fold, y + fold)
    ctx.lineTo(x + w, y + fold)
    ctx.stroke()
  elif shape == "cube":
    let depth = jsMin(w, h) * clamp(size(0.2), 0, 0.45)
    ctx.beginPath()
    ctx.moveTo(x, y + depth)
    ctx.lineTo(x + w - depth, y + depth)
    ctx.lineTo(x + w, y)
    ctx.moveTo(x + w - depth, y + depth)
    ctx.lineTo(x + w - depth, y + h)
    ctx.stroke()
  elif shape == "swimlane":
    let vertical = node["horizontal"].isFalse
    let extent = if vertical: w else: h
    let header = jsMax(0, jsMin(extent, if node.nul("headerHeight"): jsMin(extent * 0.28, 32)
                                         else: node.nm("headerHeight")))
    ctx.beginPath()
    if vertical:
      ctx.moveTo(x + header, y)
      ctx.lineTo(x + header, y + h)
    else:
      ctx.moveTo(x, y + header)
      ctx.lineTo(x + w, y + header)
    ctx.stroke()
  elif shape == "tapeData":
    ctx.beginPath()
    ctx.moveTo(x + w / 2, y + h)
    ctx.lineTo(x + w, y + h)
    ctx.stroke()
  elif shape == "orEllipse":
    ctx.beginPath()
    ctx.moveTo(x, y + h / 2)
    ctx.lineTo(x + w, y + h / 2)
    ctx.moveTo(x + w / 2, y)
    ctx.lineTo(x + w / 2, y + h)
    ctx.stroke()
  elif shape == "sumEllipse":
    let s = 0.145
    ctx.beginPath()
    ctx.moveTo(x + w * s, y + h * s)
    ctx.lineTo(x + w * (1 - s), y + h * (1 - s))
    ctx.moveTo(x + w * (1 - s), y + h * s)
    ctx.lineTo(x + w * s, y + h * (1 - s))
    ctx.stroke()
  elif shape == "lineEllipse":
    ctx.beginPath()
    if node.eqs("line", "vertical"):
      ctx.moveTo(x + w / 2, y)
      ctx.lineTo(x + w / 2, y + h)
    else:
      ctx.moveTo(x, y + h / 2)
      ctx.lineTo(x + w, y + h / 2)
    ctx.stroke()
  elif shape == "sortShape":
    ctx.beginPath()
    ctx.moveTo(x, y + h / 2)
    ctx.lineTo(x + w, y + h / 2)
    ctx.stroke()
  elif shape == "datastore":
    let cap = jsMin(h / 2, jsRound(h / 8) + ctx.lineWidth - 1)
    ctx.beginPath()
    for row in 1 .. 3:
      let sy = y + cap * float64(row) / 2
      ctx.moveTo(x, sy)
      ctx.bezierCurveTo(x, sy + cap, x + w, sy + cap, x + w, sy)
    ctx.stroke()
  elif shape == "umlBoundary":
    ctx.beginPath()
    ctx.moveTo(x, y + h / 4)
    ctx.lineTo(x, y + h * 3 / 4)
    ctx.moveTo(x, y + h / 2)
    ctx.lineTo(x + w / 6, y + h / 2)
    ctx.stroke()
  elif shape == "umlEntity":
    ctx.beginPath()
    ctx.moveTo(x + w / 8, y + h)
    ctx.lineTo(x + w * 7 / 8, y + h)
    ctx.stroke()
  elif shape == "umlControl":
    ctx.beginPath()
    ctx.moveTo(x + w * 3 / 8, y + h / 8 * 1.1)
    ctx.lineTo(x + w * 5 / 8, y)
    ctx.moveTo(x + w * 3 / 8, y + h / 8 * 1.1)
    ctx.lineTo(x + w * 5 / 8, y + h / 4)
    ctx.stroke()
  elif shape == "umlLifeline":
    let head = jsMax(0, jsMin(h, size(40)))
    if head < h:
      ctx.setLineDash([4.0, 4.0])
      ctx.beginPath()
      ctx.moveTo(x + w / 2, y + head)
      ctx.lineTo(x + w / 2, y + h)
      ctx.stroke()
      ctx.setLineDash([])
  elif shape == "umlFrame":
    let frameW = jsMin(w, jsMax(10, node.nn("frameWidth", 60)))
    let frameH = jsMin(h, jsMax(15, node.nn("frameHeight", 30)))
    ctx.beginPath()
    ctx.moveTo(x, y)
    ctx.lineTo(x + frameW, y)
    ctx.lineTo(x + frameW, y + jsMax(0, frameH - 15))
    ctx.lineTo(x + jsMax(0, frameW - 10), y + frameH)
    ctx.lineTo(x, y + frameH)
    ctx.stroke()
  elif shape == "umlState" and node.eqs("umlStateSymbol", "collapseState"):
    ctx.beginPath()
    roundedRect(ctx, x + w - 40, y + h - 20, 10, 10, 3)
    roundedRect(ctx, x + w - 20, y + h - 20, 10, 10, 3)
    ctx.moveTo(x + w - 30, y + h - 15)
    ctx.lineTo(x + w - 20, y + h - 15)
    ctx.stroke()
  elif shape == "module" or shape == "component":
    let jw = node.nor("jettyWidth", (if shape == "module": 20.0 else: 32.0))
    let jh = node.nor("jettyHeight", (if shape == "module": 10.0 else: 12.0))
    let jx = jw / 2
    let jya = if shape == "module": jsMin(jh, h - jh) else: 0.3 * h - jh / 2
    let jyb = if shape == "module": jsMin(jya + 2 * jh, h - jh) else: 0.7 * h - jh / 2
    ctx.beginPath()
    ctx.rect(x, y + jya, jx, jh)
    ctx.rect(x, y + jyb, jx, jh)
    ctx.fillStyle = node.so("fill", "#ffffff")
    ctx.fill()
    ctx.stroke()
  elif shape == "providedRequiredInterface":
    ctx.beginPath()
    ctx.moveTo(x + w / 2, y)
    ctx.quadraticCurveTo(x + w, y, x + w, y + h / 2)
    ctx.quadraticCurveTo(x + w, y + h, x + w / 2, y + h)
    ctx.stroke()
  elif shape == "endState":
    ctx.beginPath()
    ctx.ellipse(x + w / 2, y + h / 2, w / 2, h / 2, 0, 0, PI * 2)
    ctx.stroke()
  elif shape == "message":
    ctx.beginPath()
    ctx.moveTo(x, y)
    ctx.lineTo(x + w / 2, y + h / 2)
    ctx.lineTo(x + w, y)
    ctx.stroke()
  elif shape == "parallelMarker":
    let pmW = w / 5
    ctx.beginPath()
    ctx.rect(x, y, pmW, h)
    ctx.rect(x + 2 * pmW, y, pmW, h)
    ctx.rect(x + 4 * pmW, y, pmW, h)
    ctx.fillStyle = node.so("stroke", "#4a5564")
    ctx.fill()
  elif shape == "process":
    let s = node["shapeSize"]
    let processInset = if nullish(s): w * 0.1
                       elif num(s) > 1: jsMin(w / 2, num(s))
                       else: w * clamp(num(s), 0, 0.5)
    ctx.beginPath()
    ctx.moveTo(x + processInset, y)
    ctx.lineTo(x + processInset, y + h)
    ctx.moveTo(x + w - processInset, y)
    ctx.lineTo(x + w - processInset, y + h)
    ctx.stroke()
  elif shape == "internalStorage":
    let sdx = jsMax(0, jsMin(w, node.nn("dx", 20)))
    let sdy = jsMax(0, jsMin(h, node.nn("dy", 20)))
    ctx.beginPath()
    ctx.moveTo(x, y + sdy)
    ctx.lineTo(x + w, y + sdy)
    ctx.moveTo(x + sdx, y)
    ctx.lineTo(x + sdx, y + h)
    ctx.stroke()
  elif shape == "partialRectangle":
    ctx.beginPath()
    if not node["top"].isFalse:
      ctx.moveTo(x, y)
      ctx.lineTo(x + w, y)
    if not node["right"].isFalse:
      ctx.moveTo(x + w, y)
      ctx.lineTo(x + w, y + h)
    if not node["bottom"].isFalse:
      ctx.moveTo(x + w, y + h)
      ctx.lineTo(x, y + h)
    if not node["left"].isFalse:
      ctx.moveTo(x, y + h)
      ctx.lineTo(x, y)
    ctx.stroke()
  elif shape == "table":
    let grid = tableGrid(node)
    let tb = node["tableBorder"]
    if not (tb.isNum and tb.n == 0):
      ctx.strokeStyle = (let g = node["gridStroke"]; if truthy(g): str(g) else: node.so("stroke", "#4a5564"))
      ctx.strokeRect(x, y, w, h)
      if grid.titleHeight > 0:
        ctx.beginPath()
        ctx.moveTo(x, grid.contentY)
        ctx.lineTo(x + w, grid.contentY)
        ctx.stroke()
      for r in 1 ..< grid.rows.len:
        if node["rowLines"].isFalse and not (node.tr("firstRowLine") and r == 1): continue
        ctx.beginPath()
        for rc in 0 ..< grid.columns.len:
          let above = tableCellOriginAt(node, float64(r - 1), float64(rc))
          if above.row + above.rowspan > r: continue
          ctx.moveTo(grid.columns[rc].pos, grid.rows[r].pos)
          ctx.lineTo(grid.columns[rc].pos + grid.columns[rc].size, grid.rows[r].pos)
        ctx.stroke()
      for c in 1 ..< grid.columns.len:
        ctx.beginPath()
        for cr in 0 ..< grid.rows.len:
          let leftCell = tableCellOriginAt(node, float64(cr), float64(c - 1))
          if leftCell.column + leftCell.colspan > c: continue
          ctx.moveTo(grid.columns[c].pos, grid.rows[cr].pos)
          ctx.lineTo(grid.columns[c].pos, grid.rows[cr].pos + grid.rows[cr].size)
        ctx.stroke()
  ctx.restore()

proc textBase*(node: Val, overrides: Val = nil): Val =
  ## Shared base style for the rich text engine.
  result = newObj()
  result["fontSize"] = orV(node["fontSize"], jnum(14))
  result["fontFamily"] = orV(node["fontFamily"], jstr("Arial, sans-serif"))
  result["fontWeight"] = if node.tr("bold"): jnum(700) else: orV(node["fontWeight"], jnum(500))
  result["color"] = orV(node["textColor"], jstr("#172033"))
  result["align"] = orV(node["textAlign"], jstr("center"))
  result["verticalAlign"] = orV(node["verticalAlign"], jstr("middle"))
  result["wrap"] = jbool(not node["wordWrap"].isFalse)
  result["padding"] = jnum(if node.nul("textPadding"): 9.0 else: jsMax(0, node.nor("textPadding", 0)))
  if overrides.isObj: assign(result, overrides)

proc drawFoldingBadge(ctx: Ctx, node: Val) =
  let size = 9.0
  let x = nodeX(node) + 4
  let y = nodeY(node) + 4
  ctx.save()
  ctx.globalAlpha = 1
  ctx.fillStyle = "#ffffff"
  ctx.strokeStyle = "#7b8494"
  ctx.lineWidth = 1
  ctx.beginPath()
  ctx.rect(x + 0.5, y + 0.5, size, size)
  ctx.fill()
  ctx.stroke()
  ctx.beginPath()
  ctx.moveTo(x + 2, y + size / 2 + 0.5)
  ctx.lineTo(x + size - 1, y + size / 2 + 0.5)
  if node.tr("collapsed"):
    ctx.moveTo(x + size / 2 + 0.5, y + 2)
    ctx.lineTo(x + size / 2 + 0.5, y + size - 1)
  ctx.stroke()
  ctx.restore()

proc drawScriptBadge(ctx: Ctx, node: Val) =
  let size = 12.0
  let x = nodeX(node) + nodeW(node) - size - 4
  let y = nodeY(node) + 4
  ctx.save()
  ctx.globalAlpha = 1
  ctx.fillStyle = "#7c3aed"
  ctx.beginPath()
  ctx.arc(x + size / 2, y + size / 2, size / 2, 0, PI * 2)
  ctx.fill()
  ctx.fillStyle = "#ffffff"
  ctx.font = "bold 8px Arial, sans-serif"
  ctx.textAlign = "center"
  ctx.textBaseline = "middle"
  ctx.fillText("JS", x + size / 2, y + size / 2 + 0.5)
  ctx.restore()

proc drawNodeText*(p: ScenePainter, ctx: Ctx, node: Val) =
  let nodeOpacity = if node.nul("opacity"): 1.0 else: clamp(node.nm("opacity"), 0, 1)
  ctx.globalAlpha = nodeOpacity * (if node.nul("textOpacity"): 1.0 else: clamp(node.nm("textOpacity"), 0, 1))
  var bx = nodeX(node)
  var by = nodeY(node)
  var bw = nodeW(node)
  var bh = nodeH(node)
  if node.eqs("shape", "swimlane"):
    let header = clamp(node.nn("headerHeight", 26), 0,
                       if node["horizontal"].isFalse: nodeW(node) else: nodeH(node))
    if node["horizontal"].isFalse: bw = header
    else: bh = header

  let rich = node["richText"]
  if not nullish(rich):
    discard richtext.draw(ctx, rich, bx, by, bw, bh, textBase(node))
    return

  let fontSize = node.fo("fontSize", 14)
  let fontWeight = if node.tr("bold"): "700" else: node.so("fontWeight", "500")
  ctx.fillStyle = node.so("textColor", "#172033")
  ctx.font = (if node.tr("italic"): "italic " else: "") & fontWeight & " " &
    node.so("fontSize", "14") & "px " & node.so("fontFamily", "Arial, sans-serif")
  ctx.textAlign = node.so("textAlign", "center")
  ctx.textBaseline = "middle"
  let padding = if node.nul("textPadding"): 9.0 else: jsMax(0, node.nor("textPadding", 0))
  let text = node.so("text", "")
  let lines = if node["wordWrap"].isFalse: text.split('\n')
              else: wrapText(ctx, text, jsMax(10, bw - padding * 2))
  let lineHeight = fontSize * 1.25
  let vertical = node.so("verticalAlign", "middle")
  var startY = by + bh / 2 - float64(lines.len - 1) * lineHeight / 2
  if vertical == "top": startY = by + lineHeight
  if vertical == "bottom": startY = by + bh - float64(lines.len) * lineHeight + lineHeight / 2
  let align = ctx.textAlign
  let x = if align == "left": bx + padding
          elif align == "right": bx + bw - padding
          else: bx + bw / 2
  for i, line in lines:
    let baseline = startY + float64(i) * lineHeight
    ctx.fillText(line, x, baseline)
    if node.tr("underline") or node.tr("strikethrough"):
      let width = ctx.measureText(line)
      var lineX = x
      if align == "center": lineX -= width / 2
      if align == "right": lineX -= width
      let lineY = baseline + (if node.tr("strikethrough"): -fontSize * 0.05 else: fontSize * 0.55)
      ctx.beginPath()
      ctx.moveTo(lineX, lineY)
      ctx.lineTo(lineX + width, lineY)
      ctx.strokeStyle = node.so("textColor", "#172033")
      ctx.lineWidth = jsMax(1, fontSize / 14)
      ctx.stroke()

proc drawTableCells(p: ScenePainter, ctx: Ctx, node: Val) =
  let grid = tableGrid(node)
  let cells = node["cells"]

  if not node.nul("tableTitle") and grid.titleHeight > 0:
    let ov = newObj()
    ov["color"] = orV(node["textColor"], jstr("#172033"))
    ov["fontWeight"] = jnum(700)
    ov["align"] = jstr("center")
    ov["verticalAlign"] = jstr("middle")
    ov["padding"] = jnum(4)
    discard richtext.draw(ctx, fromPlainVal(node["tableTitle"]), nodeX(node), nodeY(node),
                          nodeW(node), grid.titleHeight, textBase(node, ov))

  for r in 0 ..< grid.rows.len:
    for c in 0 ..< grid.columns.len:
      let box = tableCellBox(node, float64(r), float64(c))
      if box.row != r or box.column != c: continue
      var cell = if cells.isObj: cells.get($r & "," & $c) else: nil
      if nullish(cell): cell = newObj()
      if cell.kind == vStr:
        let o = newObj()
        o["text"] = cell
        cell = o
      let content = cell["text"]
      let model = if cell.tr("richText"): cell["richText"] else: nil
      let header = if not cell.nul("header"): cell.tr("header")
                   else: (node.tr("headerRow") and r == 0) or
                         (node.tr("headerColumn") and c == 0)
      let ov = newObj()
      ov["color"] = orV(cell["textColor"], orV(node["textColor"], jstr("#172033")))
      ov["fontWeight"] = if cell.nul("fontWeight"):
                           (if header: jnum(700) else: orV(node["fontWeight"], jnum(500)))
                         else: cell["fontWeight"]
      ov["fontSize"] = orV(cell["fontSize"], orV(node["fontSize"], jnum(14)))
      ov["fontFamily"] = orV(cell["fontFamily"], orV(node["fontFamily"], jstr("Arial, sans-serif")))
      ov["italic"] = jbool(cell["italic"].isTrue)
      ov["underline"] = jbool(cell["underline"].isTrue)
      ov["strike"] = jbool(cell["strikethrough"].isTrue)
      ov["align"] = orV(cell["align"], orV(node["cellAlign"], jstr("center")))
      ov["verticalAlign"] = orV(cell["verticalAlign"], jstr("middle"))
      ov["wrap"] = jbool(not cell["wordWrap"].isFalse)
      ov["padding"] = jnum(if cell.nul("textPadding"):
                             (if node.nul("tableCellPadding"): 5.0 else: node.nm("tableCellPadding"))
                           else: cell.nm("textPadding"))
      let base = textBase(node, ov)

      var cellFill = cell["fill"]
      if not truthy(cellFill):
        cellFill = if header: node["headerFill"] else: jfalse
      if truthy(cellFill) and not isStrVal(cellFill, "none"):
        ctx.save()
        ctx.globalAlpha = ctx.globalAlpha * (if cell.nul("opacity"): 1.0 else: clamp(cell.nm("opacity"), 0, 1))
        ctx.fillStyle = str(cellFill)
        let tb = node["tableBorder"]
        let inset = if tb.isNum and tb.n == 0: 0.0
                    else: jsMax(0.5, node.nor("strokeWidth", 1)) / 2
        ctx.fillRect(box.x + inset, box.y + inset, jsMax(0, box.width - inset * 2),
                     jsMax(0, box.height - inset * 2))
        ctx.restore()

      if cell.tr("stroke") and not cell.eqs("stroke", "none"):
        ctx.save()
        ctx.strokeStyle = str(cell["stroke"])
        ctx.lineWidth = cell.nn("strokeWidth", 1)
        if cell.tr("dashed"):
          let dp = cell["dashPattern"]
          if dp.isArr:
            var d: seq[float64]
            for v in dp: d.add num(v)
            ctx.setLineDash(d)
          else: ctx.setLineDash([3.0, 3.0])
        ctx.strokeRect(box.x, box.y, box.width, box.height)
        ctx.restore()

      if model == nil and (nullish(content) or isStrVal(content, "")): continue
      ctx.save()
      ctx.globalAlpha = ctx.globalAlpha * (if cell.nul("textOpacity"): 1.0 else: clamp(cell.nm("textOpacity"), 0, 1))
      discard richtext.draw(ctx, (if model != nil: model else: fromPlainVal(content)),
                            box.x, box.y, box.width, box.height, base)
      ctx.restore()

  if node.tr("text"): p.drawNodeText(ctx, node)

proc drawTaskList(p: ScenePainter, ctx: Ctx, node: Val) =
  let headerHeight = node.fo("headerHeight", 28)
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  ctx.beginPath()
  ctx.moveTo(x, y + headerHeight)
  ctx.lineTo(x + w, y + headerHeight)
  ctx.strokeStyle = node.so("stroke", "#4a5564")
  ctx.lineWidth = 1
  ctx.stroke()
  ctx.fillStyle = node.so("textColor", "#172033")
  ctx.font = "600 " & node.so("fontSize", "14") & "px Arial, sans-serif"
  ctx.textAlign = "center"
  ctx.textBaseline = "middle"
  ctx.fillText(if node.nul("text"): "Task Masterlist" else: str(node["text"]), x + w / 2, y + headerHeight / 2)
  let tasks = node["tasks"]
  let count = tasks.len
  let rowHeight = (h - headerHeight) / float64(max(1, count))
  ctx.font = "13px Arial, sans-serif"
  ctx.textAlign = "left"
  for i in 0 ..< count:
    let cy = y + headerHeight + rowHeight * float64(i) + rowHeight / 2
    ctx.beginPath()
    ctx.arc(x + 10, cy, 5, 0, PI * 2)
    let task = tasks[i]
    ctx.fillStyle = if truthy(task) and task.tr("done"): "#22a06b" else: "#111111"
    ctx.fill()
    ctx.fillStyle = node.so("textColor", "#172033")
    let taskText = if task.isStr: task elif truthy(task): task["text"] else: nil
    ctx.fillText(if nullish(taskText): "" else: str(taskText), x + 22, cy)

# ------------------------------------------------------- script blocks --

const scriptMono = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"

proc ellipsize(ctx: Ctx, text: string, maxWidth: float64): string =
  if maxWidth <= 0: return ""
  if ctx.measureText(text) <= maxWidth: return text
  result = text
  while result.len > 0 and ctx.measureText(result & "…") > maxWidth:
    result.setLen(result.len - 1)
    while result.len > 0 and (ord(result[^1]) and 0xC0) == 0x80: result.setLen(result.len - 1)
    if result.len > 0 and ord(result[^1]) >= 0xC0: result.setLen(result.len - 1)
  result &= "…"

proc drawVisualScript(p: ScenePainter, ctx: Ctx, node: Val) =
  ## A script block: a coloured title bar, what the block does, and the
  ## output or error of the last run.
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  let accent = node.so("stroke", "#6366f1")
  let header = jsMin(26, h)
  ctx.save()
  p.traceNode(ctx, node)
  ctx.clip()
  ctx.fillStyle = accent
  ctx.fillRect(x, y, w, header)
  ctx.restore()

  ctx.save()
  ctx.textBaseline = "middle"
  ctx.textAlign = "left"
  ctx.fillStyle = "#ffffff"
  ctx.font = "700 12px Inter, Arial, sans-serif"
  let tag = node.so("vsType", "script").toUpperAscii
  ctx.font = "700 9px Inter, Arial, sans-serif"
  let tagWidth = ctx.measureText(tag)
  let showTag = tagWidth + 44 < w
  if showTag:
    ctx.globalAlpha = 0.75
    ctx.fillText(tag, x + w - 8 - tagWidth, y + header / 2 + 0.5)
    ctx.globalAlpha = 1
  ctx.font = "700 12px Inter, Arial, sans-serif"
  let titleRoom = w - 18 - (if showTag: tagWidth + 10 else: 0.0)
  ctx.fillText(ellipsize(ctx, node.so("text", "Script"), titleRoom), x + 9, y + header / 2 + 0.5)

  # Output of the last run, pinned to the bottom.
  let error = scriptField(node, "lastError")
  let output = scriptField(node, "lastResult")
  if error.len > 0 or output.len > 0:
    # A ring on the block itself, not just its output box, so the last run's
    # outcome reads at a glance even when the block is small or zoomed out.
    ctx.save()
    p.traceNode(ctx, node)
    ctx.lineWidth = 2.5
    ctx.strokeStyle = if error.len > 0: "#ef4444" else: "#22c55e"
    ctx.stroke()
    ctx.restore()
  var bodyBottom = y + h - 6
  if error.len > 0 or output.len > 0:
    let isError = error.len > 0
    ctx.font = "11px " & scriptMono
    let lines = wrapText(ctx, (if isError: "⚠ " & error else: output), w - 24)
    let available = int((h - header - 30) / 14)
    let shown = max(1, min(lines.len, max(1, available)))
    let boxH = float64(shown) * 14 + 8
    let boxY = y + h - boxH - 6
    roundedRect(ctx, x + 6, boxY, w - 12, boxH, 5)
    ctx.fillStyle = if isError: "#fef2f2" else: "#f0fdf4"
    ctx.fill()
    ctx.fillStyle = if isError: "#b91c1c" else: "#166534"
    for i in 0 ..< shown:
      var line = lines[i]
      if i == shown - 1 and shown < lines.len: line &= " …"
      ctx.fillText(ellipsize(ctx, line, w - 24), x + 12, boxY + 11 + float64(i) * 14)
    bodyBottom = boxY - 2

  var rowY = y + header + 13
  for (caption, value) in scriptRows(node):
    if rowY + 5 > bodyBottom: break
    if caption.len > 0:
      ctx.font = "600 9px Inter, Arial, sans-serif"
      ctx.fillStyle = "#94a3b8"
      let cap = caption.toUpperAscii
      ctx.fillText(cap, x + 9, rowY)
      let capWidth = ctx.measureText(cap) + 6
      ctx.font = "11px " & scriptMono
      ctx.fillStyle = "#334155"
      ctx.fillText(ellipsize(ctx, value, w - 18 - capWidth), x + 9 + capWidth, rowY)
    else:
      ctx.font = "11px " & scriptMono
      ctx.fillStyle = "#1e293b"
      ctx.fillText(ellipsize(ctx, value, w - 18), x + 9, rowY)
    rowY += 15
  if node.tr("portsEnabled"):
    # Each socket sits beside the row that already shows its variable (the
    # caption/value text above), rather than at a generic, content-blind
    # position -- see geometry.nim's portYFraction, the single place both
    # this drawing and the click/drag hit-testing agree on where a socket is.
    # A two-way field's input and output variants share one point (see
    # portXFraction) -- draw it once, not twice.
    var drawnKeys: HashSet[string]
    for port in variablePorts(node):
      if drawnKeys.containsOrIncl(scriptPortKey(node, port.name)): continue
      let entries = portLabels(node, port.direction)
      let px = x + portXFraction(node, port.direction, port.index, entries) * w
      let py = y + portYFraction(node, port.direction, port.index, entries) * h
      drawPortDot(ctx, px, py, "#64748b")
  ctx.restore()

proc drawNode*(p: ScenePainter, ctx: Ctx, node: Val) =
  let center = nodeCenter(node)
  ctx.save()
  ctx.translate(center.x, center.y)
  ctx.rotate(rot(node) * PI / 180)
  ctx.scale(if node.tr("flipH"): -1.0 else: 1.0, if node.tr("flipV"): -1.0 else: 1.0)
  ctx.translate(-center.x, -center.y)
  ctx.globalAlpha = if node.nul("opacity"): 1.0 else: clamp(node.nm("opacity"), 0, 1)

  let fill = node.so("fill", "#ffffff")
  let stroke = node.so("stroke", "#4a5564")
  let lineWidth = node.nn("strokeWidth", 1.5)

  if node.eqs("shape", "stencil"):
    var paint = Paint(fill: fill, stroke: stroke, strokeWidth: lineWidth,
                      alpha: ctx.globalAlpha)
    let tc = node["textColor"]
    if truthy(tc):
      paint.textColor = str(tc)
      paint.hasTextColor = true
    if node.tr("dashed"):
      paint.dash = dashPattern(node)
      paint.hasDash = true
    if stencils.draw(ctx, textOf(node["stencil"]), nodeX(node), nodeY(node),
                     nodeW(node), nodeH(node), paint):
      p.drawNodeText(ctx, node)
      ctx.restore()
      return

  p.traceNode(ctx, node)
  if node.tr("shadow"):
    ctx.shadowColor = "rgba(15, 23, 42, 0.22)"
    ctx.shadowBlur = 8
    ctx.shadowOffsetY = 3
  applyNodeFill(ctx, node, fill)
  if not isStrokeOnly(node["shape"]): ctx.fill()
  ctx.shadowColor = "transparent"

  if node.eqs("shape", "image"):
    ctx.save()
    ctx.clip()
    if mediaHook != nil: mediaHook(ctx, node)
    else: ctx.media(mediaJson(node))
    ctx.restore()
    p.traceNode(ctx, node)

  ctx.strokeStyle = stroke
  ctx.lineWidth = lineWidth
  if node.tr("dashed"): ctx.setLineDash(dashPattern(node))
  if not node.eqs("shape", "text") and not node.eqs("shape", "partialRectangle") and
      not node.eqs("shape", "parallelMarker"):
    ctx.stroke()
  ctx.setLineDash([])
  p.drawNodeDecorations(ctx, node)

  if node.tr("collapsible"): drawFoldingBadge(ctx, node)
  if node.tr("cscript"): drawScriptBadge(ctx, node)

  if node.eqs("kind", "taskList"): p.drawTaskList(ctx, node)
  elif node.eqs("kind", "visualScript"): p.drawVisualScript(ctx, node)
  elif node.eqs("shape", "table"): p.drawTableCells(ctx, node)
  else: p.drawNodeText(ctx, node)
  if node.tr("portsEnabled") and not node.eqs("kind", "visualScript"):
    # Script blocks draw their own sockets, glued to the row that shows the
    # variable (see drawVisualScript) -- this generic even-spaced layout with
    # a floating name label is for a plain shape with ports turned on from
    # the Style inspector, which has no such rows to align to.
    ctx.font = "11px Arial, sans-serif"
    ctx.textBaseline = "middle"
    for port in variablePorts(node):
      let entries = portLabels(node, port.direction)
      let x = nodeX(node) + portXFraction(node, port.direction, port.index, entries) * nodeW(node)
      let y = nodeY(node) + portYFraction(node, port.direction, port.index, entries) * nodeH(node)
      drawPortDot(ctx, x, y, portTypeColor(port.dataType))
      ctx.fillStyle = node.so("textColor", "#172033")
      ctx.textAlign = if port.direction == "input": "left" else: "right"
      ctx.fillText(port.name, x + (if port.direction == "input": 12.0 else: -12.0), y)
  ctx.restore()

# -------------------------------------------------------------- render --

proc renderInto*(p: ScenePainter, ctx: Ctx, view: Val): RenderStats =
  ## Paints one frame into `ctx` (freshly reset by the caller). The page sizes
  ## the canvas from the returned pixel dimensions before replaying.
  let dpr = clamp(view.fo("dpr", 1), 1, 2)
  let pixelWidth = max(1, int(floor(view.nm("width") * dpr)))
  let pixelHeight = max(1, int(floor(view.nm("height") * dpr)))
  let zoom = view.nm("zoom")
  let pageView = view.tr("pageView")

  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.fillStyle = if pageView: "#d9dde3" else: view.so("background", "#ffffff")
  ctx.fillRect(0, 0, float64(pixelWidth), float64(pixelHeight))
  ctx.setTransform(dpr * zoom, 0, 0, dpr * zoom, -view.nm("scrollX") * dpr, -view.nm("scrollY") * dpr)

  if pageView:
    let pageWidth = view.fo("pageWidth", 827)
    let pageHeight = view.fo("pageHeight", 1169)
    let columns = max(1.0, view.nor("pageColumns", 1))
    let rows = max(1.0, view.nor("pageRows", 1))
    let pageStartX = view.fo("pageStartColumn", 0) * pageWidth
    let pageStartY = view.fo("pageStartRow", 0) * pageHeight
    let paperWidth = pageWidth * columns
    let paperHeight = pageHeight * rows
    ctx.save()
    ctx.shadowColor = "rgba(15, 23, 42, .24)"
    ctx.shadowBlur = 12 / max(0.2, zoom)
    ctx.shadowOffsetY = 4 / max(0.2, zoom)
    ctx.fillStyle = view.so("background", "#ffffff")
    ctx.fillRect(pageStartX, pageStartY, paperWidth, paperHeight)
    ctx.restore()

    ctx.save()
    ctx.strokeStyle = "#c7ccd4"
    ctx.lineWidth = 1 / max(0.2, zoom)
    ctx.strokeRect(pageStartX, pageStartY, paperWidth, paperHeight)
    ctx.beginPath()
    var column = 1.0
    while column < columns:
      let pageX = pageStartX + column * pageWidth
      ctx.moveTo(pageX, pageStartY)
      ctx.lineTo(pageX, pageStartY + paperHeight)
      column += 1
    var row = 1.0
    while row < rows:
      let pageY = pageStartY + row * pageHeight
      ctx.moveTo(pageStartX, pageY)
      ctx.lineTo(pageStartX + paperWidth, pageY)
      row += 1
    ctx.stroke()
    ctx.restore()

  if not view["grid"].isFalse: p.drawGrid(ctx, view)

  let visible = p.getVisibleItems(view)
  for item in visible:
    if item.eqs("type", "edge"): p.drawEdge(ctx, item)
    else: p.drawNode(ctx, item)

  ctx.setTransform(1, 0, 0, 1, 0, 0)
  RenderStats(visible: visible.len, total: p.items.len,
              pixelWidth: pixelWidth, pixelHeight: pixelHeight)

proc render*(p: ScenePainter, view: Val): RenderStats =
  p.ctx.reset()
  result = p.renderInto(p.ctx, view)
  p.ctx.finish()

proc drawList*(p: ScenePainter, items: openArray[Val]) =
  ## Draws the given items, in order, under whatever transform the page has
  ## set on its context (the outline view).
  p.ctx.reset()
  for item in items:
    if item.eqs("type", "edge"): p.drawEdge(p.ctx, item)
    else: p.drawNode(p.ctx, item)
  p.ctx.finish()
