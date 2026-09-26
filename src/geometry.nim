## Scene geometry: connector routing, circular arcs, table grids and item
## bounds. A direct port of PixelGeometry from the JavaScript editor, working
## on the dynamic item objects of the retained scene.

import std/[math, tables, strutils]
import jsval

type
  Pt* = object
    x*, y*: float64
  Rect* = object
    x*, y*, width*, height*: float64
  Scene* = Table[string, Val]
    ## id -> item, the painter's `items` Map and the graph's `byId`.
  VariablePort* = object
    name*, dataType*, direction*, side*: string
    index*: int
    anchor*: Val
    point*: Pt

proc pt*(x, y: float64): Pt {.inline.} = Pt(x: x, y: y)
proc rect*(x, y, w, h: float64): Rect {.inline.} = Rect(x: x, y: y, width: w, height: h)

proc jsMax*(a, b: float64): float64 {.inline.} =
  ## Math.max: NaN-propagating.
  if a != a or b != b: NaN else: max(a, b)

proc jsMin*(a, b: float64): float64 {.inline.} =
  ## Math.min: NaN-propagating.
  if a != a or b != b: NaN else: min(a, b)

proc clamp*(value, lo, hi: float64): float64 {.inline.} =
  ## Math.max(lo, Math.min(hi, value)), NaN-propagating like JS.
  jsMax(lo, jsMin(hi, value))

proc jsMin*(a, b, c: float64): float64 {.inline.} = jsMin(jsMin(a, b), c)
proc jsMax*(a, b, c: float64): float64 {.inline.} = jsMax(jsMax(a, b), c)

proc jsRound*(x: float64): float64 {.inline.} =
  ## Math.round: halves round towards +Infinity.
  floor(x + 0.5)

proc isFiniteNum*(x: float64): bool {.inline.} = x == x and x != Inf and x != -Inf

proc toPt*(v: Val): Pt = Pt(x: num(v["x"]), y: num(v["y"]))
proc ptVal*(p: Pt): Val =
  result = newObj()
  result["x"] = jnum(p.x)
  result["y"] = jnum(p.y)

proc ptsVal*(ps: openArray[Pt]): Val =
  result = newArr()
  for p in ps: result.a.add ptVal(p)

proc valPts*(v: Val): seq[Pt] =
  for x in v:
    if x != nil and x.kind == vObj: result.add toPt(x)

proc rectVal*(r: Rect): Val =
  result = newObj()
  result["x"] = jnum(r.x)
  result["y"] = jnum(r.y)
  result["width"] = jnum(r.width)
  result["height"] = jnum(r.height)

proc lookup*(scene: Scene, id: Val): Val {.inline.} =
  ## scene[id] with JavaScript's key coercion (null -> "null").
  if id == nil: return nil
  let key = if id.kind == vStr: id.s else: str(id)
  scene.getOrDefault(key, nil)

proc boundsOfPoints*(points: openArray[Pt], padding = 0.0): Rect =
  if points.len == 0: return rect(0, 0, 0, 0)
  var minX = points[0].x
  var minY = points[0].y
  var maxX = minX
  var maxY = minY
  for i in 1 ..< points.len:
    minX = jsMin(minX, points[i].x)
    minY = jsMin(minY, points[i].y)
    maxX = jsMax(maxX, points[i].x)
    maxY = jsMax(maxY, points[i].y)
  rect(minX - padding, minY - padding, maxX - minX + padding * 2, maxY - minY + padding * 2)

proc intersects*(a, b: Rect): bool {.inline.} =
  a.x + a.width >= b.x and a.y + a.height >= b.y and a.x <= b.x + b.width and
    a.y <= b.y + b.height

proc rotatePoint*(p, center: Pt, degrees: float64): Pt =
  if degrees == 0 or degrees != degrees: return p
  let radians = degrees * PI / 180
  let c = cos(radians)
  let s = sin(radians)
  let dx = p.x - center.x
  let dy = p.y - center.y
  pt(center.x + dx * c - dy * s, center.y + dx * s + dy * c)

proc rot*(node: Val): float64 =
  ## node.rotation || 0
  node.fo("rotation", 0)

proc nodeX*(n: Val): float64 = num(n["x"])
proc nodeY*(n: Val): float64 = num(n["y"])
proc nodeW*(n: Val): float64 = num(n["width"])
proc nodeH*(n: Val): float64 = num(n["height"])

proc nodeCenter*(node: Val): Pt {.inline.} =
  pt(nodeX(node) + nodeW(node) / 2, nodeY(node) + nodeH(node) / 2)

proc portLabels*(node: Val, direction: string): seq[(string, string)] =
  let source = if direction == "input": node.so("inputPorts", "In")
               else: node.so("outputPorts", "Out")
  for entry in source.replace(';', ',').replace('\n', ',').split(','):
    if result.len >= 8: break
    let parts = entry.strip().split(':', maxsplit = 1)
    let name = parts[0].strip()
    if name.len == 0: continue
    result.add (name, if parts.len > 1: parts[1].strip().toLowerAscii() else: "any")

proc variablePorts*(node: Val): seq[VariablePort] =
  if not node.tr("portsEnabled") or node.eqs("type", "edge"): return
  let center = nodeCenter(node)
  for direction in ["input", "output"]:
    let entries = portLabels(node, direction)
    let side = if direction == "input": "west" else: "east"
    let x = if direction == "input": 0.0 else: 1.0
    for i, entry in entries:
      let y = float64(i + 1) / float64(entries.len + 1)
      let anchor = newObj()
      anchor["x"] = jnum(x)
      anchor["y"] = jnum(y)
      anchor["side"] = jstr(side)
      anchor["portKind"] = jstr(direction)
      anchor["portIndex"] = jnum(i)
      anchor["portName"] = jstr(entry[0])
      let p = pt(nodeX(node) + x * nodeW(node), nodeY(node) + y * nodeH(node))
      result.add VariablePort(name: entry[0], dataType: entry[1], direction: direction,
                              side: side, index: i, anchor: anchor,
                              point: rotatePoint(p, center, rot(node)))

proc nodePort*(node: Val, side: string): Pt =
  let center = nodeCenter(node)
  var p = center
  if side == "north": p.y = nodeY(node)
  if side == "south": p.y = nodeY(node) + nodeH(node)
  if side == "west": p.x = nodeX(node)
  if side == "east": p.x = nodeX(node) + nodeW(node)
  rotatePoint(p, center, rot(node))

proc nodeAnchor*(node: Val, anchor: Val, fallbackSide: string): Pt =
  ## Normalised anchor on a node, glued through move/resize/rotate.
  if node.tr("portsEnabled") and anchor != nil and anchor["portIndex"].isNum:
    let direction = anchor.so("portKind", "")
    let entries = portLabels(node, direction)
    let index = int(num(anchor["portIndex"]))
    if direction in ["input", "output"] and index >= 0 and index < entries.len:
      let x = if direction == "input": 0.0 else: 1.0
      let y = float64(index + 1) / float64(entries.len + 1)
      return rotatePoint(pt(nodeX(node) + x * nodeW(node), nodeY(node) + y * nodeH(node)),
                         nodeCenter(node), rot(node))
  if nullish(anchor) or not isFiniteNum(num(anchor["x"])) or not isFiniteNum(num(anchor["y"])):
    return nodePort(node, if fallbackSide.len > 0: fallbackSide else: "east")
  let center = nodeCenter(node)
  let p = pt(nodeX(node) + clamp(num(anchor["x"]), 0, 1) * nodeW(node),
             nodeY(node) + clamp(num(anchor["y"]), 0, 1) * nodeH(node))
  rotatePoint(p, center, rot(node))

proc oppositeSide*(side: string): string =
  if side == "north": "south"
  elif side == "south": "north"
  elif side == "west": "east"
  else: "west"

proc nearestSide*(node: Val, p: Pt): string =
  let center = nodeCenter(node)
  let local = rotatePoint(p, center, -rot(node))
  let d = [abs(local.y - nodeY(node)), abs(local.x - nodeX(node) - nodeW(node)),
           abs(local.y - nodeY(node) - nodeH(node)), abs(local.x - nodeX(node))]
  const names = ["north", "east", "south", "west"]
  var best = 0
  for i in 1 .. 3:
    if d[i] < d[best]: best = i
  names[best]

proc samePoint*(a, b: Pt): bool {.inline.} =
  abs(a.x - b.x) < 0.01 and abs(a.y - b.y) < 0.01

proc simplifyOrthogonal*(points: openArray[Pt]): seq[Pt] =
  for p in points:
    if result.len == 0 or not samePoint(result[^1], p): result.add p
  var j = result.len - 2
  while j > 0:
    let a = result[j - 1]
    let b = result[j]
    let c = result[j + 1]
    if (abs(a.x - b.x) < 0.01 and abs(b.x - c.x) < 0.01) or
        (abs(a.y - b.y) < 0.01 and abs(b.y - c.y) < 0.01):
      result.delete(j)
    dec j

proc orthogonalizeRoute*(points: seq[Pt], sourceSide, targetSide: string): seq[Pt] =
  ## Old mxGraph control points are routing hints: add the missing elbows.
  if points.len < 2: return points
  var res = @[points[0]]
  var horizontal = sourceSide == "east" or sourceSide == "west"
  for i in 1 ..< points.len - 1:
    let hint = points[i]
    var previous = res[^1]
    let dx = abs(hint.x - previous.x)
    let dy = abs(hint.y - previous.y)
    if dx > 0.01 and dy > 0.01:
      let elbow = if horizontal: pt(hint.x, previous.y) else: pt(previous.x, hint.y)
      res.add elbow
      horizontal = not horizontal
    previous = res[^1]
    if not samePoint(previous, hint):
      horizontal = abs(hint.y - previous.y) < 0.01
      res.add hint
  let target = points[^1]
  let last = res[^1]
  if abs(target.x - last.x) > 0.01 and abs(target.y - last.y) > 0.01:
    let horizontalTarget = targetSide == "east" or targetSide == "west"
    res.add(if horizontalTarget: pt(last.x, target.y) else: pt(target.x, last.y))
  res.add target
  simplifyOrthogonal(res)

proc automaticRoute*(source, target: Pt, sourceSide, targetSide: string): seq[Pt] =
  ## sourceSide/targetSide are "" for a free (dangling) terminal.
  let horizontalSource = sourceSide == "east" or sourceSide == "west"
  let horizontalTarget = targetSide == "east" or targetSide == "west"
  let hasSource = sourceSide.len > 0
  let hasTarget = targetSide.len > 0
  const gap = 28.0
  let s = source
  let t = target

  if hasSource and not hasTarget:
    return simplifyOrthogonal(if horizontalSource: @[s, pt(t.x, s.y), t]
                              else: @[s, pt(s.x, t.y), t])
  if not hasSource and hasTarget:
    return simplifyOrthogonal(if horizontalTarget: @[s, pt(s.x, t.y), t]
                              else: @[s, pt(t.x, s.y), t])
  if not hasSource and not hasTarget:
    return simplifyOrthogonal(@[s, pt(t.x, s.y), t])

  var so = s
  var to = t
  if sourceSide == "east": so.x += gap
  if sourceSide == "west": so.x -= gap
  if sourceSide == "north": so.y -= gap
  if sourceSide == "south": so.y += gap
  if targetSide == "east": to.x += gap
  if targetSide == "west": to.x -= gap
  if targetSide == "north": to.y -= gap
  if targetSide == "south": to.y += gap

  var points = @[s, so]
  if horizontalSource and horizontalTarget:
    let midX = (so.x + to.x) / 2
    points.add pt(midX, so.y)
    points.add pt(midX, to.y)
  elif not horizontalSource and not horizontalTarget:
    let midY = (so.y + to.y) / 2
    points.add pt(so.x, midY)
    points.add pt(to.x, midY)
  elif horizontalSource:
    points.add pt(to.x, so.y)
  else:
    points.add pt(so.x, to.y)
  points.add to
  points.add t
  simplifyOrthogonal(points)

proc anchorSideOf(anchor: Val): string =
  if truthy(anchor):
    let s = anchor["side"]
    if truthy(s): return str(s)
  ""

proc edgeSides*(edge: Val, source, target: Val): (string, string) =
  ## The routing sides of an edge's two terminals ("" when dangling).
  var sourceSide = ""
  if source != nil:
    sourceSide = anchorSideOf(edge["sourceAnchor"])
    if sourceSide.len == 0: sourceSide = edge.so("sourceSide", "east")
  var targetSide = ""
  if target != nil:
    targetSide = anchorSideOf(edge["targetAnchor"])
    if targetSide.len == 0:
      let ts = edge["targetSide"]
      targetSide = if truthy(ts): str(ts)
                   else: oppositeSide(if sourceSide.len > 0: sourceSide else: "east")
  (sourceSide, targetSide)

proc edgePoints*(edge: Val, scene: Scene): seq[Pt] =
  let source = lookup(scene, edge["sourceId"])
  let target = lookup(scene, edge["targetId"])
  let (sourceSide, targetSide) = edgeSides(edge, source, target)
  let preview = edge["previewPoints"]
  var sourcePoint, targetPoint: Pt
  var haveSource, haveTarget: bool
  if source != nil:
    sourcePoint = nodeAnchor(source, edge["sourceAnchor"], sourceSide)
    haveSource = true
  else:
    let sp = edge["sourcePoint"]
    if truthy(sp):
      sourcePoint = toPt(sp)
      haveSource = true
    elif preview.len > 0 and not nullish(preview[0]):
      sourcePoint = toPt(preview[0])
      haveSource = true
  if target != nil:
    targetPoint = nodeAnchor(target, edge["targetAnchor"], targetSide)
    haveTarget = true
  else:
    let tp = edge["targetPoint"]
    if truthy(tp):
      targetPoint = toPt(tp)
      haveTarget = true
    elif preview.len > 0 and not nullish(preview[preview.len - 1]):
      targetPoint = toPt(preview[preview.len - 1])
      haveTarget = true

  if not haveSource or not haveTarget:
    return valPts(preview)

  let route = edge["route"]
  if not nullish(route) and route.len > 0:
    var routed = @[sourcePoint]
    for p in route:
      if p != nil and p.kind == vObj: routed.add toPt(p)
      else: routed.add pt(NaN, NaN)
    routed.add targetPoint
    if edge.eqs("lineStyle", "orthogonal"):
      return orthogonalizeRoute(routed, sourceSide, targetSide)
    return routed

  if edge.eqs("lineStyle", "straight"):
    return @[sourcePoint, targetPoint]
  automaticRoute(sourcePoint, targetPoint, sourceSide, targetSide)

type CircArc* = object
  valid*: bool
  source*, target*, center*, middle*: Pt
  radius*, startAngle*, endAngle*, sweepDegrees*: float64
  anticlockwise*: bool
  side*: float64
  samples*: seq[Pt]
  closed*: bool

proc circularArc*(edge: Val, scene: Scene): CircArc =
  let endpoints = edgePoints(edge, scene)
  if endpoints.len < 2: return
  let source = endpoints[0]
  let target = endpoints[^1]
  let dx = target.x - source.x
  let dy = target.y - source.y
  let chord = hypot(dx, dy)
  let side = if num(edge["arcSide"]) < 0: -1.0 else: 1.0
  var requested = abs(num(edge["arcSweep"]))
  if not isFiniteNum(requested) or requested < 1:
    requested = if chord < 0.01: 360.0 else: 180.0
  var center: Pt
  var radius, startAngle, sweepDegrees: float64

  if chord < 0.01:
    sweepDegrees = clamp(requested, 1, 360)
    var r = abs(num(edge["circleRadius"]))
    if not truthy(jnum(r)): r = 60
    radius = clamp(r, 5, 10000)
    center = source
    startAngle = -PI / 2
  else:
    sweepDegrees = clamp(requested, 1, 180)
    let radians = sweepDegrees * PI / 180
    radius = chord / (2 * sin(radians / 2))
    let height = if sweepDegrees >= 179.999: 0.0 else: chord / (2 * tan(radians / 2))
    let normal = pt(-dy / chord, dx / chord)
    center = pt((source.x + target.x) / 2 - normal.x * height * side,
                (source.y + target.y) / 2 - normal.y * height * side)
    startAngle = arctan2(source.y - center.y, source.x - center.x)

  let sweepRadians = sweepDegrees * PI / 180
  let endAngle = startAngle - side * sweepRadians
  let divisions = max(12, int(ceil(sweepDegrees / 4)))
  var samples = newSeqOfCap[Pt](divisions + 1)
  for i in 0 .. divisions:
    let angle = startAngle - side * sweepRadians * float64(i) / float64(divisions)
    samples.add pt(center.x + cos(angle) * radius, center.y + sin(angle) * radius)
  if chord >= 0.01:
    samples[0] = source
    samples[^1] = target
  let middleAngle = startAngle - side * sweepRadians / 2
  CircArc(valid: true, source: source, target: target, center: center, radius: radius,
          startAngle: startAngle, endAngle: endAngle, anticlockwise: side > 0,
          side: side, sweepDegrees: sweepDegrees, samples: samples,
          middle: pt(center.x + cos(middleAngle) * radius, center.y + sin(middleAngle) * radius),
          closed: chord < 0.01)

# --------------------------------------------------------------- tables --

type
  Track* = object
    pos*, size*: float64   ## y/height for rows, x/width for columns
  TableGrid* = object
    rows*, columns*: seq[Track]
    titleHeight*, contentY*, contentBottom*: float64
  CellBox* = object
    row*, column*, rowspan*, colspan*: int
    cell*: Val
    x*, y*, width*, height*: float64
  CellOrigin* = object
    row*, column*, rowspan*, colspan*: int
    cell*: Val

proc weightsFor(v: Val, count: int): seq[float64] =
  if v.isArr and v.len == count:
    for x in v: result.add num(x)
  else:
    result = newSeq[float64](count)
    for i in 0 ..< count: result[i] = 1

proc tableGrid*(node: Val): TableGrid =
  let rowCount = max(1, int(node.fo("rows", 3)))
  let columnCount = max(1, int(node.fo("columns", 3)))
  let height = nodeH(node)
  let width = nodeW(node)
  let titleHeight = if node.nul("tableTitle"): 0.0
                    else: clamp(node.nor("tableTitleHeight", 30), 0, height)
  let availableHeight = max(0.0, height - titleHeight)
  let rowWeights = weightsFor(node["rowWeights"], rowCount)
  let columnWeights = weightsFor(node["columnWeights"], columnCount)
  var rowTotal = 0.0
  for w in rowWeights: rowTotal += w
  if not truthy(jnum(rowTotal)): rowTotal = float64(rowCount)
  var columnTotal = 0.0
  for w in columnWeights: columnTotal += w
  if not truthy(jnum(columnTotal)): columnTotal = float64(columnCount)

  let x0 = nodeX(node)
  let y0 = nodeY(node)
  var offset = 0.0
  let fixedRows = node.tr("fixedRows")
  for r in 0 ..< rowCount:
    var h: float64
    if fixedRows:
      h = max(1.0, (if truthy(jnum(rowWeights[r])): rowWeights[r] else: 1.0))
    else:
      h = availableHeight * rowWeights[r] / rowTotal
    if offset + h > availableHeight: h = max(0.0, availableHeight - offset)
    result.rows.add Track(pos: y0 + titleHeight + offset, size: h)
    offset += h
  let rowExtent = offset
  offset = 0
  for c in 0 ..< columnCount:
    let w = width * columnWeights[c] / columnTotal
    result.columns.add Track(pos: x0 + offset, size: w)
    offset += w
  result.titleHeight = titleHeight
  result.contentY = y0 + titleHeight
  result.contentBottom = y0 + titleHeight + min(rowExtent, availableHeight)

proc parseCellKey*(key: string): (float64, float64) =
  var comma = -1
  for i, c in key:
    if c == ',':
      comma = i
      break
  if comma < 0: return (parseNumStr(key), NaN)
  (parseNumStr(key[0 ..< comma]), parseNumStr(key[comma + 1 .. ^1]))

proc cellObj*(v: Val): Val =
  ## typeof cell === 'string' ? { text: cell } : cell || {}
  if v != nil and v.kind == vStr:
    result = newObj()
    result["text"] = v
  elif truthy(v): result = v
  else: result = newObj()

proc tableCellOriginAt*(node: Val, row0, column0: float64): CellOrigin =
  let rows = max(1.0, (let r = num(node["rows"]); if truthy(jnum(r)): r else: 1.0))
  let columns = max(1.0, (let c = num(node["columns"]); if truthy(jnum(c)): c else: 1.0))
  var row = max(0.0, min(rows - 1, (if truthy(jnum(row0)): row0 else: 0.0)))
  var column = max(0.0, min(columns - 1, (if truthy(jnum(column0)): column0 else: 0.0)))
  let cells = node["cells"]
  if cells.isObj:
    for i in 0 ..< cells.ks.len:
      let key = atomName(cells.ks[i])
      let (originRow, originColumn) = parseCellKey(key)
      let cell = cellObj(cells.vs[i])
      let rowspan = max(1.0, min(rows - originRow, cell.fo("rowspan", 1)))
      let colspan = max(1.0, min(columns - originColumn, cell.fo("colspan", 1)))
      if row >= originRow and row < originRow + rowspan and
          column >= originColumn and column < originColumn + colspan:
        return CellOrigin(row: int(originRow), column: int(originColumn),
                          rowspan: int(rowspan), colspan: int(colspan), cell: cell)
  let empty = newObj()
  empty["text"] = jstr("")
  CellOrigin(row: int(row), column: int(column), rowspan: 1, colspan: 1, cell: empty)

proc tableCellBox*(node: Val, row, column: float64): CellBox =
  let grid = tableGrid(node)
  let origin = tableCellOriginAt(node, row, column)
  var width = 0.0
  var height = 0.0
  for c in origin.column ..< origin.column + origin.colspan:
    if c >= 0 and c < grid.columns.len: width += grid.columns[c].size
  for r in origin.row ..< origin.row + origin.rowspan:
    if r >= 0 and r < grid.rows.len: height += grid.rows[r].size
  CellBox(row: origin.row, column: origin.column, rowspan: origin.rowspan,
          colspan: origin.colspan, cell: origin.cell,
          x: grid.columns[origin.column].pos, y: grid.rows[origin.row].pos,
          width: width, height: height)

proc tableCellAt*(node: Val, p: Pt): (bool, CellBox) =
  let grid = tableGrid(node)
  var row = -1
  var column = -1
  for r in 0 ..< grid.rows.len:
    if p.y >= grid.rows[r].pos and p.y < grid.rows[r].pos + grid.rows[r].size: row = r
  for c in 0 ..< grid.columns.len:
    if p.x >= grid.columns[c].pos and p.x < grid.columns[c].pos + grid.columns[c].size: column = c
  if row < 0 or column < 0: return (false, CellBox())
  (true, tableCellBox(node, float64(row), float64(column)))

proc cellBoxVal*(b: CellBox): Val =
  result = newObj()
  result["row"] = jnum(b.row)
  result["column"] = jnum(b.column)
  result["rowspan"] = jnum(b.rowspan)
  result["colspan"] = jnum(b.colspan)
  result["cell"] = b.cell
  result["x"] = jnum(b.x)
  result["y"] = jnum(b.y)
  result["width"] = jnum(b.width)
  result["height"] = jnum(b.height)

# --------------------------------------------------------------- bounds --

proc nodeCorners*(node: Val): array[4, Pt] =
  let c = nodeCenter(node)
  let r = rot(node)
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  [rotatePoint(pt(x, y), c, r), rotatePoint(pt(x + w, y), c, r),
   rotatePoint(pt(x + w, y + h), c, r), rotatePoint(pt(x, y + h), c, r)]

proc itemBounds*(item: Val, scene: Scene): Rect =
  if item.eqs("type", "edge"):
    if item.eqs("lineStyle", "circular"):
      let arc = circularArc(item, scene)
      if arc.valid: return boundsOfPoints(arc.samples, 12)
    return boundsOfPoints(edgePoints(item, scene), 12)
  boundsOfPoints(nodeCorners(item), 10)
