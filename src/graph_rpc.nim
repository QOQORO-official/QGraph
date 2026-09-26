# Included from graph.nim: the method table behind qg_call. The page's Graph
# facade calls these by name with JSON arguments; objects that were items on
# the JavaScript side travel as their ids.

proc idArg(v: Val): string =
  ## An item argument: its id, or the id of an item object.
  if v == nil: ""
  elif v.kind == vStr: v.s
  elif v.kind == vObj: idOf(v)
  elif v.kind == vNull: ""
  else: str(v)

proc idsArg(v: Val): seq[string] =
  for x in v: result.add idArg(x)

proc itemArg(g: Graph, v: Val): Val =
  let id = idArg(v)
  if id.len == 0: nil else: g.byId.getOrDefault(id, nil)

proc allowedArg(v: Val): (HashSet[string], bool) =
  ## null = no predicate, otherwise the ids that passed it.
  if nullish(v): return (initHashSet[string](), false)
  var s = initHashSet[string]()
  for x in v: s.incl idArg(x)
  (s, true)

proc selectedCellVal(sel: SelectedCell): Val =
  if not sel.found: return jnull
  obj(("node", sel.node), ("row", jnum(sel.row)), ("column", jnum(sel.column)),
      ("cell", if sel.cell == nil: jnull else: sel.cell), ("startRow", jnum(sel.startRow)),
      ("endRow", jnum(sel.endRow)), ("startColumn", jnum(sel.startColumn)),
      ("endColumn", jnum(sel.endColumn)), ("x", jnum(sel.x)), ("y", jnum(sel.y)),
      ("width", jnum(sel.width)), ("height", jnum(sel.height)))

proc groupVal(grp: GroupInfo): Val =
  obj(("id", jstr(grp.id)), ("items", itemsVal(grp.items)), ("bounds", rectVal(grp.bounds)))

proc boolArg(v: Val, d: bool): bool = (if v == nil: d else: truthy(v))

proc updateItem*(g: Graph, id: string, changes: Val, label: string, record: bool): Val =
  ## Writes properties onto one item the way the chrome used to mutate the
  ## live object, then refreshes index and renderer (and optionally records
  ## an undo step).
  let item = g.byId.getOrDefault(id, nil)
  if item == nil: return nil
  let before = if record: g.snapshot() else: ""
  applyChanges(item, changes)
  discard g.normalizeCircularEdge(item)
  g.reindexNodeAndEdges(item)
  g.rendererUpsert([item])
  if record: g.commit(before, if label.len > 0: label else: "Edit")
  g.render()
  item

proc replaceItem*(g: Graph, id: string, data: Val, label: string): Val =
  ## Edit Data: swaps every property of one item for `data` (id and type
  ## stay), as one undo step.
  let item = g.byId.getOrDefault(id, nil)
  if item == nil or not data.isObj: return nil
  let before = g.snapshot()
  let keepId = item["id"]
  let keepType = item["type"]
  for key in item.keys: item.remove(key)
  for (key, value) in data.pairs: item.put(key, value)
  item["id"] = keepId
  item["type"] = keepType
  g.rebuildIndex()
  g.rendererSync()
  g.commit(before, if label.len > 0: label else: "Edit Data")
  g.render()
  g.emitSelection()
  item

proc dispatch*(g: Graph, m: string, a: Val): Val =
  template A(i: int): Val = a[i]
  template S(i: int): string = (let tv = a[i]; if nullish(tv): "" else: str(tv))
  template N(i: int): float64 = num(a[i])
  template B(i: int, d: bool): bool = boolArg(a[i], d)
  case m
  # ---- history / document
  of "snapshot": result = jstr(g.snapshot())
  of "commit":
    g.commit(S(0), S(1), not nullish(A(0)))
  of "undo": g.undo()
  of "redo": g.redo()
  of "canUndo": result = jbool(g.canUndo())
  of "canRedo": result = jbool(g.canRedo())
  of "loadItems":
    g.loadItems(A(0), not A(1).isFalse, A(2))
  of "toJSON": result = jstr(g.toJSON())
  of "fromJSON":
    let data = if A(0).isStr: parseJson(A(0).s) else: A(0)
    g.fromJSON(data)
  # ---- items
  of "addNode": result = g.addNode(A(0), B(1, true))
  of "addTemplate": result = g.addTemplate(A(0), A(1), B(2, true))
  of "addEdge": result = g.addEdge(A(0), B(1, true))
  of "updateItem": result = g.updateItem(S(0), A(1), S(2), B(3, false))
  of "replaceItem": result = g.replaceItem(S(0), A(1), S(2))
  of "getItem": result = g.byId.getOrDefault(S(0), jnull)
  of "rebuildIndex": g.rebuildIndex()
  of "reindexNodeAndEdges":
    let it = g.itemArg(A(0))
    if it != nil: g.reindexNodeAndEdges(it)
  of "rendererSync": g.rendererSync()
  of "rendererUpsert":
    var list: seq[Val]
    for id in idsArg(A(0)):
      let it = g.byId.getOrDefault(id, nil)
      if it != nil: list.add it
    g.rendererUpsert(list, B(1, false))
  # ---- selection
  of "setSelection":
    g.setSelection(idsArg(A(0)), B(1, false))
  of "getSelection": result = itemsVal(g.getSelection())
  of "isSelected": result = jbool(g.isSelected(S(0)))
  of "getSelectedTableCell": result = selectedCellVal(g.getSelectedTableCell())
  of "selectTableCell":
    let node = g.itemArg(A(0))
    let cell = A(1)
    if node == nil or not truthy(cell): return jfalse
    result = jbool(g.selectTableCell(node, int(num(cell["row"])), int(num(cell["column"])),
                            int(max(1.0, cell.nor("rowspan", 1))), int(max(1.0, cell.nor("colspan", 1))),
                            B(2, false)))
  of "clearTableCellSelection": result = jbool(g.clearTableCellSelection(B(0, true)))
  of "getStyleTargetIds":
    let (allowed, filtered) = allowedArg(A(0))
    result = idsVal(g.getStyleTargetIds(allowed, filtered))
  of "toggleSelection": g.toggleSelection(S(0))
  of "selectByType": g.selectByType(S(0), nullish(A(0)))
  of "effectiveGroup":
    let grp = g.effectiveGroup(g.itemArg(A(0)))
    result = if grp.len > 0: jstr(grp) else: jnull
  of "getGroupMembers": result = itemsVal(g.getGroupMembers(S(0)))
  of "getSelectedGroups":
    let arr = newArr()
    for grp in g.getSelectedGroups(): arr.push groupVal(grp)
    result = arr
  # ---- editing
  of "removeSelection": g.removeSelection()
  of "copy": g.copy()
  of "cut": g.cut()
  of "paste": g.paste(A(0))
  of "duplicate": g.duplicate()
  of "changeZ": g.changeZ(B(0, false))
  of "applyStyle":
    let (allowed, filtered) = allowedArg(A(2))
    g.applyStyle(A(0), S(1), allowed, filtered)
  of "replaceShape":
    var targets: seq[Val]
    for id in idsArg(A(0)):
      let it = g.byId.getOrDefault(id, nil)
      if it != nil: targets.add it
    result = itemsVal(g.replaceShape(targets, A(1), S(2)))
  of "previewStyle": result = itemsVal(g.previewStyle(idsArg(A(0)), A(1)))
  of "commitPreview": g.commitPreview(S(0), S(1))
  of "getCommonStyle": result = g.getCommonStyle(S(0), A(1))
  # ---- groups
  of "groupSelection": g.groupSelection()
  of "ungroupSelection": g.ungroupSelection()
  of "enterGroup": g.enterGroup()
  of "exitGroup": g.exitGroup()
  of "removeFromGroup": g.removeFromGroup()
  of "toggleFold": g.toggleFold()
  of "toggleContainerFold": g.toggleContainerFold(g.itemArg(A(0)))
  # ---- layers
  of "getLayer": result = (let l = g.getLayer(S(0)); if l == nil: jnull else: l)
  of "addLayer": result = g.addLayer(S(0))
  of "removeLayer": g.removeLayer(S(0))
  of "updateLayer": g.updateLayer(S(0), A(1))
  of "moveLayer": g.moveLayer(S(0), int(N(1)))
  of "moveSelectionToLayer": g.moveSelectionToLayer(S(0))
  of "isLayerLocked": result = jbool(g.isLayerLocked(g.itemArg(A(0))))
  of "hiddenLayerIds": result = idsVal(g.hiddenLayerIds())
  # ---- tables
  of "tableCellAt":
    let (ok, box) = g.tableCellAtWorld(g.itemArg(A(0)), toPt(A(1)))
    result = if ok: cellBoxVal(box) else: jnull
  of "getCell":
    let node = g.itemArg(A(0))
    result = if node == nil: jnull else: g.getCell(node, int(N(1)), int(N(2)))
  of "setCell":
    let node = g.itemArg(A(0))
    if node != nil: g.setCell(node, int(N(1)), int(N(2)), A(3), S(4))
  of "createTable": result = g.createTable(A(0))
  of "getTableCell": result = g.getTableCell(A(0), N(1), N(2))
  of "setTableCell": result = jbool(g.setTableCell(A(0), N(1), N(2), A(3), A(4)))
  of "insertTableRow": result = jbool(g.insertTableRow(A(0), A(1)))
  of "deleteTableRow": result = jbool(g.deleteTableRow(A(0), A(1)))
  of "insertTableColumn": result = jbool(g.insertTableColumn(A(0), A(1)))
  of "deleteTableColumn": result = jbool(g.deleteTableColumn(A(0), A(1)))
  of "mergeTableCells": result = jbool(g.mergeTableCells(A(0), A(1), A(2), A(3), A(4)))
  of "unmergeTableCell", "splitTableCell": result = jbool(g.splitTableCell(A(0), N(1), N(2)))
  of "changeTableSize": g.changeTableSize(g.itemArg(A(0)), N(1), N(2))
  # ---- media and misc
  of "insertMedia":
    let p = A(2)
    result = g.insertMedia(S(0), S(1), if truthy(p): p else: nil, S(3))
  of "autosizeSelection": g.autosizeSelection()
  of "copySize": g.copySize()
  of "pasteSize": g.pasteSize()
  of "clearLabels": g.clearLabels()
  of "deleteAll": g.deleteAll()
  of "resetView": g.resetView()
  of "fitPage": g.fitPage(B(0, false))
  of "toggleLock": g.toggleLock()
  of "alignSelection": g.alignSelection(S(0))
  of "distributeSelection": g.distributeSelection(S(0))
  of "rotateSelection": g.rotateSelection(N(0))
  of "nudgeSelection": g.nudgeSelection(N(0), N(1))
  of "flipSelection": g.flipSelection(S(0))
  of "resetWaypoints": g.resetWaypoints()
  of "addWaypointToSelection": g.addWaypointToSelection(A(0))
  of "reverseEdges": g.reverseEdges()
  of "flipCircularArc": g.flipCircularArc()
  of "copyStyle": g.copyStyle()
  of "pasteStyle": g.pasteStyle()
  of "setDefaultStyle": g.setDefaultStyle()
  of "clearDefaultStyle": g.clearDefaultStyle()
  of "setDiagramOptions": g.setDiagramOptions(if A(0).isObj: A(0) else: newObj())
  of "layoutStackContainers": result = itemsVal(g.layoutStackContainers(idsArg(A(0))))
  of "startTextEdit":
    let node = g.itemArg(A(0))
    if node != nil: g.startTextEdit(node)
  of "finishTextEdit": g.finishTextEdit(B(0, true))
  of "isEditingText": result = jbool(g.isEditingText())
  of "hideTooltip": g.hideTooltip()
  of "openLink": result = jbool(g.openLink(S(0)))
  of "connectVertex":
    let dp = A(2)
    result = g.connectVertex(g.itemArg(A(0)), S(1), truthy(dp), if truthy(dp): toPt(dp) else: Pt(), S(3))
  # ---- view
  of "getViewState": result = g.getViewState()
  of "updateWorldSize": g.updateWorldSize()
  of "setZoom":
    let p = A(1)
    g.setZoom(N(0), truthy(p), if truthy(p): num(p["x"]) else: 0.0, if truthy(p): num(p["y"]) else: 0.0)
  of "zoomIn": g.zoomIn()
  of "zoomOut": g.zoomOut()
  of "zoomActual": g.zoomActual()
  of "fit": g.fit()
  of "getAllBounds": result = rectVal(g.getAllBounds())
  of "boundsOfItems":
    var list: seq[Val]
    for id in idsArg(A(0)):
      let it = g.byId.getOrDefault(id, nil)
      if it != nil: list.add it
    let (ok, r) = g.boundsOfItems(list)
    result = if ok: rectVal(r) else: jnull
  of "worldToScreen": result = ptVal(g.worldToScreen(toPt(A(0))))
  of "screenToWorld": result = ptVal(g.eventWorld(toPt(A(0))))
  of "hitTest": result = (let h = g.hitTest(toPt(A(0)), S(1)); if h == nil: jnull else: h)
  of "render": g.render(B(0, false))
  of "drawOverlay": g.drawOverlay()
  # ---- properties
  of "get": result = g.getProp(S(0))
  of "set": g.setProp(S(0), A(1))
  else:
    raise newException(JsonError, "Unknown graph method: " & m)
