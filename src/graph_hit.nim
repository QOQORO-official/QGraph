# Included from graph.nim: hit testing, outlines and connection anchors,
# connector targeting, connectVertex, and the handle generators.

proc getClickableLinkForCell(g: Graph, item: Val, screen: Pt, forced: bool): string =
  ## The link a plain click should follow ("" if none).
  if item == nil: return ""
  var href = item["link"]
  if item.eqs("shape", "table"):
    let (ok, cell) = g.tableCellAtWorld(item, g.eventWorld(screen))
    if ok:
      let cellLink = g.getCell(item, cell.row, cell.column)["link"]
      if truthy(cellLink): href = cellLink
  if not truthy(href): return ""
  if forced or item["locked"].isTrue or g.readOnly: return str(href)
  ""

proc pointInNode*(g: Graph, p: Pt, node: Val): bool =
  let center = nodeCenter(node)
  let local = rotatePoint(p, center, -rot(node))
  let hw = nodeW(node) / 2
  let hh = nodeH(node) / 2
  let nx = (local.x - center.x) / (if hw == 0 or hw != hw: 1.0 else: hw)
  let ny = (local.y - center.y) / (if hh == 0 or hh != hh: 1.0 else: hh)
  if node.eqs("shape", "ellipse"): return nx * nx + ny * ny <= 1
  if node.eqs("shape", "diamond"): return abs(nx) + abs(ny) <= 1
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  if node.eqs("shape", "triangle"):
    return pointInPolygon(local, [pt(x + w / 2, y), pt(x + w, y + h), pt(x, y + h)])
  if node.eqs("shape", "hexagon"):
    return pointInPolygon(local, [pt(x + w * 0.22, y), pt(x + w * 0.78, y), pt(x + w, y + h / 2),
                                  pt(x + w * 0.78, y + h), pt(x + w * 0.22, y + h), pt(x, y + h / 2)])
  if node.eqs("shape", "parallelogram"):
    return pointInPolygon(local, [pt(x + w * 0.18, y), pt(x + w, y), pt(x + w * 0.82, y + h), pt(x, y + h)])
  if node.eqs("shape", "trapezoid"):
    return pointInPolygon(local, [pt(x + w * 0.18, y), pt(x + w * 0.82, y), pt(x + w, y + h), pt(x, y + h)])
  local.x >= x and local.x <= x + w and local.y >= y and local.y <= y + h

proc compareHit(a, b: Val): int =
  ## Topmost first; nodes before edges at equal z; then id descending.
  let za = a.fo("z", 0)
  let zb = b.fo("z", 0)
  if za != zb: return (if zb - za < 0: -1 else: 1)
  if not strictEq(a["type"], b["type"]): return (if a.eqs("type", "node"): -1 else: 1)
  jsCompareStr(idOf(b), idOf(a))

proc hitTest*(g: Graph, p: Pt, ignoreId = ""): Val =
  let radius = 8 / g.zoom
  let ids = g.index.query(rect(p.x - radius, p.y - radius, radius * 2, radius * 2))
  var candidates: seq[Val]
  for id in ids:
    let item = g.byId.getOrDefault(id, nil)
    if item != nil and idOf(item) != ignoreId and not item["visible"].isFalse:
      candidates.add item
  candidates.sort(compareHit)
  for c in candidates:
    if c.tr("foldedAway") or g.isLayerLocked(c): continue
    let owner = g.getLayerOf(c)
    if owner != nil and owner["visible"].isFalse: continue
    if not c.eqs("type", "edge") and g.pointInNode(p, c): return c
    if c.eqs("type", "edge"):
      var points: seq[Pt]
      if c.eqs("lineStyle", "circular"):
        let arc = circularArc(c, g.byId)
        points = if arc.valid: arc.samples else: edgePoints(c, g.byId)
      else: points = edgePoints(c, g.byId)
      for i in 0 ..< points.len - 1:
        if distanceToSegment(p, points[i], points[i + 1]) <= radius: return c
  nil

proc nodeOutline(g: Graph, node: Val): seq[Pt] =
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  let shape = node.st("shape")
  if node["shape"].isStr:
    case shape
    of "diamond": return @[pt(x + w / 2, y), pt(x + w, y + h / 2), pt(x + w / 2, y + h), pt(x, y + h / 2)]
    of "triangle": return @[pt(x + w / 2, y), pt(x + w, y + h), pt(x, y + h)]
    of "hexagon":
      return @[pt(x + w * 0.22, y), pt(x + w * 0.78, y), pt(x + w, y + h / 2),
               pt(x + w * 0.78, y + h), pt(x + w * 0.22, y + h), pt(x, y + h / 2)]
    of "parallelogram": return @[pt(x + w * 0.18, y), pt(x + w, y), pt(x + w * 0.82, y + h), pt(x, y + h)]
    of "trapezoid": return @[pt(x + w * 0.18, y), pt(x + w * 0.82, y), pt(x + w, y + h), pt(x, y + h)]
    of "chevron", "step":
      return @[pt(x, y), pt(x + w * 0.72, y), pt(x + w, y + h / 2), pt(x + w * 0.72, y + h),
               pt(x, y + h), pt(x + w * 0.25, y + h / 2)]
    else: discard
  @[pt(x, y), pt(x + w, y), pt(x + w, y + h), pt(x, y + h)]

proc anchorSide(g: Graph, node: Val, nx0, ny0: float64): string =
  let x = clamp(nx0, 0, 1)
  let y = clamp(ny0, 0, 1)
  if node["shape"].isStr and node["shape"].s in ["ellipse", "diamond", "triangle", "hexagon",
                                                  "parallelogram", "trapezoid"]:
    let dx = x - 0.5
    let dy = y - 0.5
    if abs(dx) >= abs(dy): return (if dx >= 0: "east" else: "west")
    return (if dy >= 0: "south" else: "north")
  let d = [y, 1 - x, 1 - y, x]
  const names = ["north", "east", "south", "west"]
  var best = 0
  for i in 1 .. 3:
    if d[i] < d[best]: best = i
  names[best]

proc normalizedAnchor(g: Graph, node: Val, local: Pt): Val =
  let w = nodeW(node)
  let h = nodeH(node)
  var nx = if w != 0 and w == w: (local.x - nodeX(node)) / w else: 0.5
  var ny = if h != 0 and h == h: (local.y - nodeY(node)) / h else: 0.5
  nx = clamp(nx, 0, 1)
  ny = clamp(ny, 0, 1)
  obj(("x", jnum(nx)), ("y", jnum(ny)), ("side", jstr(g.anchorSide(node, nx, ny))))

proc nearestNodeAnchor(g: Graph, node: Val, world: Pt): AnchorInfo =
  let center = nodeCenter(node)
  let local = rotatePoint(world, center, -rot(node))
  var p: Pt
  if node.eqs("shape", "ellipse"):
    let rx = max(1e-6, nodeW(node) / 2)
    let ry = max(1e-6, nodeH(node) / 2)
    var dx = local.x - center.x
    let dy = local.y - center.y
    if abs(dx) + abs(dy) < 1e-9: dx = rx
    let factor = 1 / sqrt((dx * dx) / (rx * rx) + (dy * dy) / (ry * ry))
    p = pt(center.x + dx * factor, center.y + dy * factor)
  else:
    let outline = g.nodeOutline(node)
    var found = false
    var best: SegHit
    for i in 0 ..< outline.len:
      let c = closestPointOnSegment(local, outline[i], outline[(i + 1) mod outline.len])
      if not found or c.distance < best.distance:
        best = c
        found = true
    p = if found: best.point else: center
  let normalized = g.normalizedAnchor(node, p)
  let side = str(normalized["side"])
  let anchorWorld = nodeAnchor(node, normalized, side)
  AnchorInfo(found: true, node: node, anchor: normalized, side: side, point: anchorWorld,
             distance: hypot(world.x - anchorWorld.x, world.y - anchorWorld.y))

proc getConnectionAnchors(g: Graph, node: Val): seq[Handle] =
  ## Dense connection points around the outline (the classic X markers).
  if node.tr("portsEnabled"):
    for port in variablePorts(node):
      if port.direction == "input":
        result.add Handle(kind: "port", side: port.side, anchorSpec: port.anchor,
                          anchor: port.point, point: port.point, cursor: "crosshair")
    return
  var specs: seq[Handle]
  var seen = initHashSet[string]()
  proc push(localPoint: Pt) =
    let spec = g.normalizedAnchor(node, localPoint)
    let key = $int(jsRound(num(spec["x"]) * 1000)) & ":" & $int(jsRound(num(spec["y"]) * 1000))
    if seen.containsOrIncl(key): return
    let side = str(spec["side"])
    specs.add Handle(kind: "port", side: side, anchorSpec: spec,
                     anchor: nodeAnchor(node, spec, side), cursor: "crosshair")
  if node.eqs("shape", "ellipse"):
    for a in 0 ..< 16:
      let angle = -PI / 2 + float64(a) * PI * 2 / 16
      push(pt(nodeX(node) + nodeW(node) / 2 + cos(angle) * nodeW(node) / 2,
              nodeY(node) + nodeH(node) / 2 + sin(angle) * nodeH(node) / 2))
    return specs
  let outline = g.nodeOutline(node)
  for i in 0 ..< outline.len:
    let p0 = outline[i]
    let p1 = outline[(i + 1) mod outline.len]
    for step in 0 ..< 4:
      let t = float64(step) / 4
      push(pt(p0.x + (p1.x - p0.x) * t, p0.y + (p1.y - p0.y) * t))
  specs

proc closestCardinalAnchor(g: Graph, node: Val, p: Pt): AnchorInfo =
  const sides = ["north", "east", "south", "west"]
  for side in sides:
    let spec = anchorSpec(side)
    let world = nodeAnchor(node, spec, side)
    let distance = hypot(p.x - world.x, p.y - world.y)
    if not result.found or distance < result.distance:
      result = AnchorInfo(found: true, node: node, anchor: spec, side: side, point: world,
                          distance: distance, snapped: true, automaticMidpoint: true)

proc classicCardinalAnchor(g: Graph, node: Val, referencePoint: Pt, referenceSide: string,
                           hasReference: bool): AnchorInfo =
  if not hasReference or referenceSide.len == 0:
    return g.closestCardinalAnchor(node, if hasReference: referencePoint else: nodeCenter(node))
  let center = nodeCenter(node)
  let horizontal = referenceSide == "east" or referenceSide == "west"
  let tolerance = 6 / g.zoom
  var side: string
  if horizontal:
    side = if abs(referencePoint.y - center.y) <= tolerance:
             (if referencePoint.x <= center.x: "west" else: "east")
           else: (if referencePoint.y < center.y: "north" else: "south")
  else:
    side = if abs(referencePoint.x - center.x) <= tolerance:
             (if referencePoint.y <= center.y: "north" else: "south")
           else: (if referencePoint.x < center.x: "west" else: "east")
  let spec = anchorSpec(side)
  let p = nodeAnchor(node, spec, side)
  AnchorInfo(found: true, node: node, anchor: spec, side: side, point: p,
             distance: hypot(referencePoint.x - p.x, referencePoint.y - p.y),
             snapped: true, automaticMidpoint: true)

proc snappedNodeAnchor(g: Graph, node: Val, world: Pt, referencePoint: Pt,
                       referenceSide: string, hasReference: bool,
                       portDirection = "input"): AnchorInfo =
  if node.tr("portsEnabled"):
    for port in variablePorts(node):
      if port.direction != portDirection: continue
      let distance = hypot(world.x - port.point.x, world.y - port.point.y)
      if distance <= 14 / g.zoom and (not result.found or distance < result.distance):
        result = AnchorInfo(found: true, node: node, anchor: clone(port.anchor),
                            side: port.side, point: port.point, distance: distance,
                            snapped: true)
    return
  let outline = g.nearestNodeAnchor(node, world)
  let anchors = g.getConnectionAnchors(node)
  var best = -1
  var bestDistance = 0.0
  var bestPointer = -1
  var bestPointerDistance = 0.0
  for i, a in anchors:
    let distance = hypot(outline.point.x - a.anchor.x, outline.point.y - a.anchor.y)
    if best < 0 or distance < bestDistance:
      best = i
      bestDistance = distance
    let pointerDistance = hypot(world.x - a.anchor.x, world.y - a.anchor.y)
    if bestPointer < 0 or pointerDistance < bestPointerDistance:
      bestPointer = i
      bestPointerDistance = pointerDistance
  if bestPointer >= 0 and bestPointerDistance <= 8 / g.zoom:
    let c = anchors[bestPointer]
    return AnchorInfo(found: true, node: node, anchor: clone(c.anchorSpec), side: c.side,
                      point: c.anchor, distance: bestPointerDistance,
                      outlineDistance: outline.distance, hasOutlineDistance: true, snapped: true)
  if hasReference:
    var midpoint = g.classicCardinalAnchor(node, referencePoint, referenceSide, true)
    midpoint.outlineDistance = outline.distance
    midpoint.hasOutlineDistance = true
    return midpoint
  if best >= 0 and bestDistance <= 10 / g.zoom:
    let c = anchors[best]
    return AnchorInfo(found: true, node: node, anchor: clone(c.anchorSpec), side: c.side,
                      point: c.anchor, distance: hypot(world.x - c.anchor.x, world.y - c.anchor.y),
                      outlineDistance: outline.distance, hasOutlineDistance: true, snapped: true)
  outline

proc connectableNode*(g: Graph, node: Val): Val =
  var current = node
  var visited = initHashSet[string]()
  while current != nil and not current.eqs("type", "edge") and current["connectable"].isFalse and
      current.tr("containerId") and not visited.containsOrIncl(idOf(current)):
    current = lookup(g.byId, current["containerId"])
  if current != nil and not current.eqs("type", "edge") and not current["connectable"].isFalse:
    current
  else: nil

proc compareConnectionCandidates(a, b: Val): int =
  let za = a.fo("z", 0)
  let zb = b.fo("z", 0)
  if za != zb: return (if zb - za < 0: -1 else: 1)
  jsCompareStr(idOf(b), idOf(a))

proc findConnectionTarget(g: Graph, world: Pt, ignoreId: string, referencePoint: Pt,
                          referenceSide: string, hasReference: bool,
                          portDirection = "input"): AnchorInfo =
  let tolerance = 14 / g.zoom
  let ids = g.index.query(rect(world.x - tolerance, world.y - tolerance, tolerance * 2, tolerance * 2))
  var candidates: seq[Val]
  var added = initHashSet[string]()
  for id in ids:
    var node = g.byId.getOrDefault(id, nil)
    if node == nil or node.eqs("type", "edge") or node["visible"].isFalse or node.tr("foldedAway"): continue
    node = g.connectableNode(node)
    if node == nil or idOf(node) == ignoreId or added.contains(idOf(node)) or node.tr("locked") or
        g.isLayerLocked(node): continue
    let owner = g.getLayerOf(node)
    if owner != nil and owner["visible"].isFalse: continue
    added.incl idOf(node)
    candidates.add node
  candidates.sort(compareConnectionCandidates)
  for c in candidates:
    let info = g.snappedNodeAnchor(c, world, referencePoint, referenceSide,
                                   hasReference, portDirection)
    if not info.found: continue
    let distance = if info.hasOutlineDistance: info.outlineDistance else: info.distance
    if g.pointInNode(world, c) or distance <= tolerance: return info


proc findDirectionalConnectionTarget(g: Graph, source: Val, side: string): DirectionalTarget =
  let origin = nodeAnchor(source, anchorSpec(side), side)
  let sourceCenter = nodeCenter(source)
  var candidates: seq[DirectionalTarget]
  var added = initHashSet[string]()
  let maximumDistance = max(480.0, g.defaultEdgeLength * 6)
  for item in g.items:
    var node = item
    if node == nil or node.eqs("type", "edge") or idOf(node) == idOf(source) or
        node["visible"].isFalse or node.tr("foldedAway"): continue
    node = g.connectableNode(node)
    if node == nil or idOf(node) == idOf(source) or added.contains(idOf(node)) or node.tr("locked") or
        g.isLayerLocked(node): continue
    let owner = g.getLayerOf(node)
    if owner != nil and owner["visible"].isFalse: continue
    added.incl idOf(node)
    let center = nodeCenter(node)
    let dx = center.x - sourceCenter.x
    let dy = center.y - sourceCenter.y
    let primary = if side == "west": -dx elif side == "north": -dy elif side == "south": dy else: dx
    let lateral = if side == "west" or side == "east": abs(dy) else: abs(dx)
    let breadth = if side == "west" or side == "east": (nodeH(source) + nodeH(node)) / 2
                  else: (nodeW(source) + nodeW(node)) / 2
    if primary <= 0 or lateral > primary + breadth: continue
    let anchor = g.closestCardinalAnchor(node, origin)
    if not anchor.found or anchor.distance > maximumDistance: continue
    candidates.add DirectionalTarget(found: true, node: node, anchor: anchor,
      score: anchor.distance + max(0.0, lateral - breadth) * 0.35, z: node.fo("z", 0))
  candidates.sort(proc (a, b: DirectionalTarget): int =
    if a.score != b.score: (if a.score < b.score: -1 else: 1)
    elif b.z != a.z: (if b.z - a.z < 0: -1 else: 1)
    else: 0)
  if candidates.len > 0: candidates[0] else: DirectionalTarget()

proc connectVertex*(g: Graph, source0: Val, side0: string, hasDrop: bool, dropPoint: Pt,
                    before0: string): Val =
  let source = g.connectableNode(source0)
  if source == nil: return nil
  let before = if before0.len > 0: before0 else: g.snapshot()
  let side = if side0.len > 0: side0 else: "east"

  if not hasDrop:
    let existing = g.findDirectionalConnectionTarget(source, side)
    if existing.found:
      discard g.addEdge(obj(("sourceId", source["id"]), ("targetId", existing.node["id"]),
                            ("sourceSide", jstr(side)), ("targetSide", jstr(existing.anchor.side)),
                            ("sourceAnchor", anchorSpec(side)),
                            ("targetAnchor", clone(existing.anchor.anchor))), false)
      g.setSelection(@[idOf(existing.node)])
      g.commit(before, "Connect")
      g.render()
      return existing.node

  let parent = if source.tr("containerId"): lookup(g.byId, source["containerId"]) else: nil
  let stackChild = parent != nil and parent.eqs("childLayout", "stackLayout")
  var members = @[source]
  if not stackChild:
    let sourceId = idOf(source)
    for candidate in g.items:
      if candidate.eqs("type", "edge") or idOf(candidate) == sourceId: continue
      var current = candidate
      var visited = initHashSet[string]()
      while current != nil and current.tr("containerId") and not visited.containsOrIncl(idOf(current)):
        if str(current["containerId"]) == sourceId:
          members.add candidate
          break
        current = lookup(g.byId, current["containerId"])

  var targetX = nodeX(source)
  var targetY = nodeY(source)
  if hasDrop:
    targetX = dropPoint.x - nodeW(source) / 2
    targetY = dropPoint.y - nodeH(source) / 2
  elif side == "west": targetX -= nodeW(source) + g.defaultEdgeLength
  elif side == "north": targetY -= nodeH(source) + g.defaultEdgeLength
  elif side == "south": targetY += nodeH(source) + g.defaultEdgeLength
  else: targetX += nodeW(source) + g.defaultEdgeLength
  if g.gridEnabled:
    targetX = snap(targetX, g.gridSize)
    targetY = snap(targetY, g.gridSize)

  let dx = targetX - nodeX(source)
  let dy = targetY - nodeY(source)
  var idMap = initTable[string, string]()
  var clones: seq[Val]
  var remaining = members
  while remaining.len > 0:
    var progressed = false
    var i = remaining.len - 1
    while i >= 0:
      let original = remaining[i]
      if original != source and original.tr("containerId") and
          not idMap.hasKey(str(original["containerId"])):
        dec i
        continue
      let data = clone(original)
      data.del("id")
      data.del("z")
      data.del("mx")
      data["x"] = jnum(nodeX(original) + dx)
      data["y"] = jnum(nodeY(original) + dy)
      data["groups"] = newArr()
      data.del("groupId")
      if original == source:
        if stackChild: data["containerId"] = source["containerId"]
        else: data.del("containerId")
      else:
        data["containerId"] = jstr(idMap[str(original["containerId"])])
      let copy = g.addNode(data, false)
      idMap[idOf(original)] = idOf(copy)
      clones.add copy
      remaining.delete(i)
      progressed = true
      dec i
    if not progressed: break

  if clones.len == 0: return nil
  let target = clones[0]
  let opposite = oppositeSide(side)
  discard g.addEdge(obj(("sourceId", source["id"]), ("targetId", target["id"]),
                        ("sourceSide", jstr(side)), ("targetSide", jstr(opposite)),
                        ("sourceAnchor", anchorSpec(side)), ("targetAnchor", anchorSpec(opposite))), false)
  if stackChild: discard g.layoutStackContainers(@[idOf(parent)])
  g.setSelection(@[idOf(target)])
  g.updateWorldSize()
  g.commit(before, "Connect Vertex")
  g.render()
  target

# ------------------------------------------------------------ handles --

proc getTableResizeHandles(g: Graph, node: Val): seq[Handle] =
  if node == nil or not node.eqs("shape", "table") or node.tr("locked"): return
  let grid = tableGrid(node)
  let center = nodeCenter(node)
  let rotation = rot(node)
  for c in 1 ..< grid.columns.len:
    let x = grid.columns[c].pos
    let f = rotatePoint(pt(x, grid.contentY), center, rotation)
    let t = rotatePoint(pt(x, grid.contentBottom), center, rotation)
    result.add Handle(kind: "tableColumnResize", index: c, fromP: f, toP: t,
                      point: pt((f.x + t.x) / 2, (f.y + t.y) / 2), cursor: "col-resize")
  for r in 1 ..< grid.rows.len:
    let y = grid.rows[r].pos
    let f = rotatePoint(pt(nodeX(node), y), center, rotation)
    let t = rotatePoint(pt(nodeX(node) + nodeW(node), y), center, rotation)
    result.add Handle(kind: "tableRowResize", index: r, fromP: f, toP: t,
                      point: pt((f.x + t.x) / 2, (f.y + t.y) / 2), cursor: "row-resize")

proc getTableRowMoveHandles(g: Graph, node: Val): seq[Handle] =
  if node == nil or not node.eqs("shape", "table") or node.tr("locked") or
      node["reorderRows"].isFalse: return
  let grid = tableGrid(node)
  let center = nodeCenter(node)
  let rotation = rot(node)
  for r in 0 ..< grid.rows.len:
    result.add Handle(kind: "tableRowMove", row: r, cursor: "move",
      point: rotatePoint(pt(nodeX(node) + nodeW(node), grid.rows[r].pos + grid.rows[r].size / 2),
                         center, rotation))

proc getNodeHandles(g: Graph, node: Val): seq[Handle] =
  if node.tr("locked"): return
  let center = nodeCenter(node)
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  let raw = [pt(x, y), pt(x + w / 2, y), pt(x + w, y), pt(x, y + h / 2), pt(x + w, y + h / 2),
             pt(x, y + h), pt(x + w / 2, y + h), pt(x + w, y + h)]
  const cursors = ["nwse-resize", "ns-resize", "nesw-resize", "ew-resize",
                   "ew-resize", "nesw-resize", "ns-resize", "nwse-resize"]
  for i in 0 ..< raw.len:
    result.add Handle(kind: "resize", index: i, point: rotatePoint(raw[i], center, rot(node)),
                      cursor: cursors[i])
  result.add Handle(kind: "rotate", index: -1, cursor: "crosshair",
                    point: rotatePoint(pt(x + w / 2, y - 54 / g.zoom), center, rot(node)))

proc getCustomHandles(g: Graph, node: Val): seq[Handle] =
  if node == nil or node.eqs("type", "edge") or node.tr("locked"): return
  let center = nodeCenter(node)
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  var handles: seq[Handle]
  proc add(kind: string, p: Pt, cursor = "move") =
    handles.add Handle(kind: "custom", customType: kind,
                       point: rotatePoint(p, center, rot(node)), cursor: cursor)
  let shape = node["shape"]
  if node.eqs("shape", "swimlane") or node.eqs("kind", "taskList"):
    let vertical = node["horizontal"].isFalse
    let header = clamp(node.nn("headerHeight", 26), 0, if vertical: w else: h)
    add("headerSize", if vertical: pt(x + header, y + h / 2) else: pt(x + w / 2, y + header),
        if vertical: "ew-resize" else: "ns-resize")
  elif (node.eqs("shape", "rect") or nullish(shape)) and node.nm("radius") > 0:
    let radius = clamp(node.nor("radius", 0), 0, jsMin(w, h) / 2)
    add("cornerRadius", pt(x + w - radius, y + jsMin(h / 8, 14)), "ew-resize")
  elif node.eqs("shape", "cylinder"):
    add("cylinderSize", pt(x, y + h * clamp(node.nn("shapeSize", 0.1875), 0, 0.5)), "ns-resize")
  elif node.eqs("shape", "cube"):
    let cubeSize = jsMin(w, h) * clamp(node.nn("shapeSize", 0.2), 0, 0.45)
    add("cubeSize", pt(x + cubeSize, y + cubeSize), "nwse-resize")
  elif node.eqs("shape", "isoCube2"):
    let isoAngle = clamp(node.nn("isoAngle", 15), 0.01, 94)
    let isoHeight = jsMin(w * tan(isoAngle * PI / 200), h / 2)
    add("isoCubeAngle", pt(x, y + isoHeight), "ns-resize")
  elif node.eqs("shape", "loopLimit") or node.eqs("shape", "card"):
    let loop = node.eqs("shape", "loopLimit")
    let cornerDefault = if loop: 20.0 else: 30.0
    let cornerLimit = if loop: w / 2 else: w
    let cornerSize = clamp(node.nn("shapeSize", cornerDefault), 0, cornerLimit)
    let cornerDrop = clamp(if node.nul("dy"): (if loop: cornerSize * 0.8 else: cornerSize)
                           else: node.nm("dy"), 0, h)
    add("cornerCutWidth", pt(x + cornerSize, y), "ew-resize")
    add("cornerCutHeight", pt(x, y + cornerDrop), "ns-resize")
  elif node.eqs("shape", "note"):
    let fold = jsMin(w, h) * clamp(node.nn("shapeSize", 0.28), 0.08, 0.5)
    add("noteSize", pt(x + w - fold, y + fold), "nesw-resize")
  elif node.eqs("shape", "blockArrow"):
    let arrowSize = clamp(node.nor("arrowSize", 0.38), 0.1, 0.8)
    let arrowWidth = clamp(node.nor("arrowWidth", 0.44), 0.1, 1)
    add("blockArrowSize", pt(x + w * (1 - arrowSize), y + h * (1 - arrowWidth) / 2), "move")
  elif shape.isStr and shape.s in ["trapezoid", "parallelogram", "hexagon", "chevron", "step"]:
    let d = case shape.s
            of "trapezoid", "parallelogram": 0.18
            of "hexagon": 0.22
            of "chevron": 0.28
            else: 0.25
    let size = clamp(node.nn("shapeSize", d), 0, 0.48)
    add("shapeSize", if shape.s == "chevron" or shape.s == "step": pt(x + w * size, y + h / 2)
                     else: pt(x + w * size, y), "ew-resize")
  handles

proc getPortArrows(g: Graph, node: Val): seq[Handle] =
  if node.tr("portsEnabled"):
    for port in variablePorts(node):
      if port.direction == "output":
        result.add Handle(kind: "port", side: port.side, anchorSpec: port.anchor,
                          anchor: port.point, point: port.point, cursor: "crosshair")
    return
  let distance = 24 / g.zoom
  let center = nodeCenter(node)
  for side in ["north", "east", "south", "west"]:
    let spec = anchorSpec(side)
    let port = nodeAnchor(node, spec, side)
    var vx = 0.0
    var vy = 0.0
    if side == "north": vy = -distance
    if side == "south": vy = distance
    if side == "east": vx = distance
    if side == "west": vx = -distance
    let angle = rot(node) * PI / 180
    let rx = vx * cos(angle) - vy * sin(angle)
    let ry = vx * sin(angle) + vy * cos(angle)
    result.add Handle(kind: "port", side: side, anchorSpec: spec, anchor: port,
                      point: pt(port.x + rx, port.y + ry), center: center, cursor: "crosshair")

proc getEdgeHandles(g: Graph, edge: Val): seq[Handle] =
  var points = edgePoints(edge, g.byId)
  if points.len < 2: return
  let route = edge["route"]
  if edge.eqs("lineStyle", "circular"):
    let arc = circularArc(edge, g.byId)
    if arc.valid:
      result.add Handle(kind: if arc.closed: "circleRadius" else: "arcSweep",
                        point: arc.middle, cursor: "move")
  elif edge.eqs("lineStyle", "orthogonal"):
    let straightSegment = points.len == 2
    if straightSegment:
      let centre = pt((points[0].x + points[1].x) / 2, (points[0].y + points[1].y) / 2)
      points = @[points[0], centre, centre, points[1]]
    for i in 0 ..< points.len - 1:
      let a = points[i]
      let b = points[i + 1]
      var vertical = abs(a.x - b.x) < 0.01
      if vertical and abs(a.y - b.y) < 0.01 and i < points.len - 2:
        vertical = abs(a.x - points[i + 2].x) < 0.01
      result.add Handle(kind: "segment", index: i,
                        orientation: if vertical: "vertical" else: "horizontal",
                        point: pt((a.x + b.x) / 2, (a.y + b.y) / 2), points: points,
                        virtual: straightSegment and i != 1,
                        cursor: if vertical: "ew-resize" else: "ns-resize")
  else:
    if route.isArr:
      for w in 0 ..< route.len:
        result.add Handle(kind: "waypoint", index: w, point: toPt(route[w]), cursor: "move")
    for i in 0 ..< points.len - 1:
      let a = points[i]
      let b = points[i + 1]
      result.add Handle(kind: "virtual", index: i, point: pt((a.x + b.x) / 2, (a.y + b.y) / 2),
                        points: points, cursor: "pointer")
  result.add Handle(kind: "edgeTerminal", terminal: "source", point: points[0], cursor: "crosshair")
  result.add Handle(kind: "edgeTerminal", terminal: "target", point: points[^1], cursor: "crosshair")

proc insertWaypointAt(g: Graph, edge: Val, segmentIndex: int, world: Pt): int =
  let route = if edge["route"].isArr: clone(edge["route"]) else: newArr()
  let at = max(0, min(route.len, segmentIndex))
  route.a.insert(ptVal(world), at)
  edge["route"] = route
  at

proc snapConnectorPoint(g: Graph, edge: Val, world: Pt, noSnap: bool): Pt =
  var p = pt(if noSnap or not g.gridEnabled: world.x else: snap(world.x, g.gridSize),
             if noSnap or not g.gridEnabled: world.y else: snap(world.y, g.gridSize))
  if noSnap or edge == nil: return p
  let route = edge["route"]
  edge["route"] = jnull
  let terminals = edgePoints(edge, g.byId)
  edge["route"] = route
  let tolerance = 7 / g.zoom
  if terminals.len >= 2:
    for e in [terminals[0], terminals[^1]]:
      if abs(world.x - e.x) <= tolerance: p.x = e.x
      if abs(world.y - e.y) <= tolerance: p.y = e.y
  p

proc waypointAction(g: Graph, world: Pt, noSnap: bool) =
  let edge = g.byId.getOrDefault(g.action.itemId, nil)
  if edge == nil: return
  let route = clone(g.action.originalRoute)
  let index = g.action.index
  if index < 0 or index >= route.len: return
  route.a[index] = ptVal(g.snapConnectorPoint(edge, world, noSnap))
  edge["route"] = route
  g.reindex(edge)
  g.rendererUpsert([edge], true)
  g.render(true)

proc removeWaypoint*(g: Graph, edge: Val, index: int): bool =
  if edge == nil or not edge["route"].isArr or index < 0 or index >= edge["route"].len: return false
  let before = g.snapshot()
  let route = clone(edge["route"])
  route.a.delete(index)
  edge["route"] = if route.len > 0: route else: jnull
  g.reindex(edge)
  g.rendererUpsert([edge])
  g.commit(before, "Remove Waypoint")
  g.render()
  true

proc normalizeEdgeRoute(g: Graph, edge: Val) =
  if edge == nil or not edge["route"].isArr or edge["route"].len == 0: return
  let route = valPts(clone(edge["route"]))
  let source = lookup(g.byId, edge["sourceId"])
  let target = lookup(g.byId, edge["targetId"])
  let (sourceSide, targetSide) = edgeSides(edge, source, target)
  var start, finish: Pt
  if source != nil: start = nodeAnchor(source, edge["sourceAnchor"], sourceSide)
  elif truthy(edge["sourcePoint"]): start = toPt(edge["sourcePoint"])
  else: return
  if target != nil: finish = nodeAnchor(target, edge["targetAnchor"], targetSide)
  elif truthy(edge["targetPoint"]): finish = toPt(edge["targetPoint"])
  else: return
  var points = @[start] & route & @[finish]
  let orthogonal = edge.eqs("lineStyle", "orthogonal")
  if orthogonal: points = orthogonalizeRoute(points, sourceSide, targetSide)
  let tolerance = 4 / g.zoom
  var i = points.len - 2
  while i > 0:
    let previous = points[i - 1]
    let current = points[i]
    let next = points[i + 1]
    let straightThrough = if orthogonal:
        (abs(previous.x - current.x) <= tolerance and abs(current.x - next.x) <= tolerance) or
        (abs(previous.y - current.y) <= tolerance and abs(current.y - next.y) <= tolerance)
      else: distanceToSegment(current, previous, next) <= tolerance
    if hypot(current.x - previous.x, current.y - previous.y) <= tolerance or
        hypot(current.x - next.x, current.y - next.y) <= tolerance or straightThrough:
      points.delete(i)
    dec i
  edge["route"] = if points.len > 2: ptsVal(points[1 ..< points.len - 1]) else: jnull

proc hitNodeConnectionControl(g: Graph, item: Val, world: Pt): HitControl =
  if item == nil or item.eqs("type", "edge") or item.tr("locked") or item["connectable"].isFalse or
      (not item.tr("portsEnabled") and (not g.connectionArrows or g.portMode == "outline")): return
  for port in g.getPortArrows(item):
    if hypot(world.x - port.point.x, world.y - port.point.y) <= 14 / g.zoom:
      return HitControl(found: true, item: item, control: port)

proc hitControl*(g: Graph, world: Pt): HitControl =
  let radius = 12 / g.zoom
  # Named sockets are live even before selecting the node.
  for id in g.index.query(rect(world.x - radius, world.y - radius, radius * 2, radius * 2)):
    let item = g.byId.getOrDefault(id, nil)
    if item != nil and item.tr("portsEnabled") and not item["visible"].isFalse and
        not item.tr("foldedAway") and not g.isLayerLocked(item):
      let port = g.hitNodeConnectionControl(item, world)
      if port.found: return port
  let selected = g.getSelection()
  let groups = g.getSelectedGroups()
  if groups.len == 1 and groups[0].items.len == selected.len:
    let frame = g.groupFrame(groups[0].bounds)
    let groupHandles = g.getGroupHandles(frame)
    var i = groupHandles.len - 1
    while i >= 0:
      if hypot(world.x - groupHandles[i].point.x, world.y - groupHandles[i].point.y) <= radius:
        return HitControl(found: true, item: nil, group: groups[0], hasGroup: true, frame: frame,
                          control: groupHandles[i])
      dec i
    return
  if selected.len == 1:
    let item = selected[0]
    let sel = g.getSelectedTableCell()
    if sel.found and sel.node == item: return
    if not item.eqs("type", "edge") and not item.tr("locked"):
      let custom = g.getCustomHandles(item)
      var c = custom.len - 1
      while c >= 0:
        if hypot(world.x - custom[c].point.x, world.y - custom[c].point.y) <= radius:
          return HitControl(found: true, item: item, control: custom[c])
        dec c
    if not item.eqs("type", "edge") and item.eqs("shape", "table") and not item.tr("locked"):
      let rowMove = g.getTableRowMoveHandles(item)
      var r = rowMove.len - 1
      while r >= 0:
        if hypot(world.x - rowMove[r].point.x, world.y - rowMove[r].point.y) <= 10 / g.zoom:
          return HitControl(found: true, item: item, control: rowMove[r])
        dec r
      let tableHandles = g.getTableResizeHandles(item)
      var t = tableHandles.len - 1
      while t >= 0:
        if distanceToSegment(world, tableHandles[t].fromP, tableHandles[t].toP) <= 6 / g.zoom:
          return HitControl(found: true, item: item, control: tableHandles[t])
        dec t
    let controls = if item.eqs("type", "edge"): g.getEdgeHandles(item) else: g.getNodeHandles(item)
    let controlRadius = if item.eqs("type", "edge"): 8 / g.zoom else: radius
    var i = controls.len - 1
    while i >= 0:
      if hypot(world.x - controls[i].point.x, world.y - controls[i].point.y) <= controlRadius:
        return HitControl(found: true, item: item, control: controls[i])
      dec i
    let selectedConnection = g.hitNodeConnectionControl(item, world)
    if selectedConnection.found: return selectedConnection
  let hovered = g.connectableNode(g.byId.getOrDefault(g.hoverId, nil))
  if hovered != nil and not g.isSelected(idOf(hovered)):
    let hoverConnection = g.hitNodeConnectionControl(hovered, world)
    if hoverConnection.found: return hoverConnection
