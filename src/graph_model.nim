# Included from graph.nim: the retained model -- construction, events,
# undo snapshots, loading, add/remove/paste, styles, groups, layers,
# folding, tables, and the viewport/world size bookkeeping.

# ------------------------------------------------------------ bridge --

proc emit(g: Graph, name: string, data: Val = nil) =
  if g.hooks.emit != nil: g.hooks.emit(name, data)

proc getSelection*(g: Graph): seq[Val] =
  for id in g.selection:
    let it = g.byId.getOrDefault(id, nil)
    if it != nil: result.add it

proc emitSelection(g: Graph) =
  g.emit("selectionchange", itemsVal(g.getSelection()))

proc hasMedia(item: Val): bool =
  item.tr("src") or item["mediaLayers"].isArr

proc mediaItems(items: openArray[Val]): Val =
  result = newArr()
  for it in items:
    if hasMedia(it): result.push it

proc rendererSync(g: Graph) =
  g.painter.sync(g.items)
  if g.hooks.rendererSync != nil: g.hooks.rendererSync(mediaItems(g.items))

proc rendererUpsert(g: Graph, items: openArray[Val], deferWorker = false) =
  if items.len == 0: return
  g.painter.upsert(items)
  if g.hooks.rendererUpsert != nil:
    var ids: seq[string]
    for it in items: ids.add idOf(it)
    let media = mediaItems(items)
    g.hooks.rendererUpsert(ids, deferWorker, if media.len > 0: media else: nil)

proc rendererRemove(g: Graph, ids: openArray[string]) =
  if ids.len == 0: return
  g.painter.remove(ids)
  if g.hooks.rendererRemove != nil: g.hooks.rendererRemove(@ids)

proc toast(g: Graph, text: string) = g.emit("toast", jstr(text))

# -------------------------------------------------------- construction --

proc defaultLayers(): Val =
  let layer = newObj()
  layer["id"] = jstr("layer-0")
  layer["name"] = jstr("Background")
  layer["visible"] = jtrue
  layer["locked"] = jfalse
  newArr([layer])

proc defaultEdgeStyleVal(): Val =
  result = newObj()
  result["lineStyle"] = jstr("orthogonal")
  result["rounded"] = jfalse

proc newGraph*(mobileMode = false): Graph =
  result = Graph(
    byId: initTable[string, Val](),
    index: initSpatialGrid(256),
    zoom: 1, gridSize: 10, gridEnabled: true, gridColor: "#dfe4ea",
    backgroundColor: "#ffffff", pageView: false, pageWidth: 827, pageHeight: 1169,
    pageMargin: 24, pageColumns: 1, pageRows: 1, pageStartColumn: 0, pageStartRow: 0,
    connectionArrows: true, connectionPoints: true, allowLoops: true,
    defaultEdgeLength: 80, guidesEnabled: true, portMode: "unity",
    defaultEdgeStyle: defaultEdgeStyleVal(), pageScale: 1, tooltipsEnabled: true,
    layers: defaultLayers(), activeLayer: "layer-0", mobileMode: mobileMode,
    extra: newObj(), painter: newScenePainter(), overlay: newCtx())
  result.textEditor.taskIndex = -1
  result.textEditor.richBlockIndex = -1

proc start*(g: Graph) =
  ## Mirrors the tail of the JS constructor, once the surface exists.
  g.rendererSync()
  g.updateWorldSize()
  g.render()

# ------------------------------------------------------------ snapshot --

proc isEmbeddedMedia(s: string): bool =
  ## /^data:(?:image\/gif|video\/(?:mp4|webm))(?:;|,)/i
  if s.len < 10: return false
  let head = s[0 ..< min(s.len, 24)].toLowerAscii()
  for prefix in ["data:image/gif", "data:video/mp4", "data:video/webm"]:
    if head.startsWith(prefix) and head.len > prefix.len and head[prefix.len] in {';', ','}:
      return true
  false

const BlobMarker = "\0pixel-snapshot-blob:"

proc snapshot*(g: Graph): string =
  ## JSON of the scene with large strings (embedded media) interned, so
  ## undo history does not copy megabytes of data URIs on every gesture.
  let hook = proc (v: Val): string =
    let s = v.s
    if s.len < 65536 and not isEmbeddedMedia(s): return s
    let key = cast[int](v)
    if g.snapshotBlobsById.hasKey(key):
      let (held, id) = g.snapshotBlobsById[key]
      if held == v: return BlobMarker & id
    var id = g.snapshotBlobIds.getOrDefault(s, "")
    if id.len == 0:
      inc g.snapshotBlobCounter
      id = $g.snapshotBlobCounter
      g.snapshotBlobIds[s] = id
      g.snapshotBlobs[id] = v
    g.snapshotBlobsById[key] = (v, id)
    BlobMarker & id
  toJson(itemsVal(g.items), hook)

proc parseSnapshot(g: Graph, data: string): Val =
  let parsed = parseJson(data)
  mapStrings(parsed, proc (s: string): Val =
    if s.startsWith(BlobMarker):
      let id = s[BlobMarker.len .. ^1]
      if g.snapshotBlobs.hasKey(id): return g.snapshotBlobs[id]
    jstr(s))

proc commit*(g: Graph, before: string, label = "", hasBefore = true) =
  let after = g.snapshot()
  if hasBefore and before != after:
    let l = if label.len > 0: label else: "Edit"
    g.history.add HistoryEntry(data: before, label: l)
    if g.history.len > 100: g.history.delete(0)
    g.future.setLen(0)
    g.emit("historychange")
    g.emit("change", obj(("label", jstr(l))))

proc undo*(g: Graph) =
  if g.history.len == 0: return
  g.future.add HistoryEntry(data: g.snapshot(), label: "Redo")
  let entry = g.history.pop()
  g.loadItems(g.parseSnapshot(entry.data), false)
  g.emit("historychange")

proc redo*(g: Graph) =
  if g.future.len == 0: return
  g.history.add HistoryEntry(data: g.snapshot(), label: "Undo")
  let entry = g.future.pop()
  g.loadItems(g.parseSnapshot(entry.data), false)
  g.emit("historychange")

proc canUndo*(g: Graph): bool = g.history.len > 0
proc canRedo*(g: Graph): bool = g.future.len > 0

# --------------------------------------------------------------- load --

proc loadItems*(g: Graph, items: Val, resetHistory = true, layers: Val = nil) =
  g.layers = if layers.isArr and layers.len > 0: clone(layers) else: defaultLayers()
  g.activeLayer = strOrEmpty(g.layers[0]["id"])
  var known: seq[string]
  for layer in g.layers: known.add strOrEmpty(layer["id"])

  let cloned = clone(if items.isArr: items else: newArr())
  g.items = @[]
  for it in cloned: g.items.add it
  if resetHistory:
    g.infiniteWorldWidth = 0
    g.infiniteWorldHeight = 0
    g.worldOriginX = 0
    g.worldOriginY = 0
    setScroll(0, 0)
  g.byId = initTable[string, Val]()
  for item in g.items:
    discard normalizeGroups(item)
    discard normalizeHtml(item)
    if not item.tr("containerRole") and not item.eqs("type", "edge"):
      let legacyName = jsTrim(strOrEmpty(item["text"])).toLowerAscii()
      if item.eqs("shape", "swimlane") and legacyName == "container":
        item["kind"] = jstr("container")
        item["containerRole"] = jstr("container")
        item["container"] = jtrue
        item["collapsible"] = jtrue
      elif item.eqs("childLayout", "stackLayout") and legacyName == "list":
        item["kind"] = jstr("list")
        item["containerRole"] = jstr("list")
        item["container"] = jtrue
        item["collapsible"] = jtrue
    # Items from a layerless document (or naming an unknown layer) land on
    # the first layer; indexOf is a strict comparison against layer ids.
    let layer = item["layer"]
    if nullish(layer) or not layer.isStr or not known.containsStr(layer.s):
      item["layer"] = jstr(g.activeLayer)
    g.byId[idOf(item)] = item
  for child in g.items:
    let parent = if child.tr("containerId"): lookup(g.byId, child["containerId"]) else: nil
    if parent == nil or parent == child or parent.eqs("type", "edge"): child.del("containerId")
    else: parent["container"] = jtrue
    discard g.normalizeCircularEdge(child)
  var topZ = 0.0
  for item in g.items: topZ = jsMax(topZ, item.fo("z", 0))
  if topZ > 0:
    var liftZ = topZ
    for item in g.items:
      if item.eqs("type", "edge") and not (item.nm("z") > 0):
        liftZ += 1
        item["z"] = jnum(liftZ)
  g.selection = @[]
  g.tableSelection.active = false
  g.enteredGroups = @[]
  g.rebuildIndex()
  g.rendererSync()
  var stacks: seq[string]
  for item in g.items:
    if not item.eqs("type", "edge") and item.eqs("childLayout", "stackLayout"):
      stacks.add idOf(item)
  discard g.layoutStackContainers(stacks)
  if resetHistory:
    g.history.setLen(0)
    g.future.setLen(0)
    g.snapshotBlobIds.clear()
    g.snapshotBlobsById.clear()
    g.snapshotBlobs.clear()
    g.snapshotBlobCounter = 0
  g.updateWorldSize()
  if resetHistory and g.pageView:
    setScroll(0, 0)
  g.render()
  g.emit("selectionchange", newArr())
  g.emit("layerchange", g.layers)
  g.emit("change", obj(("label", jstr("Load"))))

proc diagramVal(g: Graph): Val =
  obj(("gridEnabled", jbool(g.gridEnabled)), ("gridSize", jnum(g.gridSize)),
      ("gridColor", jstr(g.gridColor)), ("backgroundColor", jstr(g.backgroundColor)),
      ("pageView", jbool(g.pageView)), ("pageWidth", jnum(g.pageWidth)),
      ("pageHeight", jnum(g.pageHeight)), ("connectionArrows", jbool(g.connectionArrows)),
      ("connectionPoints", jbool(g.connectionPoints)), ("guidesEnabled", jbool(g.guidesEnabled)),
      ("pageScale", jnum(g.pageScale)), ("tooltipsEnabled", jbool(g.tooltipsEnabled)))

proc toJSON*(g: Graph): string =
  let doc = obj(("format", jstr("pixel-graph-v2")),
                ("viewport", obj(("zoom", jnum(g.zoom)))),
                ("diagram", g.diagramVal()),
                ("layers", g.layers),
                ("items", itemsVal(g.items)))
  toJsonPretty(doc, 2)

proc fromJSON*(g: Graph, data: Val) =
  if not truthy(data) or not data["items"].isArr:
    raise newException(JsonError, "Invalid pixel graph document")
  let vz = num(data["viewport"]["zoom"])
  g.zoom = clamp(if vz == vz and vz != 0: vz else: 1.0, 0.2, 4)
  let diagram = if truthy(data["diagram"]): data["diagram"] else: newObj()
  if diagram["gridEnabled"].isBool: g.gridEnabled = diagram["gridEnabled"].b
  if diagram.nm("gridSize") > 0: g.gridSize = clamp(diagram.nm("gridSize"), 2, 200)
  if diagram.tr("gridColor"): g.gridColor = str(diagram["gridColor"])
  if diagram.tr("backgroundColor"): g.backgroundColor = str(diagram["backgroundColor"])
  if diagram["pageView"].isBool: g.pageView = diagram["pageView"].b
  if diagram.nm("pageWidth") > 0: g.pageWidth = diagram.nm("pageWidth")
  if diagram.nm("pageHeight") > 0: g.pageHeight = diagram.nm("pageHeight")
  if diagram["connectionArrows"].isBool: g.connectionArrows = diagram["connectionArrows"].b
  if diagram["connectionPoints"].isBool: g.connectionPoints = diagram["connectionPoints"].b
  if diagram["guidesEnabled"].isBool: g.guidesEnabled = diagram["guidesEnabled"].b
  if diagram.nm("pageScale") > 0: g.pageScale = diagram.nm("pageScale")
  if diagram["tooltipsEnabled"].isBool: g.tooltipsEnabled = diagram["tooltipsEnabled"].b
  g.loadItems(data["items"], true, data["layers"])

# ---------------------------------------------------------------- add --

proc maxZ(g: Graph): float64 =
  result = 0
  for it in g.items: result = jsMax(result, it.fo("z", 0))

proc addNode*(g: Graph, data: Val, select = true): Val =
  let node = obj(("id", jstr(uid("node"))), ("type", jstr("node")), ("kind", jstr("shape")),
                 ("shape", jstr("rect")), ("x", jnum(120)), ("y", jnum(100)),
                 ("width", jnum(160)), ("height", jnum(80)), ("rotation", jnum(0)),
                 ("fill", jstr("#ffffff")), ("stroke", jstr("#4a5564")),
                 ("strokeWidth", jnum(1.5)), ("radius", jnum(5)), ("text", jstr("Process")),
                 ("textColor", jstr("#172033")), ("fontSize", jnum(14)),
                 ("z", jnum(g.maxZ() + 1)), ("visible", jtrue))
  assign(node, clone(if truthy(g.defaultNodeStyle): g.defaultNodeStyle else: newObj()))
  assign(node, clone(if truthy(data): data else: newObj()))
  if node.nul("layer"): node["layer"] = jstr(g.activeLayer)
  discard normalizeGroups(node)
  discard normalizeHtml(node)
  g.items.add node
  g.byId[idOf(node)] = node
  g.reindex(node)
  g.rendererUpsert([node])
  if select: g.setSelection(@[idOf(node)])
  g.updateWorldSize()
  g.render()
  node

proc addEdge*(g: Graph, data: Val, select = true): Val =
  let edge = obj(("id", jstr(uid("edge"))), ("type", jstr("edge")), ("sourceId", jnull),
                 ("targetId", jnull), ("sourceSide", jstr("east")), ("targetSide", jstr("west")),
                 ("sourceAnchor", jnull), ("targetAnchor", jnull), ("route", jnull),
                 ("stroke", jstr("#000000")), ("strokeWidth", jnum(1)),
                 ("lineStyle", jstr("straight")), ("startArrow", jstr("none")),
                 ("endArrow", jstr("classic")), ("rounded", jtrue),
                 ("fontFamily", jstr("Helvetica, Arial, sans-serif")), ("fontSize", jnum(11)),
                 ("z", jnum(g.maxZ() + 1)), ("visible", jtrue))
  assign(edge, clone(if truthy(g.defaultEdgeStyle): g.defaultEdgeStyle else: newObj()))
  assign(edge, clone(if truthy(data): data else: newObj()))
  g.items.add edge
  g.byId[idOf(edge)] = edge
  discard g.normalizeCircularEdge(edge)
  g.registerEdge(edge)
  g.reindex(edge)
  g.rendererUpsert([edge])
  if select: g.setSelection(@[idOf(edge)])
  g.render()
  edge

proc addTemplate*(g: Graph, templ: Val, position: Val = nil, select = true): Val =
  let definition = clone(if truthy(templ): templ else: newObj())
  var children: seq[Val]
  if definition["children"].isArr:
    for c in definition["children"]: children.add c
  definition.del("children")
  if truthy(position):
    definition["x"] = position["x"]
    definition["y"] = position["y"]

  if definition.eqs("type", "edge"):
    var points: seq[Pt]
    let pp = definition["previewPoints"]
    if pp.isArr and pp.len >= 2: points = valPts(pp)
    else:
      points = @[pt(0, 0), pt(definition.fo("width", 100), definition.fo("height", 0))]
    let originX = points[0].x
    let originY = points[0].y
    let dropX = if truthy(position): num(position["x"]) else: 0.0
    let dropY = if truthy(position): num(position["y"]) else: 0.0
    var moved: seq[Pt]
    for p in points: moved.add pt(dropX + (p.x - originX), dropY + (p.y - originY))
    definition["previewPoints"] = ptsVal(moved)
    definition.del("x")
    definition.del("y")
    definition.del("width")
    definition.del("height")
    let edge = g.addEdge(definition, select)
    g.updateWorldSize()
    g.render()
    return edge

  let rootNode = g.addNode(definition, false)
  var layoutIds = @[idOf(rootNode)]
  var created = @[rootNode]

  proc insertChildren(parent: Val, defs: seq[Val]) =
    for d in defs:
      let childData = clone(d)
      var nested: seq[Val]
      if childData["children"].isArr:
        for c in childData["children"]: nested.add c
      childData.del("children")
      childData["x"] = jnum(nodeX(parent) + childData.nor("x", 0))
      childData["y"] = jnum(nodeY(parent) + childData.nor("y", 0))
      childData["containerId"] = parent["id"]
      let child = g.addNode(childData, false)
      parent["container"] = jtrue
      created.add child
      if nested.len > 0:
        layoutIds.add idOf(child)
        insertChildren(child, nested)

  insertChildren(rootNode, children)
  g.rendererUpsert(created)
  discard g.layoutStackContainers(layoutIds)
  discard g.extendParentContainersOf(created[1 .. ^1])
  if select: g.setSelection(@[idOf(rootNode)])
  g.updateWorldSize()
  g.render()
  rootNode

# -------------------------------------------------------------- index --

proc registerEdge(g: Graph, edge: Val) =
  let id = idOf(edge)
  for k in ["sourceId", "targetId"]:
    let r = edge.get(k)
    if not truthy(r): continue
    let key = str(r)
    let bucket = addr g.edgesByNode.mgetOrPut(key, @[])
    if not bucket[].contains(id): bucket[].add id

proc unregisterEdge(g: Graph, edge: Val) =
  let id = idOf(edge)
  for k in ["sourceId", "targetId"]:
    let r = edge.get(k)
    if not truthy(r): continue
    let key = str(r)
    if not g.edgesByNode.hasKey(key): continue
    let i = g.edgesByNode[key].find(id)
    if i >= 0: g.edgesByNode[key].delete(i)
    if g.edgesByNode[key].len == 0: g.edgesByNode.del(key)

proc reindex(g: Graph, item: Val) =
  g.index.update(idOf(item), itemBounds(item, g.byId))

proc rebuildIndex*(g: Graph) =
  g.index.clear()
  g.edgesByNode.clear()
  for item in g.items:
    if item.eqs("type", "edge"): g.registerEdge(item)
  for item in g.items: g.reindex(item)

proc reindexNodeAndEdges*(g: Graph, node: Val) =
  g.reindex(node)
  let id = idOf(node)
  if not g.edgesByNode.hasKey(id): return
  for edgeId in g.edgesByNode[id]:
    let e = g.byId.getOrDefault(edgeId, nil)
    if e != nil: g.reindex(e)

proc getItem*(g: Graph, id: string): Val = g.byId.getOrDefault(id, nil)

# ---------------------------------------------------------- selection --

proc effectiveGroup(g: Graph, item: Val): string =
  ## The outermost group of an item that has not been entered ("" if none).
  if item == nil or not item["groups"].isArr: return ""
  for gid in item["groups"]:
    let s = strOrEmpty(gid)
    if not g.enteredGroups.contains(s): return s
  ""

proc setSelection*(g: Graph, ids: seq[string], exact = false) =
  g.tableSelection.active = false
  var requested: seq[string]
  var requestedSet = initHashSet[string]()
  for id in ids:
    if g.byId.hasKey(id) and not requestedSet.containsOrIncl(id): requested.add id
  var selectedGroups = initHashSet[string]()
  if not exact:
    for id in requested:
      let grp = g.effectiveGroup(g.byId[id])
      if grp.len > 0: selectedGroups.incl grp
  if selectedGroups.len > 0:
    for it in g.items:
      let grp = g.effectiveGroup(it)
      if grp.len > 0 and selectedGroups.contains(grp):
        let id = idOf(it)
        if not requestedSet.containsOrIncl(id): requested.add id
  g.selection = requested
  g.drawOverlay()
  g.emitSelection()

proc isSelected*(g: Graph, id: string): bool = g.selection.contains(id)

proc getCell*(g: Graph, node: Val, row, column: int): Val =
  let cells = node["cells"]
  let cell = if cells.isObj: cells.get($row & "," & $column) else: nil
  if nullish(cell): return obj(("text", jstr("")))
  if cell.isStr: return obj(("text", cell))
  cell

proc getSelectedTableCell*(g: Graph): SelectedCell =
  let sel = g.tableSelection
  if not sel.active or g.selection.len != 1 or g.selection[0] != sel.nodeId: return
  let node = g.byId.getOrDefault(sel.nodeId, nil)
  if node == nil or not node.eqs("shape", "table"): return
  let grid = tableGrid(node)
  let startRow = min(sel.row, sel.endRow)
  let endRow = max(sel.row, sel.endRow)
  let startColumn = min(sel.column, sel.endColumn)
  let endColumn = max(sel.column, sel.endColumn)
  if startRow < 0 or startRow >= grid.rows.len or startColumn < 0 or startColumn >= grid.columns.len:
    return
  var width = 0.0
  var height = 0.0
  for c in startColumn .. endColumn:
    if c < grid.columns.len: width += grid.columns[c].size
  for r in startRow .. endRow:
    if r < grid.rows.len: height += grid.rows[r].size
  SelectedCell(found: true, node: node, row: sel.row, column: sel.column,
               cell: g.getCell(node, sel.row, sel.column),
               startRow: startRow, endRow: endRow, startColumn: startColumn,
               endColumn: endColumn, x: grid.columns[startColumn].pos,
               y: grid.rows[startRow].pos, width: width, height: height)

proc selectTableCell*(g: Graph, node: Val, row, column, rowspan, colspan: int, extend = false): bool =
  if node == nil or not node.eqs("shape", "table"): return false
  g.selection = @[idOf(node)]
  let cellEndRow = row + max(1, rowspan) - 1
  let cellEndColumn = column + max(1, colspan) - 1
  if extend and g.tableSelection.active and g.tableSelection.nodeId == idOf(node):
    g.tableSelection.endRow = cellEndRow
    g.tableSelection.endColumn = cellEndColumn
  else:
    g.tableSelection = TableSelection(active: true, nodeId: idOf(node), row: row,
                                      column: column, endRow: cellEndRow, endColumn: cellEndColumn)
  g.drawOverlay()
  g.emitSelection()
  true

proc selectTableCellBox(g: Graph, node: Val, box: CellBox, extend = false): bool =
  g.selectTableCell(node, box.row, box.column, box.rowspan, box.colspan, extend)

proc clearTableCellSelection*(g: Graph, notify = true): bool =
  if not g.tableSelection.active: return false
  g.tableSelection.active = false
  g.drawOverlay()
  if notify: g.emitSelection()
  true

proc encodeURIComponent(s: string): string =
  const safe = {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')'}
  const hexd = "0123456789ABCDEF"
  for c in s:
    if c in safe: result.add c
    else:
      result.add '%'
      result.add hexd[ord(c) shr 4]
      result.add hexd[ord(c) and 15]

proc decodeURIComponent(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      try:
        result.add char(parseHexInt(s[i+1 .. i+2]))
        i += 3
        continue
      except ValueError: discard
    result.add s[i]
    inc i

proc tableStyleTargetId*(nodeId: string, row, column: int): string =
  "@table-cell|" & encodeURIComponent(nodeId) & "|" & $row & "|" & $column


proc parseTableStyleTargetId(id: string): CellTarget =
  let parts = id.split('|')
  if parts.len != 4 or parts[0] != "@table-cell": return
  CellTarget(found: true, nodeId: decodeURIComponent(parts[1]),
             row: int(parseNumStr(parts[2])), column: int(parseNumStr(parts[3])))

proc tableCellsInRange(g: Graph, node: Val, r0, r1, c0, c1: int): seq[CellBox] =
  if node == nil or not node.eqs("shape", "table"): return
  var seen = initHashSet[string]()
  for r in r0 .. r1:
    for c in c0 .. c1:
      let box = tableCellBox(node, float64(r), float64(c))
      let key = $box.row & "," & $box.column
      if seen.containsOrIncl(key): continue
      result.add box

proc tableCellsInSelection(g: Graph, sel: SelectedCell): seq[CellBox] =
  g.tableCellsInRange(sel.node, sel.startRow, sel.endRow, sel.startColumn, sel.endColumn)

proc getStyleTargetIds*(g: Graph, allowed: HashSet[string], filtered: bool): seq[string] =
  ## `allowed` is the set of item ids that pass the page's predicate.
  let sel = g.getSelectedTableCell()
  if sel.found and (not filtered or allowed.contains(idOf(sel.node))):
    for entry in g.tableCellsInSelection(sel):
      result.add tableStyleTargetId(idOf(sel.node), entry.row, entry.column)
    return
  for item in g.getSelection():
    if not filtered or allowed.contains(idOf(item)): result.add idOf(item)

proc toggleSelection*(g: Graph, id: string) =
  let item = g.byId.getOrDefault(id, nil)
  let grp = g.effectiveGroup(item)
  var unit: seq[string]
  if grp.len == 0: unit = @[id]
  else:
    for m in g.getGroupMembers(grp): unit.add idOf(m)
  var ids = g.selection
  var selected = initHashSet[string]()
  for s in ids: selected.incl s
  var remove = true
  for u in unit:
    if not selected.contains(u):
      remove = false
      break
  for u in unit:
    if remove:
      let i = ids.find(u)
      if i >= 0: ids.delete(i)
    elif not ids.contains(u):
      ids.add u
  g.setSelection(ids)

# ------------------------------------------------------------- remove --

proc removeSelection*(g: Graph) =
  if g.selection.len == 0: return
  let sel = g.getSelectedTableCell()
  if sel.found:
    let cellBefore = g.snapshot()
    if truthy(sel.node["cells"]):
      for entry in g.tableCellsInSelection(sel):
        sel.node["cells"].remove($entry.row & "," & $entry.column)
    g.rendererUpsert([sel.node], true)
    g.commit(cellBefore, "Delete Table Cell")
    g.render()
    g.emitSelection()
    return
  let before = g.snapshot()
  var removeOrder: seq[string]
  var remove = initHashSet[string]()
  for id in g.selection:
    let it = g.byId.getOrDefault(id, nil)
    if it != nil and not it.tr("locked") and not remove.containsOrIncl(id): removeOrder.add id
  if remove.len == 0:
    g.toast("Unlock the selection before deleting")
    return
  var grew = true
  while grew:
    grew = false
    for child in g.items:
      if child.tr("containerId") and remove.contains(str(child["containerId"])) and
          not remove.contains(idOf(child)):
        remove.incl idOf(child)
        removeOrder.add idOf(child)
        grew = true
  for item in g.items:
    if item.eqs("type", "edge") and
        ((truthy(item["sourceId"]) and remove.contains(str(item["sourceId"]))) or
         (truthy(item["targetId"]) and remove.contains(str(item["targetId"])))):
      if not remove.containsOrIncl(idOf(item)): removeOrder.add idOf(item)
  var affectedContainers: seq[string]
  for id in removeOrder:
    let removed = g.byId.getOrDefault(id, nil)
    if removed != nil and removed.tr("containerId"):
      let parentId = str(removed["containerId"])
      if not remove.contains(parentId) and not affectedContainers.contains(parentId):
        affectedContainers.add parentId
  var kept: seq[Val]
  for it in g.items:
    if not remove.contains(idOf(it)): kept.add it
  g.items = kept
  for id in removeOrder:
    g.byId.del(id)
    g.index.remove(id)
  g.selection = @[]
  g.rebuildIndex()
  g.rendererRemove(removeOrder)
  discard g.layoutStackContainers(affectedContainers)
  g.commit(before, "Delete")
  g.updateWorldSize()
  g.render()
  g.emit("selectionchange", newArr())

# --------------------------------------------------- copy / paste --

proc copy*(g: Graph) =
  let sel = g.getSelectedTableCell()
  if sel.found:
    g.tableCellClipboard = clone(if truthy(sel.cell): sel.cell else: obj(("text", jstr(""))))
    g.clipboard = @[]
    return
  g.tableCellClipboard = nil
  let selected = g.getSelection()
  var nodes: seq[Val]
  var ids = initHashSet[string]()
  var idOrder: seq[string]
  for it in selected:
    if not it.eqs("type", "edge"):
      nodes.add it
      if not ids.containsOrIncl(idOf(it)): idOrder.add idOf(it)
  let descendants = g.getContainedDescendants(idOrder)
  for d in descendants:
    if not ids.containsOrIncl(idOf(d)): nodes.add d
  var selectedEdges = initHashSet[string]()
  for it in selected:
    if it.eqs("type", "edge"): selectedEdges.incl idOf(it)
  var edges: seq[Val]
  for it in g.items:
    if it.eqs("type", "edge") and (selectedEdges.contains(idOf(it)) or
        (ids.contains(strOrEmpty(it["sourceId"])) and ids.contains(strOrEmpty(it["targetId"])))):
      edges.add it
  g.clipboard = @[]
  for it in clone(itemsVal(nodes & edges)): g.clipboard.add it

proc cut*(g: Graph) =
  g.copy()
  g.removeSelection()

proc boundsOfItems*(g: Graph, items: openArray[Val]): (bool, Rect) =
  var minX = Inf
  var minY = Inf
  var maxX = -Inf
  var maxY = -Inf
  for item in items:
    if item.eqs("type", "edge"):
      var pts: seq[Pt]
      if item.eqs("lineStyle", "circular"):
        let arc = circularArc(item, g.byId)
        pts = if arc.valid: arc.samples else: edgePoints(item, g.byId)
      else: pts = edgePoints(item, g.byId)
      for p in pts:
        minX = jsMin(minX, p.x)
        minY = jsMin(minY, p.y)
        maxX = jsMax(maxX, p.x)
        maxY = jsMax(maxY, p.y)
      continue
    for p in nodeCorners(item):
      minX = jsMin(minX, p.x)
      minY = jsMin(minY, p.y)
      maxX = jsMax(maxX, p.x)
      maxY = jsMax(maxY, p.y)
  if minX == Inf: return (false, Rect())
  (true, rect(minX, minY, maxX - minX, maxY - minY))

proc pasteEdge(g: Graph, source: Val, idMap: Table[string, string], dx, dy: float64): Val =
  let edge = clone(source)
  edge["id"] = jstr(uid("edge"))
  let drawn = edgePoints(source, g.byId)
  proc offset(p: Val): Val =
    if nullish(p): jnull else: ptVal(pt(num(p["x"]) + dx, num(p["y"]) + dy))
  let ends = [("sourceId", "sourceAnchor", "sourcePoint", 0), ("targetId", "targetAnchor", "targetPoint", 1)]
  for (idKey, anchorKey, pointKey, which) in ends:
    let refId = strOrEmpty(source.get(idKey))
    if not nullish(source.get(idKey)) and idMap.hasKey(refId):
      edge.put(idKey, jstr(idMap[refId]))
    else:
      edge.put(idKey, jnull)
      edge.put(anchorKey, jnull)
      let at = if drawn.len == 0: nil
               elif which == 0: ptVal(drawn[0])
               else: ptVal(drawn[^1])
      edge.put(pointKey, offset(if at != nil: at else: source.get(pointKey)))
  let pp = newArr()
  for p in source["previewPoints"]: pp.push offset(p)
  edge["previewPoints"] = pp
  if source["route"].isArr:
    let r = newArr()
    for p in source["route"]: r.push offset(p)
    edge["route"] = r
  g.addEdge(edge, false)

proc paste*(g: Graph, target: Val = nil) =
  let sel = g.getSelectedTableCell()
  if sel.found and g.tableCellClipboard != nil:
    let cellBefore = g.snapshot()
    if not truthy(sel.node["cells"]): sel.node["cells"] = newObj()
    sel.node["cells"].put($sel.row & "," & $sel.column, clone(g.tableCellClipboard))
    g.rendererUpsert([sel.node], true)
    g.commit(cellBefore, "Paste Table Cell")
    g.render()
    g.emitSelection()
    return
  if g.clipboard.len == 0: return
  let before = g.snapshot()
  var idMap = initTable[string, string]()
  var groupMap = initTable[string, string]()
  var created: seq[Val]
  var nodes: seq[Val]
  for it in g.clipboard:
    if not it.eqs("type", "edge"): nodes.add it
  var dx = 30.0
  var dy = 30.0
  if truthy(target):
    let (ok, origin) = g.boundsOfItems(if nodes.len > 0: nodes else: g.clipboard)
    if ok:
      dx = num(target["x"]) - origin.x
      dy = num(target["y"]) - origin.y
  for n in nodes:
    let data = clone(n)
    let oldId = idOf(data)
    idMap[oldId] = uid("node")
    data["id"] = jstr(idMap[oldId])
    data["x"] = jnum(num(data["x"]) + dx)
    data["y"] = jnum(num(data["y"]) + dy)
    if data.tr("containerId") and not idMap.hasKey(str(data["containerId"])): data.del("containerId")
    discard normalizeGroups(data)
    if data["groups"].isArr:
      let mapped = newArr()
      for grp in data["groups"]:
        let key = str(grp)
        if not groupMap.hasKey(key): groupMap[key] = uid("group")
        mapped.push jstr(groupMap[key])
      data["groups"] = mapped
      data["groupId"] = mapped[0]
    created.add g.addNode(data, false)
  for i in 0 ..< created.len:
    let originalNode = nodes[i]
    if originalNode.tr("containerId") and idMap.hasKey(str(originalNode["containerId"])):
      created[i]["containerId"] = jstr(idMap[str(originalNode["containerId"])])
  for e in g.clipboard:
    if e.eqs("type", "edge"): created.add g.pasteEdge(e, idMap, dx, dy)
  var ids: seq[string]
  for c in created: ids.add idOf(c)
  g.setSelection(ids)
  g.commit(before, "Paste")

proc duplicate*(g: Graph) =
  g.copy()
  g.paste()

# ---------------------------------------------------------------- z --

proc changeZ*(g: Graph, front: bool) =
  if g.getSelectedTableCell().found: return
  var selected = g.expandToGroups(g.getSelection())
  if selected.len == 0: return
  let before = g.snapshot()
  var order = initTable[string, int]()
  for i, it in g.items: order[idOf(it)] = i
  selected.sort(proc (a, b: Val): int =
    let delta = a.fo("z", 0) - b.fo("z", 0)
    if delta != 0: (if delta < 0: -1 else: 1)
    else: cmp(order.getOrDefault(idOf(a), 0), order.getOrDefault(idOf(b), 0)))
  var selectedIds = initHashSet[string]()
  for it in selected: selectedIds.incl idOf(it)
  var values: seq[float64]
  for it in g.items:
    if not selectedIds.contains(idOf(it)): values.add it.fo("z", 0)
  var z: float64
  if front:
    z = 0
    for v in values: z = jsMax(z, v)
    z += 1
  else:
    z = 0
    for v in values: z = jsMin(z, v)
    z -= float64(selected.len)
  for i, it in selected: it["z"] = jnum(z + float64(i))
  g.rendererUpsert(selected)
  g.commit(before, if front: "To Front" else: "To Back")
  g.render()

# ------------------------------------------------------------ styles --

proc applyChanges(item, changes: Val) =
  for (key, value) in changes.pairs:
    if value == nil: item.remove(key)
    else: item.put(key, value)

proc applyTableCellStyle*(g: Graph, node: Val, row, column: int, changes: Val): Val =
  if node == nil or not node.eqs("shape", "table"): return nil
  if not truthy(node["cells"]): node["cells"] = newObj()
  let key = $row & "," & $column
  let existing = node["cells"].get(key)
  let cell = clone(if truthy(existing): existing else: obj(("text", jstr(""))))
  let cellObj = if cell.isStr: obj(("text", cell)) else: cell
  for (property, value) in changes.pairs:
    let target = if property == "textAlign": "align" else: property
    if property == "width":
      g.setTableTrackSize(node, "column", column, value)
    elif property == "height":
      g.setTableTrackSize(node, "row", row, value)
    elif property notin ["x", "y", "rotation", "shape", "lineStyle", "startArrow", "endArrow", "arrowSize"]:
      if value == nil: cellObj.remove(target)
      else: cellObj.put(target, value)
  node["cells"].put(key, cellObj)
  cellObj

proc setTableTrackSize(g: Graph, node: Val, axis: string, index: int, value0: Val) =
  var value = jsMax(18, (let v = num(value0); if v == v and v != 0: v else: 18.0))
  let grid = tableGrid(node)
  let tracks = if axis == "column": grid.columns else: grid.rows
  if index < 0 or index >= tracks.len: return
  let total = if axis == "column": nodeW(node) else: jsMax(0, nodeH(node) - grid.titleHeight)
  value = jsMin(value, jsMax(18, total - 18 * float64(tracks.len - 1)))
  let remaining = jsMax(0, total - value)
  var otherTotal = 0.0
  for i, t in tracks:
    if i != index: otherTotal += t.size
  if otherTotal == 0 or otherTotal != otherTotal: otherTotal = float64(max(1, tracks.len - 1))
  let weights = newArr()
  for i, t in tracks:
    weights.push jnum(if i == index: value else: remaining * t.size / otherTotal)
  if axis == "column": node["columnWeights"] = weights
  else: node["rowWeights"] = weights

proc normalizeCircularEdge*(g: Graph, edge: Val): Val =
  if edge == nil or not edge.eqs("type", "edge") or not edge.eqs("lineStyle", "circular"): return edge
  edge["route"] = jnull
  let points = edgePoints(edge, g.byId)
  let closed = points.len > 0 and hypot(points[^1].x - points[0].x, points[^1].y - points[0].y) < 0.01
  var sweep = abs(num(edge["arcSweep"]))
  if not isFiniteNum(sweep) or sweep < 1: sweep = if closed: 360.0 else: 180.0
  edge["arcSweep"] = jnum(clamp(sweep, 1, if closed: 360.0 else: 180.0))
  edge["arcSide"] = jnum(if num(edge["arcSide"]) < 0: -1.0 else: 1.0)
  let r = abs(num(edge["circleRadius"]))
  edge["circleRadius"] = jnum(clamp(if r == r and r != 0: r else: 60.0, 5, 10000))
  edge

proc applyStyle*(g: Graph, changes: Val, label = "", allowed: HashSet[string], filtered: bool) =
  var selected: seq[Val]
  for it in g.getSelection():
    if not filtered or allowed.contains(idOf(it)): selected.add it
  if selected.len == 0: return
  let before = g.snapshot()
  let sel = g.getSelectedTableCell()
  if sel.found and selected.contains(sel.node):
    for entry in g.tableCellsInSelection(sel):
      discard g.applyTableCellStyle(sel.node, entry.row, entry.column, changes)
    g.rendererUpsert([sel.node], true)
    g.commit(before, if label.len > 0: label else: "Format Table Cell")
    g.render()
    g.emitSelection()
    return
  for it in selected:
    applyChanges(it, changes)
    discard g.normalizeCircularEdge(it)
    g.reindex(it)
  g.rendererUpsert(selected)
  g.commit(before, if label.len > 0: label else: "Format")
  g.render()
  g.emitSelection()

proc applyStyleAll*(g: Graph, changes: Val, label = "") =
  g.applyStyle(changes, label, initHashSet[string](), false)

proc replaceShape*(g: Graph, targets: seq[Val], templ: Val, label = ""): seq[Val] =
  let definition = clone(if truthy(templ): templ else: newObj())
  definition.del("children")
  let wantsEdge = definition.eqs("type", "edge")
  var list: seq[Val]
  for item in targets:
    if item == nil: continue
    if item.eqs("type", "edge") != wantsEdge: continue
    if g.isLayerLocked(item) or item.tr("locked"): continue
    list.add item
  if list.len == 0: return
  let before = g.snapshot()
  var keep = @SHAPE_KEEP_STYLE & @SHAPE_KEEP_CONTENT
  if wantsEdge: keep.add @SHAPE_KEEP_EDGE_STYLE
  for target in list:
    let next = clone(definition)
    for k in SHAPE_KEEP_PLACEMENT: next.remove(k)
    for k in keep:
      let v = target.get(k)
      if v != nil: next.put(k, v)
    if not wantsEdge:
      next["kind"] = if definition.tr("kind"): definition["kind"] else: jstr("shape")
      next["shape"] = if definition.tr("shape"): definition["shape"] else: jstr("rect")
    for key in target.keys():
      if not SHAPE_KEEP_PLACEMENT.contains(key) and next.get(key) == nil:
        target.remove(key)
    assign(target, next)
    discard normalizeGroups(target)
    discard normalizeHtml(target)
    if target.eqs("type", "edge"): discard g.normalizeCircularEdge(target)
    g.reindexNodeAndEdges(target)
  g.rendererUpsert(list)
  g.commit(before, if label.len > 0: label else: "Change Shape")
  g.updateWorldSize()
  g.render()
  g.emitSelection()
  list

proc previewStyle*(g: Graph, ids: seq[string], changes: Val): seq[Val] =
  var items: seq[Val]
  for id in ids:
    let target = parseTableStyleTargetId(id)
    if target.found:
      let table = g.byId.getOrDefault(target.nodeId, nil)
      if table != nil:
        discard g.applyTableCellStyle(table, target.row, target.column, changes)
        if not items.contains(table): items.add table
      continue
    let item = g.byId.getOrDefault(id, nil)
    if item == nil: continue
    applyChanges(item, changes)
    discard g.normalizeCircularEdge(item)
    g.reindexNodeAndEdges(item)
    items.add item
  if items.len == 0: return items
  g.rendererUpsert(items)
  g.updateWorldSize()
  g.render()
  items

proc commitPreview*(g: Graph, before: string, label = "") =
  g.commit(before, if label.len > 0: label else: "Format")
  g.emitSelection()

proc getCommonStyle*(g: Graph, key: string, fallback: Val): Val =
  let sel = g.getSelectedTableCell()
  if sel.found:
    let cell = if truthy(sel.cell): sel.cell else: newObj()
    let property = if key == "textAlign": "align" else: key
    if key == "x": return jnum(sel.x)
    if key == "y": return jnum(sel.y)
    if key == "width": return jnum(sel.width)
    if key == "height": return jnum(sel.height)
    if not nullish(cell.get(property)): return cell.get(property)
    if key == "align" or key == "textAlign":
      return if truthy(sel.node["cellAlign"]): sel.node["cellAlign"] else: fallback
    if key == "fill": return if truthy(sel.node["fill"]): sel.node["fill"] else: fallback
    if key == "stroke":
      if truthy(sel.node["gridStroke"]): return sel.node["gridStroke"]
      if truthy(sel.node["stroke"]): return sel.node["stroke"]
      return fallback
    let v = sel.node.get(key)
    return if nullish(v): fallback else: v
  let selected = g.getSelection()
  if selected.len == 0: return fallback
  let value = selected[0].get(key)
  for i in 1 ..< selected.len:
    if not strictEq(selected[i].get(key), value): return jstr("")
  if nullish(value): fallback else: value

proc selectByType*(g: Graph, kind: string, any: bool) =
  var ids: seq[string]
  for it in g.items:
    if any or it.eqs("type", kind): ids.add idOf(it)
  g.setSelection(ids)

# ------------------------------------------------------------ groups --

proc expandToGroups(g: Graph, items: seq[Val]): seq[Val] =
  var ids: seq[string]
  var idSet = initHashSet[string]()
  var groups = initHashSet[string]()
  for it in items:
    let grp = g.effectiveGroup(it)
    if grp.len > 0: groups.incl grp
    elif not idSet.containsOrIncl(idOf(it)): ids.add idOf(it)
  if groups.len > 0:
    for it in g.items:
      let grp = g.effectiveGroup(it)
      if grp.len > 0 and groups.contains(grp) and not idSet.containsOrIncl(idOf(it)):
        ids.add idOf(it)
  for id in ids:
    let it = g.byId.getOrDefault(id, nil)
    if it != nil: result.add it

proc getGroupMembers*(g: Graph, groupId: string): seq[Val] =
  for it in g.items:
    if g.effectiveGroup(it) == groupId: result.add it

proc groupFrame(g: Graph, b: Rect): Rect =
  let pad = 7 / g.zoom
  rect(b.x - pad, b.y - pad, b.width + pad * 2, b.height + pad * 2)

proc getSelectedGroups*(g: Graph): seq[GroupInfo] =
  var selectedIds = initHashSet[string]()
  for s in g.selection: selectedIds.incl s
  var order: seq[string]
  var byGroup = initTable[string, seq[Val]]()
  for it in g.items:
    let grp = g.effectiveGroup(it)
    if grp.len == 0: continue
    if not byGroup.hasKey(grp):
      byGroup[grp] = @[]
      order.add grp
    byGroup[grp].add it
  for grp in order:
    let members = byGroup[grp]
    var complete = true
    for m in members:
      if not selectedIds.contains(idOf(m)):
        complete = false
        break
    if not complete: continue
    let (ok, b) = g.boundsOfItems(members)
    if ok: result.add GroupInfo(id: grp, items: members, bounds: b)

proc groupFrameAt(g: Graph, p: Pt): (bool, GroupInfo) =
  var best: GroupInfo
  var found = false
  var bestZ = -Inf
  var seen = initHashSet[string]()
  for it in g.items:
    let grp = g.effectiveGroup(it)
    if grp.len == 0 or seen.containsOrIncl(grp): continue
    let members = g.getGroupMembers(grp)
    let (ok, b) = g.boundsOfItems(members)
    if not ok: continue
    let frame = g.groupFrame(b)
    if p.x < frame.x or p.x > frame.x + frame.width or p.y < frame.y or p.y > frame.y + frame.height:
      continue
    var z = 0.0
    for m in members: z = jsMax(z, m.fo("z", 0))
    if z >= bestZ:
      bestZ = z
      best = GroupInfo(id: grp, items: members, bounds: b)
      found = true
  (found, best)

proc getGroupHandles(g: Graph, frame: Rect): seq[Handle] =
  let raw = [pt(frame.x, frame.y), pt(frame.x + frame.width / 2, frame.y),
             pt(frame.x + frame.width, frame.y), pt(frame.x, frame.y + frame.height / 2),
             pt(frame.x + frame.width, frame.y + frame.height / 2), pt(frame.x, frame.y + frame.height),
             pt(frame.x + frame.width / 2, frame.y + frame.height),
             pt(frame.x + frame.width, frame.y + frame.height)]
  const cursors = ["nwse-resize", "ns-resize", "nesw-resize", "ew-resize",
                   "ew-resize", "nesw-resize", "ns-resize", "nwse-resize"]
  for i in 0 ..< raw.len:
    result.add Handle(kind: "groupResize", index: i, point: raw[i], cursor: cursors[i])
  result.add Handle(kind: "groupRotate", index: -1, cursor: "crosshair",
                    point: pt(frame.x + frame.width / 2, frame.y - 28 / g.zoom))

proc enteredDepth(g: Graph, item: Val): int =
  let groups = item["groups"]
  var depth = 0
  while depth < groups.len and g.enteredGroups.contains(strOrEmpty(groups[depth])): inc depth
  depth

proc groupSelection*(g: Graph) =
  var selected: seq[Val]
  for it in g.getSelection():
    if not it.tr("locked"): selected.add it
  if selected.len < 2:
    g.toast("Select at least two objects to group")
    return
  let members = g.expandToGroups(selected)
  let before = g.snapshot()
  let groupId = uid("group")
  for m in members:
    discard normalizeGroups(m)
    if not m["groups"].isArr: m["groups"] = newArr()
    let depth = g.enteredDepth(m)
    m["groups"].a.insert(jstr(groupId), min(depth, m["groups"].a.len))
    discard normalizeGroups(m)
  g.rendererUpsert(members)
  discard g.layoutParentContainersOf(members)
  var ids: seq[string]
  for m in members: ids.add idOf(m)
  g.setSelection(ids)
  g.commit(before, "Group")
  g.render()
  g.toast("Grouped " & $members.len & " objects")

proc ungroupSelection*(g: Graph) =
  var groups = initHashSet[string]()
  for it in g.getSelection():
    let grp = g.effectiveGroup(it)
    if grp.len > 0: groups.incl grp
  if groups.len == 0:
    g.toast("Selection is not a group")
    return
  var affected: seq[Val]
  for it in g.items:
    let grp = g.effectiveGroup(it)
    if grp.len > 0 and groups.contains(grp): affected.add it
  let before = g.snapshot()
  for a in affected:
    let grp = g.effectiveGroup(a)
    let index = a["groups"].indexOfStr(grp)
    if index >= 0: a["groups"].a.delete(index)
    discard normalizeGroups(a)
  g.rendererUpsert(affected)
  discard g.layoutParentContainersOf(affected)
  var ids: seq[string]
  for a in affected: ids.add idOf(a)
  g.setSelection(ids)
  g.commit(before, "Ungroup")
  g.render()
  g.toast("Ungrouped " & $affected.len & " objects")

proc enterGroup*(g: Graph) =
  let groups = g.getSelectedGroups()
  if groups.len != 1:
    g.toast("Select a single group to enter")
    return
  g.enteredGroups.add groups[0].id
  let children = groups[0].items
  let inner = g.effectiveGroup(children[0])
  var ids: seq[string]
  if inner.len > 0:
    for m in g.getGroupMembers(inner): ids.add idOf(m)
  else: ids = @[idOf(children[0])]
  g.setSelection(ids)
  g.toast("Entered group")

proc exitGroup*(g: Graph) =
  if g.enteredGroups.len == 0:
    g.toast("Not inside a group")
    return
  let grp = g.enteredGroups.pop()
  var ids: seq[string]
  for m in g.getGroupMembers(grp): ids.add idOf(m)
  g.setSelection(ids)
  g.toast("Left group")

proc removeFromGroup*(g: Graph) =
  var selected: seq[Val]
  for it in g.getSelection():
    if g.effectiveGroup(it).len > 0: selected.add it
  if selected.len == 0:
    g.toast("Selection is not in a group")
    return
  let before = g.snapshot()
  for s in selected:
    let index = s["groups"].indexOfStr(g.effectiveGroup(s))
    if index >= 0: s["groups"].a.delete(index)
    discard normalizeGroups(s)
  g.rendererUpsert(selected)
  discard g.layoutParentContainersOf(selected)
  g.commit(before, "Remove from Group")
  g.render()
  g.emitSelection()
  g.toast("Removed " & $selected.len & " from the group")

# ------------------------------------------------------------ layers --

proc getLayer*(g: Graph, id: string): Val =
  for layer in g.layers:
    if strOrEmpty(layer["id"]) == id: return layer
  nil

proc getLayerOf(g: Graph, item: Val): Val =
  if item == nil: return nil
  let l = item["layer"]
  if nullish(l): nil else: g.getLayer(str(l))

proc addLayer*(g: Graph, name: string): Val =
  let layer = obj(("id", jstr(uid("layer"))),
                  ("name", jstr(if name.len > 0: name else: "Layer " & $(g.layers.len + 1))),
                  ("visible", jtrue), ("locked", jfalse))
  let before = g.snapshot()
  g.layers.push layer
  g.activeLayer = idOf(layer)
  g.commit(before, "Add Layer")
  g.emit("layerchange", g.layers)
  layer

proc removeLayer*(g: Graph, id: string) =
  if g.layers.len <= 1:
    g.toast("The last layer cannot be removed")
    return
  let before = g.snapshot()
  var doomed: seq[string]
  for it in g.items:
    if strOrEmpty(it["layer"]) == id and not nullish(it["layer"]): doomed.add idOf(it)
  let kept = newArr()
  for layer in g.layers:
    if strOrEmpty(layer["id"]) != id: kept.push layer
  g.layers = kept
  if doomed.len > 0:
    var removed = initHashSet[string]()
    for d in doomed: removed.incl d
    var items: seq[Val]
    for it in g.items:
      if not removed.contains(idOf(it)): items.add it
    g.items = items
    for d in doomed: g.byId.del(d)
    var sel: seq[string]
    for s in g.selection:
      if not removed.contains(s): sel.add s
    g.selection = sel
    g.rebuildIndex()
    g.rendererRemove(doomed)
  if g.activeLayer == id: g.activeLayer = strOrEmpty(g.layers[0]["id"])
  g.commit(before, "Remove Layer")
  g.render()
  g.emit("layerchange", g.layers)
  g.emitSelection()

proc updateLayer*(g: Graph, id: string, changes: Val) =
  let layer = g.getLayer(id)
  if layer == nil: return
  let before = g.snapshot()
  for (k, v) in changes.pairs: layer.put(k, v)
  if changes["visible"].isFalse or changes["locked"].isTrue:
    var sel: seq[string]
    for s in g.selection:
      let it = g.byId.getOrDefault(s, nil)
      if it != nil and strOrEmpty(it["layer"]) != id: sel.add s
    g.selection = sel
    g.emitSelection()
  g.commit(before, "Layer")
  g.render()
  g.emit("layerchange", g.layers)

proc applyLayerOrder(g: Graph) =
  var order = initTable[string, int]()
  for i, layer in g.layers.a: order[strOrEmpty(layer["id"])] = i
  var changed: seq[Val]
  for it in g.items:
    let key = strOrEmpty(it["layer"])
    let band = if nullish(it["layer"]) or not order.hasKey(key): 0 else: order[key]
    it["z"] = jnum(float64(band) * 10000 + jsMod(it.fo("z", 0), 10000))
    changed.add it
  g.rendererUpsert(changed)

proc moveLayer*(g: Graph, id: string, delta: int) =
  var index = -1
  for i, layer in g.layers.a:
    if strOrEmpty(layer["id"]) == id:
      index = i
      break
  let target = index + delta
  if index < 0 or target < 0 or target >= g.layers.len: return
  let before = g.snapshot()
  let moved = g.layers.a[index]
  g.layers.a.delete(index)
  g.layers.a.insert(moved, target)
  g.applyLayerOrder()
  g.commit(before, "Reorder Layers")
  g.render()
  g.emit("layerchange", g.layers)

proc moveSelectionToLayer*(g: Graph, id: string) =
  let selected = g.getSelection()
  if selected.len == 0 or g.getLayer(id) == nil:
    g.toast("Select objects to move to a layer")
    return
  let before = g.snapshot()
  for s in selected: s["layer"] = jstr(id)
  g.applyLayerOrder()
  g.rendererUpsert(selected)
  g.commit(before, "Move to Layer")
  g.render()
  g.toast("Moved " & $selected.len & " to " & str(g.getLayer(id)["name"]))

proc isLayerLocked*(g: Graph, item: Val): bool =
  let layer = g.getLayerOf(item)
  layer != nil and layer["locked"].isTrue

# ----------------------------------------------------------- folding --

proc toggleFoldGroup(g: Graph, group: GroupInfo) =
  let before = g.snapshot()
  let placeholderId = "fold-" & group.id
  let existing = g.byId.getOrDefault(placeholderId, nil)
  if existing != nil:
    var members: seq[Val]
    for it in g.items:
      if strOrEmpty(it["foldedBy"]) == group.id and not nullish(it["foldedBy"]): members.add it
    for m in members:
      m.del("foldedAway")
      m.del("foldedBy")
    var kept: seq[Val]
    for it in g.items:
      if idOf(it) != placeholderId: kept.add it
    g.items = kept
    g.byId.del(placeholderId)
    g.index.remove(placeholderId)
    g.rendererRemove([placeholderId])
    g.rendererUpsert(members)
    var ids: seq[string]
    for m in members: ids.add idOf(m)
    g.setSelection(ids)
    g.commit(before, "Expand Group")
    g.updateWorldSize()
    g.render()
    g.toast("Expanded group")
    return
  let b = group.bounds
  var z = -Inf
  for it in group.items: z = jsMax(z, it.fo("z", 0))
  let placeholder = obj(("id", jstr(placeholderId)), ("type", jstr("node")), ("kind", jstr("shape")),
    ("shape", jstr("rect")), ("x", jnum(b.x)), ("y", jnum(b.y)), ("width", jnum(max(120.0, b.width))),
    ("height", jnum(40)), ("rotation", jnum(0)), ("fill", jstr("#f2f5f9")), ("stroke", jstr("#7b8494")),
    ("strokeWidth", jnum(1.5)), ("radius", jnum(4)), ("text", jstr($group.items.len & " objects")),
    ("textColor", jstr("#3d4653")), ("fontSize", jnum(12)), ("collapsible", jtrue),
    ("collapsed", jtrue), ("foldOf", jstr(group.id)), ("layer", group.items[0]["layer"]),
    ("z", jnum(z)), ("visible", jtrue))
  for it in group.items:
    it["foldedAway"] = jtrue
    it["foldedBy"] = jstr(group.id)
  g.items.add placeholder
  g.byId[placeholderId] = placeholder
  g.reindex(placeholder)
  g.rendererUpsert(group.items & @[placeholder])
  g.setSelection(@[placeholderId])
  g.commit(before, "Collapse Group")
  g.updateWorldSize()
  g.render()
  g.toast("Collapsed group")

proc toggleFold*(g: Graph) =
  let groups = g.getSelectedGroups()
  if groups.len == 1:
    g.toggleFoldGroup(groups[0])
    return
  let selected = g.getSelection()
  if selected.len == 1 and not selected[0].eqs("type", "edge") and selected[0].tr("collapsible"):
    g.toggleContainerFold(selected[0])
    return
  g.toast("Select a group to collapse")

proc toggleContainerFold*(g: Graph, node: Val) =
  if node == nil or node.eqs("type", "edge") or not node.tr("collapsible"): return
  let before = g.snapshot()
  let collapsing = not node["collapsed"].isTrue
  let descendants = g.getContainedDescendants(@[idOf(node)])
  var descendantIds = initHashSet[string]()
  for d in descendants: descendantIds.incl idOf(d)
  var affected = descendants
  for it in g.items:
    if it.eqs("type", "edge") and (descendantIds.contains(strOrEmpty(it["sourceId"])) or
        descendantIds.contains(strOrEmpty(it["targetId"]))):
      affected.add it
  let nodeId = idOf(node)
  if collapsing:
    node["expandedWidth"] = node["width"]
    node["expandedHeight"] = node["height"]
    node["collapsed"] = jtrue
    let header = jsMax(0, node.nn("headerHeight", 26))
    if node["horizontal"].isFalse: node["width"] = jnum(jsMin(nodeW(node), header))
    else: node["height"] = jnum(jsMin(nodeH(node), header))
    for a in affected:
      let owners = if a["containerFoldOwners"].isArr: a["containerFoldOwners"] else: newArr()
      if owners.indexOfStr(nodeId) < 0: owners.push jstr(nodeId)
      a["containerFoldOwners"] = owners
      a["foldedAway"] = jtrue
  else:
    node["collapsed"] = jfalse
    if node.nm("expandedWidth") > 0: node["width"] = jnum(node.nm("expandedWidth"))
    if node.nm("expandedHeight") > 0: node["height"] = jnum(node.nm("expandedHeight"))
    node.del("expandedWidth")
    node.del("expandedHeight")
    for a in affected:
      let foldOwners = newArr()
      if a["containerFoldOwners"].isArr:
        for o in a["containerFoldOwners"]:
          if not isStrVal(o, nodeId): foldOwners.push o
      if foldOwners.len > 0: a["containerFoldOwners"] = foldOwners
      else: a.del("containerFoldOwners")
      if foldOwners.len == 0 and not a.tr("foldedBy"): a.del("foldedAway")
  g.reindexNodeAndEdges(node)
  for a in affected: g.reindex(a)
  g.rendererUpsert(@[node] & affected, true)
  var layoutIds = @[nodeId]
  if node.tr("containerId"): layoutIds.add str(node["containerId"])
  discard g.layoutStackContainers(layoutIds)
  g.setSelection(@[nodeId])
  g.commit(before, if collapsing: "Collapse Container" else: "Expand Container")
  g.updateWorldSize()
  g.render()
  g.toast(if collapsing: "Collapsed container" else: "Expanded container")

# ------------------------------------------------------------ tables --

proc tableCellAtWorld*(g: Graph, node: Val, world: Pt): (bool, CellBox) =
  if node == nil or not node.eqs("shape", "table"): return (false, CellBox())
  let local = rotatePoint(world, nodeCenter(node), -rot(node))
  tableCellAt(node, local)

proc tableRowAt(g: Graph, node: Val, world: Pt): int =
  if node == nil or not node.eqs("shape", "table"): return -1
  let local = rotatePoint(world, nodeCenter(node), -rot(node))
  let rows = tableGrid(node).rows
  if rows.len == 0: return -1
  for r in 0 ..< rows.len:
    if local.y >= rows[r].pos and local.y < rows[r].pos + rows[r].size: return r
  if local.y < rows[0].pos: return 0
  rows.len - 1

proc setCell*(g: Graph, node: Val, row, column: int, value: Val, label = "") =
  let before = g.snapshot()
  if nullish(node["cells"]): node["cells"] = newObj()
  let key = $row & "," & $column
  if nullish(value) or (isStrVal(value["text"], "") and nullish(value["richText"])):
    node["cells"].remove(key)
  else:
    node["cells"].put(key, value)
  g.rendererUpsert([node])
  g.commit(before, if label.len > 0: label else: "Edit Cell")
  g.render()

proc resolveTable*(g: Graph, table: Val): Val =
  let node = if table.isStr: g.byId.getOrDefault(table.s, nil) else: table
  if node != nil and node.eqs("shape", "table"): node else: nil

proc resizeWeights(weights: Val, count: int): seq[float64] =
  if weights.isArr:
    for i in 0 ..< min(count, weights.len): result.add num(weights[i])
  while result.len < count:
    result.add(if result.len > 0: result[^1] else: 1.0)

proc weightsVal(w: seq[float64]): Val =
  result = newArr()
  for x in w: result.push jnum(x)

proc createTable*(g: Graph, options0: Val): Val =
  let options = clone(if truthy(options0): options0 else: newObj())
  let select = not options["select"].isFalse
  options.del("select")
  let rows = max(1.0, options.nor("rows", 3))
  let columns = max(1.0, options.nor("columns", 3))
  let inputCells = options["cells"]
  var cells = newObj()
  if inputCells.isArr:
    var r = 0
    while r < inputCells.len and float64(r) < rows:
      let rowVal = inputCells[r]
      var c = 0
      while rowVal.isArr and c < rowVal.len and float64(c) < columns:
        let value = rowVal[c]
        cells.put($r & "," & $c, if value.isObj or value.isArr: clone(value)
                                 else: obj(("text", jstr(strOrEmpty(value)))))
        inc c
      inc r
  elif inputCells.isObj:
    cells = clone(inputCells)
  options.del("cells")
  let before = g.snapshot()
  var rw = newArr()
  for i in 0 ..< int(rows): rw.push jnum(1)
  var cw = newArr()
  for i in 0 ..< int(columns): cw.push jnum(1)
  let data = obj(("type", jstr("node")), ("kind", jstr("table")), ("shape", jstr("table")),
    ("sourceType", jstr("htmlTable")), ("x", jnum(120)), ("y", jnum(100)),
    ("width", jnum(max(80.0, columns * 90))), ("height", jnum(max(50.0, rows * 36))),
    ("text", jstr("")), ("rows", jnum(rows)), ("columns", jnum(columns)),
    ("rowWeights", rw), ("columnWeights", cw), ("tableBorder", jnum(1)),
    ("gridStroke", jstr("#4a5564")), ("reorderRows", jtrue), ("cells", cells))
  assign(data, options)
  data["rows"] = jnum(rows)
  data["columns"] = jnum(columns)
  data["cells"] = cells
  let node = g.addNode(data, select)
  g.commit(before, "Create Table")
  node

proc getTableCell*(g: Graph, table: Val, row, column: float64): Val =
  let node = g.resolveTable(table)
  if node == nil: return nil
  let box = tableCellBox(node, row, column)
  result = obj(("tableId", node["id"]), ("row", jnum(box.row)), ("column", jnum(box.column)),
               ("rowspan", jnum(box.rowspan)), ("colspan", jnum(box.colspan)))
  assign(result, clone(g.getCell(node, box.row, box.column)))

proc setTableCell*(g: Graph, table: Val, row, column: float64, value, style: Val): bool =
  let node = g.resolveTable(table)
  if node == nil: return false
  let box = tableCellBox(node, row, column)
  let before = g.snapshot()
  if not truthy(node["cells"]): node["cells"] = newObj()
  var cell = clone(g.getCell(node, box.row, box.column))
  if value.isObj and nullish(style):
    assign(cell, clone(value))
  else:
    cell["text"] = jstr(strOrEmpty(value))
    if style.isObj: assign(cell, clone(style))
  node["cells"].put($box.row & "," & $box.column, cell)
  g.rendererUpsert([node], true)
  g.commit(before, "Set Table Cell")
  g.render()
  true

proc renumberTableRows(g: Graph, node: Val) =
  if node == nil or node.nul("rowIndexColumn"): return
  if not truthy(node["cells"]): node["cells"] = newObj()
  let column = int(jsMax(0, jsMin(node.nm("columns") - 1, node.nor("rowIndexColumn", 0))))
  for r in 0 ..< int(node.nm("rows")):
    let box = tableCellBox(node, float64(r), float64(column))
    if box.row != r or box.column != column: continue
    let cell = clone(g.getCell(node, r, column))
    cell["text"] = jstr($(r + 1))
    if not cell.tr("align"): cell["align"] = jstr("center")
    node["cells"].put($r & "," & $column, cell)

proc remapCells(node: Val, fn: proc (row, column: var float64, cell: Val): bool): Val =
  ## Rebuilds node.cells; fn may move a cell or return false to drop it.
  result = newObj()
  let cells = node["cells"]
  if not cells.isObj: return
  for key in cells.keys():
    var (row, column) = parseCellKey(key)
    var cell = clone(cells.get(key))
    if cell.isStr: cell = obj(("text", cell))
    if not fn(row, column, cell): continue
    result.put(jsNumStr(row) & "," & jsNumStr(column), cell)

proc insertTableRow*(g: Graph, table: Val, index0: Val): bool =
  let node = g.resolveTable(table)
  if node == nil: return false
  let rows = max(1.0, node.nor("rows", 1))
  let index = jsMax(0, jsMin(rows, if nullish(index0): rows else: num(index0)))
  let before = g.snapshot()
  let next = remapCells(node, proc (row, column: var float64, cell: Val): bool =
    let span = max(1.0, cell.nor("rowspan", 1))
    if row >= index: row += 1
    elif row < index and row + span > index: cell["rowspan"] = jnum(span + 1)
    true)
  node["rows"] = jnum(rows + 1)
  node["cells"] = next
  var weights = resizeWeights(node["rowWeights"], int(rows))
  let ri = int(jsMax(0, jsMin(float64(weights.len - 1), index - 1)))
  let reference = if weights.len > 0 and truthy(jnum(weights[ri])): weights[ri] else: 1.0
  weights.insert(reference, min(int(index), weights.len))
  node["rowWeights"] = weightsVal(weights)
  g.renumberTableRows(node)
  g.rendererUpsert([node], true)
  g.commit(before, "Insert Table Row")
  discard g.selectTableCellBox(node, tableCellBox(node, index, 0))
  g.render()
  true

proc deleteTableRow*(g: Graph, table: Val, index0: Val): bool =
  let node = g.resolveTable(table)
  if node == nil or node.nm("rows") <= 1: return false
  let rows = node.nm("rows")
  let index = jsMax(0, jsMin(rows - 1, if nullish(index0): rows - 1 else: num(index0)))
  let before = g.snapshot()
  let next = remapCells(node, proc (row, column: var float64, cell: Val): bool =
    let span = max(1.0, cell.nor("rowspan", 1))
    if row > index: row -= 1
    elif row == index:
      if span <= 1: return false
      cell["rowspan"] = jnum(span - 1)
    elif row < index and row + span > index:
      cell["rowspan"] = jnum(span - 1)
    if cell.nm("rowspan") <= 1: cell.del("rowspan")
    true)
  node["rows"] = jnum(rows - 1)
  node["cells"] = next
  var weights = resizeWeights(node["rowWeights"], int(rows))
  if int(index) < weights.len: weights.delete(int(index))
  node["rowWeights"] = weightsVal(weights)
  g.renumberTableRows(node)
  g.rendererUpsert([node], true)
  g.commit(before, "Delete Table Row")
  discard g.selectTableCellBox(node, tableCellBox(node, jsMin(index, node.nm("rows") - 1), 0))
  g.render()
  true

proc insertTableColumn*(g: Graph, table: Val, index0: Val): bool =
  let node = g.resolveTable(table)
  if node == nil: return false
  let columns = max(1.0, node.nor("columns", 1))
  let index = jsMax(0, jsMin(columns, if nullish(index0): columns else: num(index0)))
  let before = g.snapshot()
  let next = remapCells(node, proc (row, column: var float64, cell: Val): bool =
    let span = max(1.0, cell.nor("colspan", 1))
    if column >= index: column += 1
    elif column < index and column + span > index: cell["colspan"] = jnum(span + 1)
    true)
  node["columns"] = jnum(columns + 1)
  node["cells"] = next
  var weights = resizeWeights(node["columnWeights"], int(columns))
  let ri = int(jsMax(0, jsMin(float64(weights.len - 1), index - 1)))
  let reference = if weights.len > 0 and truthy(jnum(weights[ri])): weights[ri] else: 1.0
  weights.insert(reference, min(int(index), weights.len))
  node["columnWeights"] = weightsVal(weights)
  if not node.nul("rowIndexColumn") and index <= node.nm("rowIndexColumn"):
    node["rowIndexColumn"] = jnum(node.nm("rowIndexColumn") + 1)
  g.rendererUpsert([node], true)
  g.commit(before, "Insert Table Column")
  discard g.selectTableCellBox(node, tableCellBox(node, 0, index))
  g.render()
  true

proc deleteTableColumn*(g: Graph, table: Val, index0: Val): bool =
  let node = g.resolveTable(table)
  if node == nil or node.nm("columns") <= 1: return false
  let columns = node.nm("columns")
  let index = jsMax(0, jsMin(columns - 1, if nullish(index0): columns - 1 else: num(index0)))
  let before = g.snapshot()
  let next = remapCells(node, proc (row, column: var float64, cell: Val): bool =
    let span = max(1.0, cell.nor("colspan", 1))
    if column > index: column -= 1
    elif column == index:
      if span <= 1: return false
      cell["colspan"] = jnum(span - 1)
    elif column < index and column + span > index:
      cell["colspan"] = jnum(span - 1)
    if cell.nm("colspan") <= 1: cell.del("colspan")
    true)
  node["columns"] = jnum(columns - 1)
  node["cells"] = next
  var weights = resizeWeights(node["columnWeights"], int(columns))
  if int(index) < weights.len: weights.delete(int(index))
  node["columnWeights"] = weightsVal(weights)
  if not node.nul("rowIndexColumn"):
    if index < node.nm("rowIndexColumn"): node["rowIndexColumn"] = jnum(node.nm("rowIndexColumn") - 1)
    elif index == node.nm("rowIndexColumn"): node["rowIndexColumn"] = jnull
  g.rendererUpsert([node], true)
  g.commit(before, "Delete Table Column")
  discard g.selectTableCellBox(node, tableCellBox(node, 0, jsMin(index, node.nm("columns") - 1)))
  g.render()
  true

proc mergeTableCells*(g: Graph, table: Val, sr, sc, er, ec: Val): bool =
  let node = g.resolveTable(table)
  if node == nil: return false
  let rows = node.nm("rows")
  let columns = node.nm("columns")
  let srn = num(sr)
  let scn = num(sc)
  let startRow = jsMax(0, jsMin(rows - 1, if srn == srn and srn != 0: srn else: 0.0))
  let startColumn = jsMax(0, jsMin(columns - 1, if scn == scn and scn != 0: scn else: 0.0))
  let endRow = jsMax(0, jsMin(rows - 1, if nullish(er): startRow else: num(er)))
  let endColumn = jsMax(0, jsMin(columns - 1, if nullish(ec): startColumn else: num(ec)))
  var minRow = int(min(startRow, endRow))
  var maxRow = int(max(startRow, endRow))
  var minColumn = int(min(startColumn, endColumn))
  var maxColumn = int(max(startColumn, endColumn))
  if minRow == maxRow and minColumn == maxColumn:
    if float64(maxColumn + 1) < columns: inc maxColumn
    elif float64(maxRow + 1) < rows: inc maxRow
    else: return false
  var expanded = true
  while expanded:
    expanded = false
    for r in minRow .. maxRow:
      for c in minColumn .. maxColumn:
        let box = tableCellBox(node, float64(r), float64(c))
        let nMinRow = min(minRow, box.row)
        let nMaxRow = max(maxRow, box.row + box.rowspan - 1)
        let nMinColumn = min(minColumn, box.column)
        let nMaxColumn = max(maxColumn, box.column + box.colspan - 1)
        if nMinRow != minRow or nMaxRow != maxRow or nMinColumn != minColumn or nMaxColumn != maxColumn:
          expanded = true
        minRow = nMinRow
        maxRow = nMaxRow
        minColumn = nMinColumn
        maxColumn = nMaxColumn
  let before = g.snapshot()
  if not truthy(node["cells"]): node["cells"] = newObj()
  var entries = g.tableCellsInRange(node, minRow, maxRow, minColumn, maxColumn)
  entries.sort(proc (a, b: CellBox): int =
    if a.row != b.row: cmp(a.row, b.row) else: cmp(a.column, b.column))
  let origin = clone(g.getCell(node, minRow, minColumn))
  var texts: seq[string]
  for entry in entries:
    let value = g.getCell(node, entry.row, entry.column)
    let text = jsTrim(strOrEmpty(value["text"]))
    if text.len > 0 and not texts.contains(text): texts.add text
    node["cells"].remove($entry.row & "," & $entry.column)
  origin["text"] = jstr(texts.join("\n"))
  origin.del("richText")
  origin.del("html")
  origin["rowspan"] = jnum(maxRow - minRow + 1)
  origin["colspan"] = jnum(maxColumn - minColumn + 1)
  if maxRow == minRow: origin.del("rowspan")
  if maxColumn == minColumn: origin.del("colspan")
  node["cells"].put($minRow & "," & $minColumn, origin)
  g.rendererUpsert([node], true)
  g.commit(before, "Merge Table Cells")
  discard g.selectTableCell(node, minRow, minColumn, maxRow - minRow + 1, maxColumn - minColumn + 1)
  g.render()
  true

proc splitTableCell*(g: Graph, table: Val, row, column: float64): bool =
  let node = g.resolveTable(table)
  if node == nil: return false
  let box = tableCellBox(node, row, column)
  if box.rowspan == 1 and box.colspan == 1: return false
  let before = g.snapshot()
  let cell = clone(g.getCell(node, box.row, box.column))
  cell.del("rowspan")
  cell.del("colspan")
  if not truthy(node["cells"]): node["cells"] = newObj()
  node["cells"].put($box.row & "," & $box.column, cell)
  g.rendererUpsert([node], true)
  g.commit(before, "Split Table Cell")
  discard g.selectTableCell(node, box.row, box.column, 1, 1)
  g.render()
  true

proc swapTableRows(g: Graph, node: Val, first, second: int, before0: string): bool =
  let rows = int(max(1.0, node.nor("rows", 1)))
  let columns = int(max(1.0, node.nor("columns", 1)))
  if node == nil or not node.eqs("shape", "table") or first == second or first < 0 or
      second < 0 or first >= rows or second >= rows: return false
  let cellsV = node["cells"]
  if cellsV.isObj:
    for (_, cell) in cellsV.pairs:
      if cell.isObj and cell.nm("rowspan") > 1:
        g.toast("Unmerge vertically merged cells before moving rows")
        return false
  let before = if before0.len > 0: before0 else: g.snapshot()
  if not truthy(node["cells"]): node["cells"] = newObj()
  let cells = node["cells"]
  for column in 0 ..< columns:
    let firstKey = $first & "," & $column
    let secondKey = $second & "," & $column
    let firstValue = if cells.hasKey(firstKey): clone(cells.get(firstKey)) else: nil
    let secondValue = if cells.hasKey(secondKey): clone(cells.get(secondKey)) else: nil
    if secondValue == nil: cells.remove(firstKey) else: cells.put(firstKey, secondValue)
    if firstValue == nil: cells.remove(secondKey) else: cells.put(secondKey, firstValue)
  let rw = node["rowWeights"]
  if rw.isArr and rw.len == rows:
    let w = rw.a[first]
    rw.a[first] = rw.a[second]
    rw.a[second] = w
  g.rendererUpsert([node], true)
  g.commit(before, "Swap Table Rows")
  g.render()
  true

proc changeTableSize*(g: Graph, node: Val, rowDelta, columnDelta: float64) =
  if node == nil or not node.eqs("shape", "table"):
    g.toast("Select a table first")
    return
  if rowDelta > 0: discard g.insertTableRow(node, node["rows"])
  elif rowDelta < 0: discard g.deleteTableRow(node, jnum(node.nm("rows") - 1))
  if columnDelta > 0: discard g.insertTableColumn(node, node["columns"])
  elif columnDelta < 0: discard g.deleteTableColumn(node, jnum(node.nm("columns") - 1))

# ------------------------------------------------------------- media --

proc insertMedia*(g: Graph, src: string, name: string, point: Val, mediaType: string): Val =
  if src.len == 0: return nil
  let video = mediaType.startsWith("video/")
  var target = point
  if not truthy(target):
    let view = g.getViewState()
    target = obj(("x", jnum((view.nm("scrollX") + view.nm("width") / 2) / g.zoom - (if video: 210.0 else: 90.0))),
                 ("y", jnum((view.nm("scrollY") + view.nm("height") / 2) / g.zoom - (if video: 118.0 else: 60.0))))
  let before = g.snapshot()
  let node = g.addNode(obj(("shape", jstr("image")), ("src", jstr(src)), ("mediaType", jstr(mediaType)),
    ("mediaLoop", jtrue), ("mediaVolume", jnum(1)), ("width", jnum(if video: 420.0 else: 180.0)),
    ("height", jnum(if video: 236.0 else: 120.0)), ("x", target["x"]), ("y", target["y"]),
    ("text", jstr("")), ("fill", jstr("transparent")), ("stroke", jstr("transparent")),
    ("strokeWidth", jnum(0)), ("radius", jnum(0)), ("imageFit", jstr("contain")),
    ("imageAlign", jstr("center")), ("imageVerticalAlign", jstr("middle")), ("tooltip", jstr(name))), true)
  g.commit(before, "Insert Media")
  node

# ---------------------------------------------------------- utilities --

proc autosizeSelection*(g: Graph) =
  var selected: seq[Val]
  for it in g.getSelection():
    if not it.eqs("type", "edge") and not it.tr("locked") and not it.eqs("kind", "taskList"):
      selected.add it
  if selected.len == 0:
    g.toast("Select a shape to fit to its label")
    return
  let before = g.snapshot()
  for node in selected:
    let fontSize = node.fo("fontSize", 14)
    let font = (if node.tr("italic"): "italic " else: "") &
      (if node.tr("bold"): "700" else: node.so("fontWeight", "500")) & " " &
      node.so("fontSize", "14") & "px " & node.so("fontFamily", "Arial, sans-serif")
    let lines = node.so("text", "").split('\n')
    var width = 0.0
    for line in lines: width = jsMax(width, measureText(font, line))
    node["width"] = jnum(jsMax(40, ceil(width + 26)))
    node["height"] = jnum(jsMax(30, ceil(float64(lines.len) * fontSize * 1.25 + 20)))
    g.reindexNodeAndEdges(node)
  g.rendererUpsert(selected)
  g.commit(before, "Autosize")
  g.updateWorldSize()
  g.render()
  g.emitSelection()
  g.toast("Fitted " & $selected.len & " object" & (if selected.len == 1: "" else: "s"))

proc copySize*(g: Graph) =
  var item: Val
  for it in g.getSelection():
    if not it.eqs("type", "edge"):
      item = it
      break
  if item == nil:
    g.toast("Select a shape to copy its size")
    return
  g.sizeClipboard = obj(("width", item["width"]), ("height", item["height"]))
  g.toast("Size copied")

proc pasteSize*(g: Graph) =
  if g.sizeClipboard == nil:
    g.toast("Copy a size first")
    return
  var allowed = initHashSet[string]()
  for it in g.getSelection():
    if not it.eqs("type", "edge"): allowed.incl idOf(it)
  g.applyStyle(obj(("width", g.sizeClipboard["width"]), ("height", g.sizeClipboard["height"])),
               "Paste Size", allowed, true)

proc clearLabels*(g: Graph) =
  if g.getSelection().len == 0:
    g.toast("Nothing selected")
    return
  g.applyStyleAll(obj(("text", jstr(""))), "Clear Labels")

proc deleteAll*(g: Graph) =
  g.selectByType("", true)
  g.removeSelection()

proc resetView*(g: Graph) =
  g.zoom = 1
  g.updateWorldSize()
  setScroll(if g.pageView: 0.0 else: g.worldOriginX * g.zoom,
            if g.pageView: 0.0 else: g.worldOriginY * g.zoom)
  g.render()
  g.emit("zoomchange", jnum(g.zoom))

proc fitPage*(g: Graph, widthOnly: bool) =
  if not g.pageView: g.pageView = true
  let margin = (if g.pageMargin != 0: g.pageMargin else: 24.0) * 2
  let pageWidth = max(1.0, g.pageWidth * g.pageScale)
  let pageHeight = max(1.0, g.pageHeight * g.pageScale)
  let m = viewMetrics()
  let scaleX = (m.clientWidth - margin) / pageWidth
  let scaleY = (m.clientHeight - margin) / pageHeight
  let fitted = floor(20 * (if widthOnly: scaleX else: jsMin(scaleX, scaleY))) / 20
  g.zoom = clamp(fitted, 0.2, 4)
  g.updateWorldSize()
  setScroll(0, 0)
  g.render()
  g.emit("zoomchange", jnum(g.zoom))
  g.emit("diagramchange", obj(("pageView", jtrue)))

proc toggleLock*(g: Graph) =
  let selected = g.getSelection()
  if selected.len == 0: return
  var all = true
  for it in selected:
    if not it["locked"].isTrue:
      all = false
      break
  let lock = not all
  g.applyStyleAll(obj(("locked", jbool(lock))), if lock: "Lock" else: "Unlock")

proc movableNodes(g: Graph): seq[Val] =
  for it in g.getSelection():
    if not it.eqs("type", "edge") and not it.tr("locked"): result.add it

proc alignSelection*(g: Graph, mode: string) =
  let selected = g.movableNodes()
  if selected.len < 2: return
  let before = g.snapshot()
  var values: seq[float64]
  for it in selected:
    values.add(case mode
      of "left": nodeX(it)
      of "right": nodeX(it) + nodeW(it)
      of "top": nodeY(it)
      of "bottom": nodeY(it) + nodeH(it)
      of "center": nodeX(it) + nodeW(it) / 2
      else: nodeY(it) + nodeH(it) / 2)
  var target = 0.0
  for v in values: target += v
  target = target / float64(values.len)
  if mode == "left" or mode == "top":
    target = Inf
    for v in values: target = jsMin(target, v)
  if mode == "right" or mode == "bottom":
    target = -Inf
    for v in values: target = jsMax(target, v)
  for it in selected:
    case mode
    of "left": it["x"] = jnum(target)
    of "right": it["x"] = jnum(target - nodeW(it))
    of "top": it["y"] = jnum(target)
    of "bottom": it["y"] = jnum(target - nodeH(it))
    of "center": it["x"] = jnum(target - nodeW(it) / 2)
    else: it["y"] = jnum(target - nodeH(it) / 2)
    g.reindexNodeAndEdges(it)
  g.rendererUpsert(selected)
  g.commit(before, "Align")
  g.render()

proc distributeSelection*(g: Graph, axis: string) =
  var selected = g.movableNodes()
  if selected.len < 3: return
  let horizontal = axis == "horizontal"
  proc centerOf(it: Val): float64 =
    if horizontal: nodeX(it) + nodeW(it) / 2 else: nodeY(it) + nodeH(it) / 2
  selected.sort(proc (a, b: Val): int =
    let d = centerOf(a) - centerOf(b)
    if d < 0: -1 elif d > 0: 1 else: 0)
  let before = g.snapshot()
  let first = centerOf(selected[0])
  let last = centerOf(selected[^1])
  for i in 1 ..< selected.len - 1:
    let center = first + (last - first) * float64(i) / float64(selected.len - 1)
    if horizontal: selected[i]["x"] = jnum(center - nodeW(selected[i]) / 2)
    else: selected[i]["y"] = jnum(center - nodeH(selected[i]) / 2)
    g.reindexNodeAndEdges(selected[i])
  g.rendererUpsert(selected)
  g.commit(before, "Distribute")
  g.render()

proc rotateSelection*(g: Graph, degrees: float64) =
  let selected = g.movableNodes()
  if selected.len == 0: return
  let before = g.snapshot()
  for it in selected:
    it["rotation"] = jnum(jsMod(it.fo("rotation", 0) + degrees + 360, 360))
    g.reindexNodeAndEdges(it)
  g.rendererUpsert(selected)
  g.commit(before, "Rotate")
  g.render()

proc nudgeSelection*(g: Graph, dx, dy: float64) =
  let selected = g.movableNodes()
  if selected.len == 0: return
  let before = g.snapshot()
  for it in selected:
    it["x"] = jnum(nodeX(it) + dx)
    it["y"] = jnum(nodeY(it) + dy)
    g.reindexNodeAndEdges(it)
  g.rendererUpsert(selected)
  g.commit(before, "Nudge")
  g.render()

proc flipSelection*(g: Graph, axis: string) =
  let key = if axis == "vertical": "flipV" else: "flipH"
  let selected = g.movableNodes()
  if selected.len == 0: return
  let before = g.snapshot()
  for it in selected: it.put(key, jbool(not truthy(it.get(key))))
  g.rendererUpsert(selected)
  g.commit(before, "Flip")
  g.render()

proc selectedEdges(g: Graph): seq[Val] =
  for it in g.getSelection():
    if it.eqs("type", "edge") and not it.tr("locked"): result.add it

proc resetWaypoints*(g: Graph) =
  let edges = g.selectedEdges()
  if edges.len == 0: return
  let before = g.snapshot()
  for e in edges:
    e["route"] = jnull
    g.reindex(e)
  g.rendererUpsert(edges)
  g.commit(before, "Reset Waypoints")
  g.render()

proc addWaypointToSelection*(g: Graph, point: Val) =
  let edges = g.selectedEdges()
  if edges.len == 0 or not truthy(point): return
  let edge = edges[0]
  let p = toPt(point)
  var points = edgePoints(edge, g.byId)
  var best = 0
  var bestDistance = Inf
  for i in 0 ..< points.len - 1:
    let d = distanceToSegment(p, points[i], points[i + 1])
    if d < bestDistance:
      bestDistance = d
      best = i
  let before = g.snapshot()
  let waypoint = pt(if g.gridEnabled: snap(p.x, g.gridSize) else: p.x,
                    if g.gridEnabled: snap(p.y, g.gridSize) else: p.y)
  points.insert(waypoint, min(best + 1, points.len))
  edge["route"] = ptsVal(points[1 ..< max(1, points.len - 1)])
  g.reindex(edge)
  g.rendererUpsert([edge])
  g.commit(before, "Add Waypoint")
  g.render()

proc reverseEdges*(g: Graph) =
  let edges = g.selectedEdges()
  if edges.len == 0: return
  let before = g.snapshot()
  for e in edges:
    let sourceId = e["sourceId"]
    let sourceSide = e["sourceSide"]
    let sourceAnchor = e["sourceAnchor"]
    let startArrow = e["startArrow"]
    e["sourceId"] = e["targetId"]
    e["sourceSide"] = e["targetSide"]
    e["sourceAnchor"] = e["targetAnchor"]
    e["targetId"] = sourceId
    e["targetSide"] = sourceSide
    e["targetAnchor"] = sourceAnchor
    e["startArrow"] = e["endArrow"]
    e["endArrow"] = startArrow
    let sourcePoint = e["sourcePoint"]
    e["sourcePoint"] = e["targetPoint"]
    e["targetPoint"] = sourcePoint
    if truthy(e["route"]) and e["route"].isArr: e["route"].a.reverse()
    g.reindex(e)
  g.rendererUpsert(edges)
  g.commit(before, "Reverse Connector")
  g.render()

proc flipCircularArc*(g: Graph) =
  var edges: seq[Val]
  for it in g.getSelection():
    if it.eqs("type", "edge") and it.eqs("lineStyle", "circular") and not it.tr("locked"): edges.add it
  if edges.len == 0: return
  let before = g.snapshot()
  for e in edges:
    e["arcSide"] = jnum(if e.nm("arcSide") < 0: 1.0 else: -1.0)
    g.reindex(e)
  g.rendererUpsert(edges)
  g.commit(before, "Flip Circular Connector")
  g.render()

proc copyStyle*(g: Graph) =
  let selection = g.getSelection()
  if selection.len == 0: return
  let item = selection[0]
  let sel = g.getSelectedTableCell()
  let styleSource = if sel.found: sel.cell else: item
  let keys = if item.eqs("type", "edge"):
      @["stroke", "strokeWidth", "dashed", "opacity", "lineStyle", "arcSweep", "arcSide",
        "circleRadius", "startArrow", "endArrow", "arrowSize"]
    else:
      @["shape", "fill", "stroke", "strokeWidth", "dashed", "opacity", "radius", "shadow",
        "textColor", "textOpacity", "fontFamily", "fontSize", "fontWeight", "italic",
        "underline", "strikethrough", "textAlign", "verticalAlign"]
  g.styleClipboard = newObj()
  for k in keys:
    let key = if k == "textAlign" and sel.found: "align" else: k
    let v = styleSource.get(key)
    if v != nil: g.styleClipboard.put(k, clone(v))
  g.toast("Style copied")

proc pasteStyle*(g: Graph) =
  if truthy(g.styleClipboard): g.applyStyleAll(clone(g.styleClipboard), "Paste Style")

proc setDefaultStyle*(g: Graph) =
  let selection = g.getSelection()
  if selection.len == 0: return
  let item = selection[0]
  g.copyStyle()
  if item.eqs("type", "edge"):
    g.defaultEdgeStyle = clone(g.styleClipboard)
    g.toast("Default connector style saved")
  else:
    g.defaultNodeStyle = clone(g.styleClipboard)
    g.toast("Default vertex style saved")

proc clearDefaultStyle*(g: Graph) =
  g.defaultNodeStyle = nil
  g.defaultEdgeStyle = defaultEdgeStyleVal()
  g.toast("Default style cleared")

# ------------------------------------------------------ properties --

proc getProp*(g: Graph, name: string): Val =
  case name
  of "zoom": jnum(g.zoom)
  of "gridSize": jnum(g.gridSize)
  of "gridEnabled": jbool(g.gridEnabled)
  of "gridColor": jstr(g.gridColor)
  of "backgroundColor": jstr(g.backgroundColor)
  of "pageView": jbool(g.pageView)
  of "pageWidth": jnum(g.pageWidth)
  of "pageHeight": jnum(g.pageHeight)
  of "pageMargin": jnum(g.pageMargin)
  of "pageColumns": jnum(g.pageColumns)
  of "pageRows": jnum(g.pageRows)
  of "pageStartColumn": jnum(g.pageStartColumn)
  of "pageStartRow": jnum(g.pageStartRow)
  of "infiniteWorldWidth": jnum(g.infiniteWorldWidth)
  of "infiniteWorldHeight": jnum(g.infiniteWorldHeight)
  of "worldOriginX": jnum(g.worldOriginX)
  of "worldOriginY": jnum(g.worldOriginY)
  of "connectionArrows": jbool(g.connectionArrows)
  of "connectionPoints": jbool(g.connectionPoints)
  of "allowLoops": jbool(g.allowLoops)
  of "defaultEdgeLength": jnum(g.defaultEdgeLength)
  of "guidesEnabled": jbool(g.guidesEnabled)
  of "portMode": jstr(g.portMode)
  of "pageScale": jnum(g.pageScale)
  of "tooltipsEnabled": jbool(g.tooltipsEnabled)
  of "layers": g.layers
  of "activeLayer": jstr(g.activeLayer)
  of "mobileMode": jbool(g.mobileMode)
  of "readOnly": jbool(g.readOnly)
  of "selection": idsVal(g.selection)
  of "enteredGroups": idsVal(g.enteredGroups)
  of "hoverId": (if g.hoverId.len > 0: jstr(g.hoverId) else: jnull)
  of "defaultNodeStyle": (if g.defaultNodeStyle == nil: jnull else: g.defaultNodeStyle)
  of "defaultEdgeStyle": (if g.defaultEdgeStyle == nil: jnull else: g.defaultEdgeStyle)
  of "styleClipboard": (if g.styleClipboard == nil: jnull else: g.styleClipboard)
  of "spacePressed": jbool(g.spacePressed)
  of "action": (if g.action == nil: jnull else: obj(("type", jstr(g.action.kind))))
  of "canUndo": jbool(g.canUndo())
  of "canRedo": jbool(g.canRedo())
  of "itemCount": jnum(g.items.len)
  else: g.extra.get(name)

proc setProp*(g: Graph, name: string, v: Val) =
  case name
  of "zoom": g.zoom = num(v)
  of "gridSize": g.gridSize = num(v)
  of "gridEnabled": g.gridEnabled = truthy(v)
  of "gridColor": g.gridColor = strOrEmpty(v)
  of "backgroundColor": g.backgroundColor = strOrEmpty(v)
  of "pageView": g.pageView = truthy(v)
  of "pageWidth": g.pageWidth = num(v)
  of "pageHeight": g.pageHeight = num(v)
  of "pageMargin": g.pageMargin = num(v)
  of "pageColumns": g.pageColumns = num(v)
  of "pageRows": g.pageRows = num(v)
  of "pageStartColumn": g.pageStartColumn = num(v)
  of "pageStartRow": g.pageStartRow = num(v)
  of "infiniteWorldWidth": g.infiniteWorldWidth = num(v)
  of "infiniteWorldHeight": g.infiniteWorldHeight = num(v)
  of "worldOriginX": g.worldOriginX = num(v)
  of "worldOriginY": g.worldOriginY = num(v)
  of "connectionArrows": g.connectionArrows = truthy(v)
  of "connectionPoints": g.connectionPoints = truthy(v)
  of "allowLoops": g.allowLoops = truthy(v)
  of "defaultEdgeLength": g.defaultEdgeLength = num(v)
  of "guidesEnabled": g.guidesEnabled = truthy(v)
  of "portMode": g.portMode = strOrEmpty(v)
  of "pageScale": g.pageScale = num(v)
  of "tooltipsEnabled": g.tooltipsEnabled = truthy(v)
  of "layers": g.layers = (if v.isArr: v else: defaultLayers())
  of "activeLayer": g.activeLayer = strOrEmpty(v)
  of "mobileMode": g.mobileMode = truthy(v)
  of "readOnly": g.readOnly = truthy(v)
  of "defaultNodeStyle": g.defaultNodeStyle = (if nullish(v): nil else: v)
  of "defaultEdgeStyle": g.defaultEdgeStyle = (if nullish(v): nil else: v)
  of "styleClipboard": g.styleClipboard = (if nullish(v): nil else: v)
  of "spacePressed": g.spacePressed = truthy(v)
  else: g.extra.put(name, v)

proc setDiagramOptions*(g: Graph, changes: Val) =
  if not changes.nul("pageWidth"): changes["pageWidth"] = jnum(clamp(changes.nor("pageWidth", 827), 50, 10000))
  if not changes.nul("pageHeight"): changes["pageHeight"] = jnum(clamp(changes.nor("pageHeight", 1169), 50, 10000))
  if not changes.nul("pageScale"): changes["pageScale"] = jnum(clamp(changes.nor("pageScale", 1), 0.1, 4))
  if not changes.nul("pageView"): changes["pageView"] = jbool(changes["pageView"].isTrue)
  let pageModeChanged = changes.has("pageView") and
    not strictEq(changes["pageView"], jbool(g.pageView))
  for (key, value) in changes.pairs: g.setProp(key, value)
  if pageModeChanged:
    g.infiniteWorldWidth = 0
    g.infiniteWorldHeight = 0
    g.worldOriginX = 0
    g.worldOriginY = 0
    setScroll(0, 0)
  g.updateWorldSize()
  if pageModeChanged: setScroll(0, 0)
  g.render()
  g.emit("diagramchange", changes)

# -------------------------------------------------------------- view --

proc hiddenLayerIds*(g: Graph): seq[string] =
  for layer in g.layers:
    if layer["visible"].isFalse: result.add strOrEmpty(layer["id"])

proc getViewState*(g: Graph): Val =
  let m = viewMetrics()
  obj(("width", jnum(max(1.0, m.clientWidth))), ("height", jnum(max(1.0, m.clientHeight))),
      ("scrollX", jnum(m.scrollLeft - g.worldOriginX * g.zoom)),
      ("scrollY", jnum(m.scrollTop - g.worldOriginY * g.zoom)),
      ("zoom", jnum(g.zoom)), ("dpr", jnum(max(1.0, min(2.0, m.dpr)))),
      ("grid", jbool(g.gridEnabled)), ("gridSize", jnum(g.gridSize)),
      ("gridColor", jstr(g.gridColor)), ("background", jstr(g.backgroundColor)),
      ("pageView", jbool(g.pageView)), ("pageWidth", jnum(g.pageWidth * g.pageScale)),
      ("pageHeight", jnum(g.pageHeight * g.pageScale)), ("pageMargin", jnum(g.pageMargin)),
      ("pageColumns", jnum(g.pageColumns)), ("pageRows", jnum(g.pageRows)),
      ("pageStartColumn", jnum(g.pageStartColumn)), ("pageStartRow", jnum(g.pageStartRow)),
      ("hiddenLayers", idsVal(g.hiddenLayerIds())))

proc isGesture(g: Graph): bool =
  g.action != nil and g.action.kind in ["move", "edgeMove", "resize", "rotate", "segment",
                                        "circularArc", "pan", "pinch"]

proc render*(g: Graph, forceRealtime = false) =
  if g.destroyed: return
  let view = g.getViewState()
  if g.hooks.render != nil: g.hooks.render(view, forceRealtime or g.isGesture())
  g.drawOverlay()

proc getLayoutBounds(g: Graph): (bool, Rect) =
  let hidden = g.hiddenLayerIds()
  var found = false
  var r: Rect
  for item in g.items:
    if item == nil or item["visible"].isFalse or item.tr("foldedAway"): continue
    if not nullish(item["layer"]) and hidden.contains(str(item["layer"])): continue
    let b = itemBounds(item, g.byId)
    if not found:
      r = b
      found = true
    else:
      let right = jsMax(r.x + r.width, b.x + b.width)
      let bottom = jsMax(r.y + r.height, b.y + b.height)
      r.x = jsMin(r.x, b.x)
      r.y = jsMin(r.y, b.y)
      r.width = right - r.x
      r.height = bottom - r.y
  (found, r)

proc setSpacer(g: Graph, width, height: float64) =
  if g.hooks.spacer != nil: g.hooks.spacer(width, height)

proc updateWorldSize*(g: Graph) =
  let (hasBounds, layoutBounds) = g.getLayoutBounds()
  let minX = if hasBounds: layoutBounds.x else: 0.0
  let minY = if hasBounds: layoutBounds.y else: 0.0
  let maxX = if hasBounds: layoutBounds.x + layoutBounds.width else: 0.0
  let maxY = if hasBounds: layoutBounds.y + layoutBounds.height else: 0.0
  let zoom = max(0.2, if g.zoom != 0 and g.zoom == g.zoom: g.zoom else: 1.0)
  var m = viewMetrics()
  let viewportWidth = max(1.0, if m.clientWidth != 0: m.clientWidth else: 1.0) / zoom
  let viewportHeight = max(1.0, if m.clientHeight != 0: m.clientHeight else: 1.0) / zoom
  let holdDragExtent = g.action != nil and g.action.kind in ["move", "edgeMove", "resize",
    "tableResize", "customHandle", "groupResize", "groupRotate", "rotate", "segment",
    "circularArc", "pinch"]

  if g.pageView:
    let margin = if g.pageMargin != 0: g.pageMargin else: 24.0
    let pageWidth = max(1.0, g.pageWidth * g.pageScale)
    let pageHeight = max(1.0, g.pageHeight * g.pageScale)
    var firstColumn = if hasBounds: jsMin(0, floor(minX / pageWidth)) else: 0.0
    var firstRow = if hasBounds: jsMin(0, floor(minY / pageHeight)) else: 0.0
    var lastColumn = if hasBounds: jsMax(1, ceil(maxX / pageWidth)) else: 1.0
    var lastRow = if hasBounds: jsMax(1, ceil(maxY / pageHeight)) else: 1.0
    let oldPageOriginX = g.worldOriginX
    let oldPageOriginY = g.worldOriginY
    if holdDragExtent:
      let pfc = g.pageStartColumn
      let pfr = g.pageStartRow
      let plc = pfc + max(1.0, if g.pageColumns != 0: g.pageColumns else: 1.0)
      let plr = pfr + max(1.0, if g.pageRows != 0: g.pageRows else: 1.0)
      firstColumn = jsMin(firstColumn, pfc)
      firstRow = jsMin(firstRow, pfr)
      lastColumn = jsMax(lastColumn, plc)
      lastRow = jsMax(lastRow, plr)
    g.pageStartColumn = firstColumn
    g.pageStartRow = firstRow
    g.pageColumns = max(1.0, lastColumn - firstColumn)
    g.pageRows = max(1.0, lastRow - firstRow)
    g.worldOriginX = margin - firstColumn * pageWidth
    g.worldOriginY = margin - firstRow * pageHeight
    m = viewMetrics()
    setScroll(m.scrollLeft + (g.worldOriginX - oldPageOriginX) * zoom, NaN)
    m = viewMetrics()
    setScroll(NaN, m.scrollTop + (g.worldOriginY - oldPageOriginY) * zoom)
    g.setSpacer(ceil(jsMax(viewportWidth, margin * 2 + g.pageColumns * pageWidth) * zoom),
              ceil(jsMax(viewportHeight, margin * 2 + g.pageRows * pageHeight) * zoom))
    return

  let oldOriginX = g.worldOriginX
  let oldOriginY = g.worldOriginY
  let gutter = if hasBounds: jsMax(40, if g.pageMargin != 0: g.pageMargin else: 24.0) else: 0.0
  var surfaceMinX = jsMin(0, minX - gutter)
  var surfaceMinY = jsMin(0, minY - gutter)
  var surfaceMaxX = jsMax(viewportWidth, maxX + gutter)
  var surfaceMaxY = jsMax(viewportHeight, maxY + gutter)
  if holdDragExtent and g.infiniteWorldWidth > 0 and g.infiniteWorldHeight > 0:
    let psx = -oldOriginX
    let psy = -oldOriginY
    surfaceMinX = jsMin(surfaceMinX, psx)
    surfaceMinY = jsMin(surfaceMinY, psy)
    surfaceMaxX = jsMax(surfaceMaxX, psx + g.infiniteWorldWidth)
    surfaceMaxY = jsMax(surfaceMaxY, psy + g.infiniteWorldHeight)
  g.worldOriginX = -surfaceMinX
  g.worldOriginY = -surfaceMinY
  m = viewMetrics()
  setScroll(m.scrollLeft + (g.worldOriginX - oldOriginX) * zoom, NaN)
  m = viewMetrics()
  setScroll(NaN, m.scrollTop + (g.worldOriginY - oldOriginY) * zoom)
  g.infiniteWorldWidth = jsMax(viewportWidth, surfaceMaxX - surfaceMinX)
  g.infiniteWorldHeight = jsMax(viewportHeight, surfaceMaxY - surfaceMinY)
  g.pageColumns = 1
  g.pageRows = 1
  g.pageStartColumn = 0
  g.pageStartRow = 0
  g.setSpacer(ceil(g.infiniteWorldWidth * zoom), ceil(g.infiniteWorldHeight * zoom))

proc setZoom*(g: Graph, value0: float64, hasPoint = false, sx = 0.0, sy = 0.0) =
  let old = g.zoom
  let value = clamp(value0, 0.2, 4)
  if abs(old - value) < 0.001: return
  var m = viewMetrics()
  let screenX = if hasPoint: sx else: m.clientWidth / 2
  let screenY = if hasPoint: sy else: m.clientHeight / 2
  let worldX = (m.scrollLeft + screenX) / old - g.worldOriginX
  let worldY = (m.scrollTop + screenY) / old - g.worldOriginY
  g.zoom = value
  g.updateWorldSize()
  setScroll((worldX + g.worldOriginX) * value - screenX, NaN)
  setScroll(NaN, (worldY + g.worldOriginY) * value - screenY)
  g.render()
  g.emit("zoomchange", jnum(value))

proc zoomIn*(g: Graph) = g.setZoom(g.zoom * 1.2)
proc zoomOut*(g: Graph) = g.setZoom(g.zoom / 1.2)
proc zoomActual*(g: Graph) = g.setZoom(1)

proc getAllBounds*(g: Graph): Rect =
  if g.items.len == 0: return rect(0, 0, 1, 1)
  let first = itemBounds(g.items[0], g.byId)
  var minX = first.x
  var minY = first.y
  var maxX = first.x + first.width
  var maxY = first.y + first.height
  for i in 1 ..< g.items.len:
    let b = itemBounds(g.items[i], g.byId)
    minX = jsMin(minX, b.x)
    minY = jsMin(minY, b.y)
    maxX = jsMax(maxX, b.x + b.width)
    maxY = jsMax(maxY, b.y + b.height)
  rect(minX, minY, maxX - minX, maxY - minY)

proc fit*(g: Graph) =
  if g.items.len == 0:
    g.setZoom(1)
    return
  let b = g.getAllBounds()
  let m = viewMetrics()
  let zoom = jsMin(jsMin((m.clientWidth - 80) / max(1.0, b.width),
                         (m.clientHeight - 80) / max(1.0, b.height)), 2)
  g.zoom = clamp(zoom, 0.2, 4)
  g.updateWorldSize()
  setScroll(max(0.0, (b.x + g.worldOriginX) * g.zoom - 40), NaN)
  setScroll(NaN, max(0.0, (b.y + g.worldOriginY) * g.zoom - 40))
  g.render()
  g.emit("zoomchange", jnum(g.zoom))

proc eventWorld*(g: Graph, screen: Pt): Pt =
  let m = viewMetrics()
  pt((screen.x + m.scrollLeft) / g.zoom - g.worldOriginX,
     (screen.y + m.scrollTop) / g.zoom - g.worldOriginY)

proc worldToScreen*(g: Graph, p: Pt): Pt =
  let m = viewMetrics()
  pt((p.x + g.worldOriginX) * g.zoom - m.scrollLeft, (p.y + g.worldOriginY) * g.zoom - m.scrollTop)
