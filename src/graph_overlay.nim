# Included from graph.nim: the interaction overlay (selection frames,
# handles, connection previews, guides, marquee), drawn into its own
# command list and replayed by the page onto the transparent overlay canvas.

proc drawRoundHandle(g: Graph, ctx: Ctx, p: Pt, fill: string, radius: float64) =
  ctx.beginPath()
  ctx.arc(p.x, p.y, radius, 0, PI * 2)
  ctx.fillStyle = fill
  ctx.fill()
  ctx.strokeStyle = "#ffffff"
  ctx.lineWidth = 1.2 / g.zoom
  ctx.stroke()

proc drawEdgeHandle(g: Graph, ctx: Ctx, p: Pt, fill: string, opacity = 1.0) =
  let size = 6 / g.zoom
  ctx.save()
  ctx.globalAlpha = opacity
  ctx.fillStyle = fill
  ctx.strokeStyle = "#000000"
  ctx.lineWidth = 1 / g.zoom
  ctx.beginPath()
  ctx.rect(p.x - size / 2, p.y - size / 2, size, size)
  ctx.fill()
  ctx.stroke()
  ctx.restore()

proc drawCustomHandle(g: Graph, ctx: Ctx, p: Pt) =
  let size = 6 / g.zoom
  ctx.save()
  ctx.translate(p.x, p.y)
  ctx.rotate(PI / 4)
  ctx.fillStyle = "#ffc400"
  ctx.strokeStyle = "#ffffff"
  ctx.lineWidth = 1.2 / g.zoom
  ctx.fillRect(-size / 2, -size / 2, size, size)
  ctx.strokeRect(-size / 2, -size / 2, size, size)
  ctx.restore()

proc drawRotationHandle(g: Graph, ctx: Ctx, p: Pt) =
  let radius = 8 / g.zoom
  ctx.save()
  ctx.strokeStyle = "#29b6f2"
  ctx.fillStyle = "#29b6f2"
  ctx.lineWidth = 2 / g.zoom
  ctx.beginPath()
  ctx.arc(p.x, p.y, radius * 0.62, -PI * 0.2, PI * 1.45)
  ctx.stroke()
  let angle = -PI * 0.2
  let tip = pt(p.x + cos(angle) * radius * 0.62, p.y + sin(angle) * radius * 0.62)
  ctx.beginPath()
  ctx.moveTo(tip.x, tip.y)
  ctx.lineTo(tip.x - 5 / g.zoom, tip.y - 1 / g.zoom)
  ctx.lineTo(tip.x - 1 / g.zoom, tip.y + 5 / g.zoom)
  ctx.closePath()
  ctx.fill()
  ctx.restore()

proc drawCornerPath(ctx: Ctx, corners: openArray[Pt]) =
  ctx.beginPath()
  ctx.moveTo(corners[0].x, corners[0].y)
  for i in 1 ..< corners.len: ctx.lineTo(corners[i].x, corners[i].y)
  ctx.closePath()

proc drawReplaceTarget(g: Graph, ctx: Ctx, target: ReplaceTarget) =
  let radius = target.radius
  let scale = radius / 13
  let glyph = 6 * scale
  let start = -PI * 0.7
  ctx.save()
  ctx.beginPath()
  ctx.arc(target.center.x, target.center.y, radius, 0, PI * 2)
  ctx.fillStyle = if target.hot: "#29b6f2" else: "rgba(255, 255, 255, 0.94)"
  ctx.fill()
  ctx.lineWidth = 1.5 / g.zoom
  ctx.strokeStyle = "#29b6f2"
  ctx.stroke()
  ctx.strokeStyle = if target.hot: "#ffffff" else: "#29b6f2"
  ctx.fillStyle = ctx.strokeStyle
  ctx.lineWidth = 1.8 / g.zoom
  ctx.beginPath()
  ctx.arc(target.center.x, target.center.y, glyph, start, PI * 0.95)
  ctx.stroke()
  let tip = pt(target.center.x + glyph * cos(start), target.center.y + glyph * sin(start))
  let tangent = pt(sin(start), -cos(start))
  let normal = pt(cos(start), sin(start))
  let head = 4 * scale
  ctx.beginPath()
  ctx.moveTo(tip.x + tangent.x * head, tip.y + tangent.y * head)
  ctx.lineTo(tip.x - normal.x * head * 0.8, tip.y - normal.y * head * 0.8)
  ctx.lineTo(tip.x + normal.x * head * 0.8, tip.y + normal.y * head * 0.8)
  ctx.closePath()
  ctx.fill()
  ctx.restore()

proc drawContainerTarget(g: Graph, ctx: Ctx, node: Val) =
  let corners = nodeCorners(node)
  ctx.save()
  ctx.fillStyle = "rgba(34, 160, 107, 0.10)"
  ctx.strokeStyle = "#22a06b"
  ctx.lineWidth = 3 / g.zoom
  ctx.setLineDash([7 / g.zoom, 4 / g.zoom])
  drawCornerPath(ctx, corners)
  ctx.fill()
  ctx.stroke()
  ctx.restore()

proc drawSelectedGroup(g: Graph, ctx: Ctx, group: GroupInfo, controls: bool) =
  let frame = g.groupFrame(group.bounds)
  ctx.save()
  ctx.strokeStyle = "rgba(0, 168, 255, 0.45)"
  ctx.lineWidth = 1 / g.zoom
  ctx.setLineDash([2 / g.zoom, 3 / g.zoom])
  for node in group.items:
    drawCornerPath(ctx, nodeCorners(node))
    ctx.stroke()
  ctx.strokeStyle = "#00a8ff"
  ctx.lineWidth = 2 / g.zoom
  ctx.setLineDash([7 / g.zoom, 4 / g.zoom])
  ctx.strokeRect(frame.x, frame.y, frame.width, frame.height)
  ctx.setLineDash([])
  if controls:
    for h in g.getGroupHandles(frame):
      if h.kind == "groupRotate": g.drawRotationHandle(ctx, h.point)
      else: g.drawRoundHandle(ctx, h.point, "#00a8ff", 5.5 / g.zoom)
  ctx.restore()

proc drawTableResizeHandles(g: Graph, ctx: Ctx, node: Val) =
  let handles = g.getTableResizeHandles(node)
  ctx.save()
  ctx.strokeStyle = "rgba(0, 168, 255, 0.72)"
  ctx.fillStyle = "#00a8ff"
  ctx.lineWidth = 1.5 / g.zoom
  for h in handles:
    ctx.beginPath()
    ctx.moveTo(h.fromP.x, h.fromP.y)
    ctx.lineTo(h.toP.x, h.toP.y)
    ctx.stroke()
    ctx.beginPath()
    ctx.arc(h.point.x, h.point.y, 4 / g.zoom, 0, PI * 2)
    ctx.fill()
    ctx.strokeStyle = "#ffffff"
    ctx.stroke()
    ctx.strokeStyle = "rgba(0, 168, 255, 0.72)"
  ctx.restore()

proc drawTableRowMoveHandles(g: Graph, ctx: Ctx, node: Val) =
  let handles = g.getTableRowMoveHandles(node)
  let halfWidth = 5.5 / g.zoom
  let halfHeight = 6 / g.zoom
  ctx.save()
  for h in handles:
    let p = h.point
    ctx.fillStyle = "#ffffff"
    ctx.strokeStyle = "#00a8ff"
    ctx.lineWidth = 1 / g.zoom
    ctx.fillRect(p.x - halfWidth, p.y - halfHeight, halfWidth * 2, halfHeight * 2)
    ctx.strokeRect(p.x - halfWidth, p.y - halfHeight, halfWidth * 2, halfHeight * 2)
    ctx.strokeStyle = "#4b5563"
    ctx.lineWidth = 1.25 / g.zoom
    for line in -1 .. 1:
      let y = p.y + float64(line) * 2.3 / g.zoom
      ctx.beginPath()
      ctx.moveTo(p.x - 3.5 / g.zoom, y)
      ctx.lineTo(p.x + 3.5 / g.zoom, y)
      ctx.stroke()
  ctx.restore()

proc drawPortArrows(g: Graph, ctx: Ctx, node: Val) =
  let ports = g.getPortArrows(node)
  let activeSide = if g.action != nil and g.action.kind == "connect": g.action.sourceSide else: "\0"
  if not node.tr("portsEnabled") and (g.connectionPoints or g.portMode == "outline"):
    let anchors = g.getConnectionAnchors(node)
    ctx.save()
    ctx.strokeStyle = "#00b8d9"
    ctx.lineWidth = 1.35 / g.zoom
    for a in anchors:
      let p = a.anchor
      let size = 2.7 / g.zoom
      ctx.beginPath()
      ctx.moveTo(p.x - size, p.y - size)
      ctx.lineTo(p.x + size, p.y + size)
      ctx.moveTo(p.x + size, p.y - size)
      ctx.lineTo(p.x - size, p.y + size)
      ctx.stroke()
    ctx.restore()
  for port in ports:
    if not g.connectionArrows or g.portMode == "outline": continue
    let angle = arctan2(port.point.y - port.anchor.y, port.point.x - port.anchor.x)
    let length = 20 / g.zoom
    let width = 11 / g.zoom
    ctx.save()
    ctx.translate(port.point.x, port.point.y)
    ctx.rotate(angle)
    ctx.beginPath()
    ctx.moveTo(length / 2, 0)
    ctx.lineTo(-length / 5, -width / 2)
    ctx.lineTo(-length / 5, -width / 4)
    ctx.lineTo(-length / 2, -width / 4)
    ctx.lineTo(-length / 2, width / 4)
    ctx.lineTo(-length / 5, width / 4)
    ctx.lineTo(-length / 5, width / 2)
    ctx.closePath()
    ctx.fillStyle = if activeSide == port.side: "#29b6f2" else: "rgba(41,182,242,0.22)"
    ctx.fill()
    ctx.restore()

proc drawSelectedNode(g: Graph, ctx: Ctx, node: Val, controls: bool) =
  let center = nodeCenter(node)
  ctx.save()
  ctx.strokeStyle = "#00a8ff"
  ctx.lineWidth = 1.5 / g.zoom
  ctx.setLineDash([4 / g.zoom, 4 / g.zoom])
  drawCornerPath(ctx, nodeCorners(node))
  ctx.stroke()
  ctx.setLineDash([])
  if controls and not node.tr("locked"):
    for h in g.getNodeHandles(node):
      if h.kind == "rotate": g.drawRotationHandle(ctx, h.point)
      else: g.drawRoundHandle(ctx, h.point, "#29b6f2", 5.5 / g.zoom)
    for h in g.getCustomHandles(node): g.drawCustomHandle(ctx, h.point)
    if node.eqs("shape", "table"):
      g.drawTableResizeHandles(ctx, node)
      g.drawTableRowMoveHandles(ctx, node)
    if g.action == nil and not node["connectable"].isFalse and not node.tr("portsEnabled"):
      g.drawPortArrows(ctx, node)
  elif node.tr("locked"):
    ctx.fillStyle = "#4b5563"
    ctx.font = jsNumStr(13 / g.zoom) & "px Arial, sans-serif"
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    ctx.fillText("\xF0\x9F\x94\x92", center.x, nodeY(node) - 12 / g.zoom)
  ctx.restore()

proc drawSelectedTableCell(g: Graph, ctx: Ctx, sel: SelectedCell) =
  let node = sel.node
  let center = nodeCenter(node)
  let raw = [pt(sel.x, sel.y), pt(sel.x + sel.width, sel.y),
             pt(sel.x + sel.width, sel.y + sel.height), pt(sel.x, sel.y + sel.height)]
  var corners: array[4, Pt]
  for i in 0 .. 3: corners[i] = rotatePoint(raw[i], center, rot(node))
  ctx.save()
  ctx.fillStyle = "rgba(0, 168, 255, 0.06)"
  ctx.strokeStyle = "#00a8ff"
  ctx.lineWidth = 2 / g.zoom
  ctx.setLineDash([5 / g.zoom, 3 / g.zoom])
  drawCornerPath(ctx, corners)
  ctx.fill()
  ctx.stroke()
  ctx.setLineDash([])
  for c in corners:
    ctx.fillStyle = "#00a8ff"
    ctx.fillRect(c.x - 3 / g.zoom, c.y - 3 / g.zoom, 6 / g.zoom, 6 / g.zoom)
    ctx.strokeStyle = "#ffffff"
    ctx.lineWidth = 1 / g.zoom
    ctx.strokeRect(c.x - 3 / g.zoom, c.y - 3 / g.zoom, 6 / g.zoom, 6 / g.zoom)
  ctx.restore()

proc drawConnectionTarget(g: Graph, ctx: Ctx, node: Val, anchor: Val, side: string) =
  if node == nil: return
  let anchors = g.getConnectionAnchors(node)
  let hasActive = truthy(anchor)
  let active = if hasActive: nodeAnchor(node, anchor, side) else: Pt()
  ctx.save()
  ctx.strokeStyle = "#00a8ff"
  ctx.fillStyle = "rgba(0,168,255,0.12)"
  ctx.lineWidth = 2 / g.zoom
  drawCornerPath(ctx, nodeCorners(node))
  ctx.fill()
  ctx.stroke()
  if g.connectionPoints:
    ctx.lineWidth = 1.35 / g.zoom
    for a in anchors:
      let p = a.anchor
      let size = 2.7 / g.zoom
      ctx.beginPath()
      ctx.moveTo(p.x - size, p.y - size)
      ctx.lineTo(p.x + size, p.y + size)
      ctx.moveTo(p.x + size, p.y - size)
      ctx.lineTo(p.x - size, p.y + size)
      ctx.stroke()
  if hasActive:
    ctx.beginPath()
    ctx.arc(active.x, active.y, 6 / g.zoom, 0, PI * 2)
    ctx.fillStyle = "#00a8ff"
    ctx.fill()
    ctx.strokeStyle = "#ffffff"
    ctx.lineWidth = 1.5 / g.zoom
    ctx.stroke()
  ctx.restore()

proc drawGuides(g: Graph, ctx: Ctx) =
  if not g.guidesEnabled or g.action == nil: return
  let view = g.getViewState()
  ctx.save()
  ctx.strokeStyle = "#ff2a8b"
  ctx.lineWidth = 1 / g.zoom
  ctx.setLineDash([4 / g.zoom, 3 / g.zoom])
  let zoom = view.nm("zoom")
  if g.action.hasGuideX:
    ctx.beginPath()
    ctx.moveTo(g.action.guideX, view.nm("scrollY") / zoom)
    ctx.lineTo(g.action.guideX, (view.nm("scrollY") + view.nm("height")) / zoom)
    ctx.stroke()
  if g.action.hasGuideY:
    ctx.beginPath()
    ctx.moveTo(view.nm("scrollX") / zoom, g.action.guideY)
    ctx.lineTo((view.nm("scrollX") + view.nm("width")) / zoom, g.action.guideY)
    ctx.stroke()
  ctx.restore()

proc drawSelectedEdge(g: Graph, ctx: Ctx, edge: Val) =
  let points = edgePoints(edge, g.byId)
  if points.len < 2: return
  if isSocketWire(edge):
    # Selected dataflow wires stay curved and handle-free. Follow the same
    # cubic as painter.drawPortWire instead of the saved orthogonal route.
    let p0 = points[0]
    let p3 = points[^1]
    let pull = jsMax(40.0, abs(p3.x - p0.x) * 0.5)
    ctx.save()
    ctx.beginPath()
    ctx.moveTo(p0.x, p0.y)
    ctx.bezierCurveTo(p0.x + pull, p0.y, p3.x - pull, p3.y, p3.x, p3.y)
    ctx.strokeStyle = "#9f1239"
    ctx.lineWidth = 3 / g.zoom
    ctx.lineCap = "round"
    ctx.stroke()
    ctx.restore()
    return
  let circular = if edge.eqs("lineStyle", "circular"): circularArc(edge, g.byId) else: CircArc()
  ctx.save()
  ctx.beginPath()
  if circular.valid:
    ctx.moveTo(circular.samples[0].x, circular.samples[0].y)
    ctx.arc(circular.center.x, circular.center.y, circular.radius,
            circular.startAngle, circular.endAngle, circular.anticlockwise)
  else:
    ctx.moveTo(points[0].x, points[0].y)
    for i in 1 ..< points.len: ctx.lineTo(points[i].x, points[i].y)
  ctx.strokeStyle = "#00a8ff"
  ctx.lineWidth = 2.5 / g.zoom
  ctx.setLineDash([5 / g.zoom, 4 / g.zoom])
  ctx.stroke()
  ctx.setLineDash([])
  for h in g.getEdgeHandles(edge):
    case h.kind
    of "virtual": g.drawEdgeHandle(ctx, h.point, "#0000ff", 0.2)
    of "waypoint": g.drawEdgeHandle(ctx, h.point, "#00ff00")
    of "segment": g.drawEdgeHandle(ctx, h.point, "#0000ff", if h.virtual: 0.2 else: 1.0)
    of "arcSweep", "circleRadius": g.drawEdgeHandle(ctx, h.point, "#ffb000")
    else: g.drawEdgeHandle(ctx, h.point, "#0000ff")
  ctx.restore()

proc drawConnectionPreview(g: Graph, ctx: Ctx) =
  let action = g.action
  if action == nil: return
  let target = if action.targetId.len > 0: g.byId.getOrDefault(action.targetId, nil) else: nil
  var points: seq[Pt]
  var circularPreview: CircArc
  if action.kind == "connect":
    let source = g.byId.getOrDefault(action.sourceId, nil)
    if source == nil: return
    let preview = obj(("id", jstr("preview")), ("type", jstr("edge")), ("sourceId", jstr(action.sourceId)),
      ("targetId", if action.targetId.len > 0: jstr(action.targetId) else: jnull),
      ("sourceSide", jstr(action.sourceSide)),
      ("targetSide", if action.targetSide.len > 0: jstr(action.targetSide) else: jnull),
      ("sourceAnchor", if action.sourceAnchor == nil: jnull else: action.sourceAnchor),
      ("targetAnchor", if action.targetAnchor == nil: jnull else: action.targetAnchor),
      ("lineStyle", jstr("straight")))
    assign(preview, clone(if truthy(g.defaultEdgeStyle): g.defaultEdgeStyle else: newObj()))
    if target == nil: preview["targetPoint"] = ptVal(action.current)
    points = edgePoints(preview, g.byId)
    if preview.eqs("lineStyle", "circular"):
      circularPreview = circularArc(preview, g.byId)
      if circularPreview.valid: points = circularPreview.samples
  elif action.kind == "reconnect":
    let edge = g.byId.getOrDefault(action.itemId, nil)
    if edge == nil: return
    let temp = clone(edge)
    if target != nil:
      if action.terminal == "source":
        temp["sourceId"] = jstr(action.targetId)
        temp["sourceSide"] = if action.targetSide.len > 0: jstr(action.targetSide) else: jnull
        temp["sourceAnchor"] = if action.targetAnchor == nil: jnull else: action.targetAnchor
      else:
        temp["targetId"] = jstr(action.targetId)
        temp["targetSide"] = if action.targetSide.len > 0: jstr(action.targetSide) else: jnull
        temp["targetAnchor"] = if action.targetAnchor == nil: jnull else: action.targetAnchor
    else:
      if action.terminal == "source":
        temp["sourceId"] = jnull
        temp["sourceAnchor"] = jnull
        temp["sourcePoint"] = ptVal(action.current)
      else:
        temp["targetId"] = jnull
        temp["targetAnchor"] = jnull
        temp["targetPoint"] = ptVal(action.current)
    points = edgePoints(temp, g.byId)
    if temp.eqs("lineStyle", "circular"): circularPreview = circularArc(temp, g.byId)
    if circularPreview.valid: points = circularPreview.samples
  if points.len < 2: return
  ctx.save()
  ctx.beginPath()
  ctx.moveTo(points[0].x, points[0].y)
  if circularPreview.valid:
    ctx.arc(circularPreview.center.x, circularPreview.center.y, circularPreview.radius,
            circularPreview.startAngle, circularPreview.endAngle, circularPreview.anticlockwise)
  else:
    for i in 1 ..< points.len: ctx.lineTo(points[i].x, points[i].y)
  ctx.strokeStyle = if target != nil: "#22a06b" else: "#29b6f2"
  ctx.lineWidth = 2 / g.zoom
  ctx.setLineDash([6 / g.zoom, 4 / g.zoom])
  ctx.stroke()
  ctx.setLineDash([])
  let movingPoint = if action.kind == "reconnect" and action.terminal == "source": points[0] else: points[^1]
  g.drawRoundHandle(ctx, movingPoint, if target != nil: "#22a06b" else: "#29b6f2", 4.5 / g.zoom)
  ctx.restore()

proc drawMarquee(g: Graph, ctx: Ctx) =
  let a = g.action.startWorld
  let b = g.action.current
  let x = min(a.x, b.x)
  let y = min(a.y, b.y)
  ctx.save()
  ctx.fillStyle = "rgba(41,182,242,0.12)"
  ctx.strokeStyle = "#29b6f2"
  ctx.lineWidth = 1 / g.zoom
  ctx.fillRect(x, y, abs(a.x - b.x), abs(a.y - b.y))
  ctx.strokeRect(x, y, abs(a.x - b.x), abs(a.y - b.y))
  ctx.restore()

proc drawOverlay*(g: Graph) =
  if g.destroyed: return
  let view = g.getViewState()
  let ctx = g.overlay
  ctx.reset()
  let dpr = view.nm("dpr")
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.clearRect(0, 0, floor(view.nm("width") * dpr), floor(view.nm("height") * dpr))
  ctx.setTransform(dpr * g.zoom, 0, 0, dpr * g.zoom, -view.nm("scrollX") * dpr, -view.nm("scrollY") * dpr)

  let selected = g.getSelection()
  let groups = g.getSelectedGroups()
  var covered = initHashSet[string]()
  for grp in groups:
    for m in grp.items: covered.incl idOf(m)
  let soleGroup = groups.len == 1 and covered.len == selected.len

  for it in selected:
    if covered.contains(idOf(it)): continue
    let sel = g.getSelectedTableCell()
    if sel.found and sel.node == it: g.drawSelectedTableCell(ctx, sel)
    elif it.eqs("type", "edge"): g.drawSelectedEdge(ctx, it)
    else: g.drawSelectedNode(ctx, it, selected.len == 1 and groups.len == 0)

  for grp in groups: g.drawSelectedGroup(ctx, grp, soleGroup)

  let hovered = g.connectableNode(g.byId.getOrDefault(g.hoverId, nil))
  if g.action == nil and hovered != nil and not hovered.tr("locked") and
      not g.isSelected(idOf(hovered)) and not hovered["visible"].isFalse:
    g.drawPortArrows(ctx, hovered)

  if g.action != nil and g.action.kind == "move" and g.action.dropTargetId.len > 0:
    let containerTarget = g.byId.getOrDefault(g.action.dropTargetId, nil)
    if containerTarget != nil: g.drawContainerTarget(ctx, containerTarget)

  if g.replaceTarget.active and g.byId.hasKey(g.replaceTarget.id):
    g.drawReplaceTarget(ctx, g.replaceTarget)

  if g.action != nil and (g.action.kind == "connect" or g.action.kind == "reconnect"):
    if g.action.targetId.len > 0:
      g.drawConnectionTarget(ctx, g.byId.getOrDefault(g.action.targetId, nil),
                             g.action.targetAnchor, g.action.targetSide)
    g.drawConnectionPreview(ctx)
  if g.action != nil and g.action.kind == "marquee": g.drawMarquee(ctx)
  if g.action != nil and g.action.kind == "tableRowSwap":
    let swapNode = g.byId.getOrDefault(g.action.itemId, nil)
    if swapNode != nil:
      let grid = tableGrid(swapNode)
      let r = g.action.targetRow
      if r >= 0 and r < grid.rows.len:
        let row = grid.rows[r]
        ctx.save()
        ctx.fillStyle = "rgba(255, 176, 0, 0.16)"
        ctx.strokeStyle = "#ffb000"
        ctx.lineWidth = 2 / g.zoom
        ctx.fillRect(nodeX(swapNode), row.pos, nodeW(swapNode), row.size)
        ctx.strokeRect(nodeX(swapNode), row.pos, nodeW(swapNode), row.size)
        ctx.restore()
  if g.action != nil and g.action.kind == "move": g.drawGuides(ctx)
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.finish()
  currentCmd = addr ctx.buf
  if g.hooks.overlay != nil: g.hooks.overlay(ctx)
