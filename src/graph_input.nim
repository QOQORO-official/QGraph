# Included from graph.nim: pointer/keyboard input, drag actions, container
# (stack) layouts and containment, label editing, context menu and drop.



proc setCursor(g: Graph, cursor: string) =
  if cursor == g.cursor: return
  g.cursor = cursor
  if g.hooks.cursor != nil: g.hooks.cursor(cursor)

proc hideTooltip*(g: Graph) =
  if g.hooks.tooltip != nil: g.hooks.tooltip(false, "", "")

proc updateTooltip(g: Graph, hit: Val) =
  var text = ""
  if hit != nil and not (hit["mediaLayers"].isArr and hit["mediaLayers"].len > 0):
    if truthy(hit["tooltip"]): text = str(hit["tooltip"])
    elif truthy(hit["link"]): text = str(hit["link"])
  if not g.tooltipsEnabled or text.len == 0:
    g.hideTooltip()
    return
  if g.hooks.tooltip != nil: g.hooks.tooltip(true, idOf(hit), text)

proc hitFoldingBadge(g: Graph, world: Pt, node: Val): bool =
  world.x >= nodeX(node) + 2 and world.x <= nodeX(node) + 17 and
    world.y >= nodeY(node) + 2 and world.y <= nodeY(node) + 17

proc toggleFoldFor(g: Graph, node: Val) =
  if node.nul("foldOf"):
    g.toggleContainerFold(node)
    return
  let foldOf = str(node["foldOf"])
  var members: seq[Val]
  for it in g.items:
    if not nullish(it["foldedBy"]) and str(it["foldedBy"]) == foldOf: members.add it
  if members.len == 0: return
  let (_, b) = g.boundsOfItems(members)
  g.toggleFoldGroup(GroupInfo(id: foldOf, items: members, bounds: b))

proc cloneById(g: Graph, items: openArray[Val], includeLocked = false): OrderedTable[string, Val] =
  for it in items:
    if not it.eqs("type", "edge") and (includeLocked or not it.tr("locked")):
      result[idOf(it)] = clone(it)

proc getContainedDescendants*(g: Graph, containerIds: seq[string]): seq[Val] =
  var parents = initHashSet[string]()
  for id in containerIds: parents.incl id
  var added = true
  while added:
    added = false
    for item in g.items:
      if item.eqs("type", "edge") or not item.tr("containerId") or
          not parents.contains(str(item["containerId"])) or parents.contains(idOf(item)): continue
      parents.incl idOf(item)
      result.add item
      added = true

proc selectionCellForHit(g: Graph, hit: Val, alt: bool): Val =
  if hit == nil or hit.eqs("type", "edge") or alt: return hit
  result = hit
  var seen = initHashSet[string]()
  while result.tr("containerId") and not seen.containsOrIncl(str(result["containerId"])):
    let parent = lookup(g.byId, result["containerId"])
    if parent == nil or g.isSelected(idOf(parent)) or parent.eqs("shape", "swimlane"): break
    result = parent

# ------------------------------------------------------ stack layout --

proc layoutStackContainer(g: Graph, container: Val): seq[Val] =
  if container == nil or not container.eqs("childLayout", "stackLayout"): return
  let horizontal = not container["stackHorizontal"].isFalse
  let spacing = container.nor("stackSpacing", 0)
  let border = container.nor("stackBorder", 0)
  let marginLeft = container.nor("marginLeft", 0)
  let marginRight = container.nor("marginRight", 0)
  let marginTop = container.nor("marginTop", 0)
  let marginBottom = container.nor("marginBottom", 0)
  let cid = idOf(container)
  var children: seq[Val]
  for it in g.items:
    if not it.eqs("type", "edge") and not nullish(it["containerId"]) and str(it["containerId"]) == cid and
        it["containerId"].isStr and not it["visible"].isFalse and not it.tr("foldedAway"):
      children.add it
  children.sort(proc (a, b: Val): int =
    let av = if horizontal: nodeX(a) else: nodeY(a)
    let bv = if horizontal: nodeX(b) else: nodeY(b)
    let d = if av != bv: av - bv else: a.fo("z", 0) - b.fo("z", 0)
    if d < 0: -1 elif d > 0: 1 else: 0)

  var x0 = nodeX(container) + border + marginLeft
  var y0 = nodeY(container) + border + marginTop
  var fill = if horizontal: nodeH(container) - marginTop - marginBottom - 2 * border
             else: nodeW(container) - marginLeft - marginRight - 2 * border
  let isSwimlane = container.eqs("shape", "swimlane")
  let header = if isSwimlane: jsMax(0, container.nn("headerHeight", 26)) else: 0.0
  let headerHorizontal = not container["horizontal"].isFalse
  if isSwimlane:
    if horizontal == headerHorizontal: fill -= header
    if headerHorizontal: y0 += header
    else: x0 += header
  fill = jsMax(1, fill)

  if children.len == 0:
    if container["resizeParent"].isFalse or container.tr("resizeParentMax"): return
    var emptySize = if horizontal: x0 - nodeX(container) + marginRight + border
                    else: y0 - nodeY(container) + marginBottom + border
    emptySize = jsMax(1, emptySize)
    let currentSize = if horizontal: nodeW(container) else: nodeH(container)
    if emptySize == currentSize: return
    if horizontal: container["width"] = jnum(emptySize)
    else: container["height"] = jnum(emptySize)
    g.reindexNodeAndEdges(container)
    g.rendererUpsert([container], true)
    return @[container]

  var changed: seq[Val]
  var changedIds = initHashSet[string]()
  var hasPreviousEnd = false
  var previousEnd = 0.0
  var last: Val = nil
  var processedGroups = initHashSet[string]()
  proc mark(item: Val) =
    if not changedIds.containsOrIncl(idOf(item)): changed.add item

  for child in children:
    let stackGroup = if child["groups"].isArr and child["groups"].len > 0: strOrEmpty(child["groups"][0]) else: ""
    if stackGroup.len > 0 and processedGroups.contains(stackGroup): continue
    let oldX = nodeX(child)
    let oldY = nodeY(child)
    let oldWidth = nodeW(child)
    let oldHeight = nodeH(child)
    var nextPrimary = if not hasPreviousEnd: (if horizontal: x0 else: y0) else: previousEnd + spacing
    if container.tr("allowStackGaps"):
      nextPrimary = jsMax(nextPrimary, if horizontal: nodeX(child) else: nodeY(child))
    if stackGroup.len > 0:
      processedGroups.incl stackGroup
      var groupChildren: seq[Val]
      for candidate in children:
        if candidate["groups"].isArr and strOrEmpty(candidate["groups"][0]) == stackGroup and
            candidate["groups"].len > 0:
          groupChildren.add candidate
      let (_, gb) = g.boundsOfItems(groupChildren)
      let groupDx = if horizontal: nextPrimary - gb.x else: x0 - gb.x
      let groupDy = if horizontal: y0 - gb.y else: nextPrimary - gb.y
      for member in groupChildren:
        member["x"] = jnum(nodeX(member) + groupDx)
        member["y"] = jnum(nodeY(member) + groupDy)
        mark(member)
        for d in g.getContainedDescendants(@[idOf(member)]):
          d["x"] = jnum(nodeX(d) + groupDx)
          d["y"] = jnum(nodeY(d) + groupDy)
          mark(d)
      previousEnd = nextPrimary + (if horizontal: gb.width else: gb.height)
      hasPreviousEnd = true
      last = nil
      continue
    if horizontal:
      child["x"] = jnum(nextPrimary)
      child["y"] = jnum(y0)
      child["height"] = jnum(fill)
      previousEnd = nodeX(child) + nodeW(child)
    else:
      child["x"] = jnum(x0)
      child["y"] = jnum(nextPrimary)
      child["width"] = jnum(fill)
      previousEnd = nodeY(child) + nodeH(child)
    hasPreviousEnd = true
    let dx = nodeX(child) - oldX
    let dy = nodeY(child) - oldY
    if dx != 0 or dy != 0:
      for d in g.getContainedDescendants(@[idOf(child)]):
        d["x"] = jnum(nodeX(d) + dx)
        d["y"] = jnum(nodeY(d) + dy)
        mark(d)
    if dx != 0 or dy != 0 or nodeW(child) != oldWidth or nodeH(child) != oldHeight: mark(child)
    last = child

  if not container["resizeParent"].isFalse and hasPreviousEnd:
    var nextSize = previousEnd - (if horizontal: nodeX(container) else: nodeY(container)) +
      (if horizontal: marginRight else: marginBottom) + border
    let oldSize = if horizontal: nodeW(container) else: nodeH(container)
    if container.tr("resizeParentMax"): nextSize = jsMax(oldSize, nextSize)
    nextSize = jsMax(1, nextSize)
    if nextSize != oldSize:
      if horizontal: container["width"] = jnum(nextSize)
      else: container["height"] = jnum(nextSize)
      mark(container)
  elif container.tr("resizeLast") and last != nil:
    if horizontal:
      last["width"] = jnum(jsMax(1, nodeX(container) + nodeW(container) - nodeX(last) - marginRight - border))
    else:
      last["height"] = jnum(jsMax(1, nodeY(container) + nodeH(container) - nodeY(last) - marginBottom - border))
    mark(last)

  for c in changed: g.reindexNodeAndEdges(c)
  if changed.len > 0: g.rendererUpsert(changed, true)
  changed

proc containerDepth(g: Graph, id: string): int =
  var item = g.byId.getOrDefault(id, nil)
  var seen = initHashSet[string]()
  while item != nil and item.tr("containerId") and not seen.containsOrIncl(str(item["containerId"])):
    inc result
    item = lookup(g.byId, item["containerId"])

proc layoutStackContainers*(g: Graph, containerIds: seq[string]): seq[Val] =
  var queue = containerIds
  queue.sort(proc (a, b: string): int = cmp(g.containerDepth(b), g.containerDepth(a)))
  var visited = initHashSet[string]()
  while queue.len > 0:
    let id = queue[0]
    queue.delete(0)
    if id.len == 0 or visited.containsOrIncl(id): continue
    let container = g.byId.getOrDefault(id, nil)
    if container == nil: continue
    result.add g.layoutStackContainer(container)
    if container.tr("containerId"): queue.add str(container["containerId"])

proc extendParentContainersOf*(g: Graph, items: seq[Val]): seq[Val] =
  var queue: seq[string]
  var visited = initHashSet[string]()
  var changedIds = initHashSet[string]()
  for it in items:
    if it != nil and it.tr("containerId"): queue.add str(it["containerId"])
  while queue.len > 0:
    let parentId = queue[0]
    queue.delete(0)
    if parentId.len == 0 or visited.containsOrIncl(parentId): continue
    let parent = g.byId.getOrDefault(parentId, nil)
    if parent == nil: continue
    if not parent.eqs("childLayout", "stackLayout"):
      var children: seq[Val]
      for it in g.items:
        if not it.eqs("type", "edge") and it.tr("containerId") and str(it["containerId"]) == idOf(parent) and
            not it["visible"].isFalse and not it.tr("foldedAway"):
          children.add it
      let (ok, b) = g.boundsOfItems(children)
      if ok:
        let nextWidth = jsMax(nodeW(parent), b.x + b.width - nodeX(parent))
        let nextHeight = jsMax(nodeH(parent), b.y + b.height - nodeY(parent))
        if nextWidth != nodeW(parent) or nextHeight != nodeH(parent):
          parent["width"] = jnum(nextWidth)
          parent["height"] = jnum(nextHeight)
          g.reindexNodeAndEdges(parent)
          if not changedIds.containsOrIncl(idOf(parent)): result.add parent
    if parent.tr("containerId"): queue.add str(parent["containerId"])
  if result.len > 0: g.rendererUpsert(result, true)

proc layoutParentContainersOf(g: Graph, items: seq[Val]): seq[Val] =
  var ids: seq[string]
  for it in items:
    if it != nil and it.tr("containerId"):
      let p = str(it["containerId"])
      if not ids.contains(p): ids.add p
  result = g.layoutStackContainers(ids)
  result.add g.extendParentContainersOf(items)

proc containmentRoots(g: Graph, items: seq[Val]): seq[Val] =
  var selected = initHashSet[string]()
  for it in items: selected.incl idOf(it)
  for it in items:
    var parentId = if it.tr("containerId"): str(it["containerId"]) else: ""
    var seen = initHashSet[string]()
    var isRoot = true
    while parentId.len > 0 and not seen.contains(parentId):
      if selected.contains(parentId):
        isRoot = false
        break
      seen.incl parentId
      let parent = g.byId.getOrDefault(parentId, nil)
      parentId = if parent != nil and parent.tr("containerId"): str(parent["containerId"]) else: ""
    if isRoot: result.add it

proc isDedicatedContainer(g: Graph, item: Val): bool =
  if item == nil or item.eqs("type", "edge") or item.eqs("kind", "listItem"): return false
  if item.eqs("containerRole", "container") or item.eqs("containerRole", "list"): return true
  if item.eqs("kind", "container") or item.eqs("kind", "list") or item.eqs("kind", "taskList"): return true
  item["container"].isTrue or not item.nul("childLayout") or item.eqs("shape", "swimlane")

proc isContainerDropTarget(g: Graph, item: Val, movedIds: HashSet[string]): bool =
  if item == nil or item.eqs("type", "edge") or item["visible"].isFalse or item.tr("foldedAway") or
      item.tr("collapsed") or movedIds.contains(idOf(item)) or item.tr("locked") or
      item.eqs("shape", "text") or item.eqs("shape", "image") or item.eqs("shape", "table"): return false
  if not g.isDedicatedContainer(item): return false
  if item["dropTarget"].isFalse or (item["part"].isTrue and not item["container"].isTrue): return false
  if item.eqs("fill", "transparent") and not item.eqs("shape", "swimlane") and not item["container"].isTrue:
    return false
  true

proc isBlockContainmentItem(g: Graph, item: Val): bool =
  if item == nil or item.eqs("type", "edge"): return false
  if item["container"].isTrue or item.tr("childLayout") or item.eqs("shape", "swimlane") or
      item.eqs("kind", "taskList") or item.eqs("kind", "listItem"): return true
  if item.eqs("shape", "text") or item.eqs("shape", "html") or item.eqs("shape", "image") or
      item.eqs("kind", "label"): return false
  let transparentFill = item.nul("fill") or item.eqs("fill", "transparent") or item.eqs("fill", "none")
  let transparentStroke = item.nul("stroke") or item.eqs("stroke", "transparent") or
    item.eqs("stroke", "none") or item.nm("strokeWidth") == 0
  not (transparentFill and transparentStroke)

proc isDescendantOf(g: Graph, item: Val, ancestorId: string): bool =
  var parentId = if item != nil and item.tr("containerId"): str(item["containerId"]) else: ""
  var seen = initHashSet[string]()
  while parentId.len > 0 and not seen.contains(parentId):
    if parentId == ancestorId: return true
    seen.incl parentId
    let parent = g.byId.getOrDefault(parentId, nil)
    parentId = if parent != nil and parent.tr("containerId"): str(parent["containerId"]) else: ""
  false

proc itemDepth(g: Graph, item: Val): int =
  var parentId = if item != nil and item.tr("containerId"): str(item["containerId"]) else: ""
  var seen = initHashSet[string]()
  while parentId.len > 0 and not seen.containsOrIncl(parentId):
    inc result
    let parent = g.byId.getOrDefault(parentId, nil)
    parentId = if parent != nil and parent.tr("containerId"): str(parent["containerId"]) else: ""

proc findContainerTargets(g: Graph, rootIds: seq[string], movedIds: HashSet[string],
                          hasPointer: bool, pointer: Pt): seq[Val] =
  var roots: seq[Val]
  for id in rootIds:
    let it = g.byId.getOrDefault(id, nil)
    if it != nil: roots.add it
  let (ok, b) = g.boundsOfItems(roots)
  if not ok: return
  let dropPoint = if hasPointer: pointer else: pt(b.x + b.width / 2, b.y + b.height / 2)
  var candidates: seq[Val]
  for item in g.items:
    if g.isContainerDropTarget(item, movedIds) and g.pointInNode(dropPoint, item): candidates.add item
  candidates.sort(proc (a, b: Val): int =
    let level = g.itemDepth(a) - g.itemDepth(b)
    if level != 0: return level
    let z = b.fo("z", 0) - a.fo("z", 0)
    if z != 0: return (if z < 0: -1 else: 1)
    let area = nodeW(b) * nodeH(b) - nodeW(a) * nodeH(a)
    if area < 0: -1 elif area > 0: 1 else: 0)
  if candidates.len == 0: return
  result = @[candidates[0]]
  var current = candidates[0]
  while true:
    var children: seq[Val]
    for c in candidates:
      if idOf(c) != idOf(current) and g.isDescendantOf(c, idOf(current)): children.add c
    if children.len == 0: break
    children.sort(proc (a, b: Val): int =
      let level = g.itemDepth(a) - g.itemDepth(b)
      if level != 0: return level
      let z = b.fo("z", 0) - a.fo("z", 0)
      if z != 0: return (if z < 0: -1 else: 1)
      let area = nodeW(a) * nodeH(a) - nodeW(b) * nodeH(b)
      if area < 0: -1 elif area > 0: 1 else: 0)
    current = children[0]
    result.add current

proc findContainerTarget(g: Graph, rootIds: seq[string], movedIds: HashSet[string],
                         hasPointer: bool, pointer: Pt): Val =
  var roots: seq[Val]
  for id in rootIds:
    let it = g.byId.getOrDefault(id, nil)
    if it != nil: roots.add it
  let (hasBounds, sb) = g.boundsOfItems(roots)
  let hasDrop = hasPointer or hasBounds
  let dropPoint = if hasPointer: pointer else: pt(sb.x + sb.width / 2, sb.y + sb.height / 2)
  var blockMove = false
  for r in roots:
    if g.isBlockContainmentItem(r):
      blockMove = true
      break
  if not blockMove:
    let contentTargets = g.findContainerTargets(rootIds, movedIds, hasPointer, pointer)
    if contentTargets.len > 0: return contentTargets[^1]
    let originalParentId = if roots.len > 0 and roots[0].tr("containerId"): str(roots[0]["containerId"]) else: ""
    var sameOriginalParent = originalParentId.len > 0
    if sameOriginalParent:
      for it in roots:
        if strOrEmpty(it["containerId"]) != originalParentId or not it.tr("containerId"):
          sameOriginalParent = false
          break
    let originalParent = if sameOriginalParent: g.byId.getOrDefault(originalParentId, nil) else: nil
    if originalParent != nil and hasDrop and g.pointInNode(dropPoint, originalParent): return originalParent
    return nil
  let candidates = g.findContainerTargets(rootIds, movedIds, hasPointer, pointer)
  if candidates.len > 0: candidates[^1] else: nil

proc finishContainment(g: Graph, action: Action) =
  let target = if action.dropTargetId.len > 0: g.byId.getOrDefault(action.dropTargetId, nil) else: nil
  var changed: seq[Val]
  var affectedContainers: seq[string]
  var nextZ = if target != nil: target.fo("z", 0) + 1 else: 0.0
  for id in action.rootIds:
    let item = g.byId.getOrDefault(id, nil)
    if item == nil: continue
    let previous = if item.tr("containerId"): str(item["containerId"]) else: ""
    if previous.len > 0: affectedContainers.add previous
    let fixedId = action.fixedContainerByRoot.getOrDefault(idOf(item), "")
    let fixedParent = if fixedId.len > 0: g.byId.getOrDefault(fixedId, nil) else: nil
    if fixedParent != nil:
      item["containerId"] = fixedParent["id"]
      fixedParent["container"] = jtrue
      affectedContainers.add idOf(fixedParent)
    elif target != nil:
      item["containerId"] = target["id"]
      target["container"] = jtrue
      if item.fo("z", 0) <= target.fo("z", 0):
        item["z"] = jnum(nextZ)
        nextZ += 1
    else:
      item.del("containerId")
    let now = if item.tr("containerId"): str(item["containerId"]) else: ""
    if previous != now: changed.add item
  if target != nil:
    changed.add target
    affectedContainers.add idOf(target)
  if changed.len > 0: g.rendererUpsert(changed)
  discard g.layoutStackContainers(affectedContainers)
  var rootItems: seq[Val]
  for id in action.rootIds:
    let it = g.byId.getOrDefault(id, nil)
    if it != nil: rootItems.add it
  discard g.extendParentContainersOf(rootItems)

# ------------------------------------------------------- move actions --

proc startMoveAction(g: Graph, world: Pt, before: string): Action =
  let selectedGroups = g.getSelectedGroups()
  var atomicGroupMembers = initHashSet[string]()
  for grp in selectedGroups:
    for m in grp.items: atomicGroupMembers.incl idOf(m)
  var selected: seq[Val]
  for it in g.getSelection():
    if atomicGroupMembers.contains(idOf(it)) or (not it.tr("locked") and not it["movable"].isFalse):
      selected.add it
  var selectedEdges, selectedNodes: seq[Val]
  for it in selected:
    if it.eqs("type", "edge"): selectedEdges.add it else: selectedNodes.add it
  let roots = g.containmentRoots(selectedNodes)
  var moving = selectedNodes
  var known = initHashSet[string]()
  for m in moving: known.incl idOf(m)
  var rootIds: seq[string]
  for r in roots: rootIds.add idOf(r)
  for d in g.getContainedDescendants(rootIds):
    if not known.containsOrIncl(idOf(d)): moving.add d
  let originals = g.cloneById(moving, true)
  var explicitEdges: OrderedTable[string, ExplicitEdge]
  for e in selectedEdges:
    explicitEdges[idOf(e)] = ExplicitEdge(edge: clone(e), points: edgePoints(e, g.byId))
  var originalEdges: OrderedTable[string, Val]
  for m in moving:
    let id = idOf(m)
    if not g.edgesByNode.hasKey(id): continue
    for edgeId in g.edgesByNode[id]:
      if not originalEdges.hasKey(edgeId) and g.byId.hasKey(edgeId):
        originalEdges[edgeId] = clone(g.byId[edgeId])
  var fixedContainerByRoot = initTable[string, string]()
  var groupConstraints: seq[GroupConstraint]
  for grp in selectedGroups:
    let groupRoots = g.containmentRoots(grp.items)
    if groupRoots.len == 0: continue
    let parentId = if groupRoots[0].tr("containerId"): str(groupRoots[0]["containerId"]) else: ""
    var sameParent = parentId.len > 0
    if sameParent:
      for r in groupRoots:
        if strOrEmpty(r["containerId"]) != parentId:
          sameParent = false
          break
    if not sameParent or not g.byId.hasKey(parentId): continue
    var unitIds = initHashSet[string]()
    var unitIdOrder: seq[string]
    for r in groupRoots:
      if not unitIds.containsOrIncl(idOf(r)): unitIdOrder.add idOf(r)
    for d in g.getContainedDescendants(unitIdOrder): unitIds.incl idOf(d)
    var unitItems: seq[Val]
    for m in moving:
      if unitIds.contains(idOf(m)): unitItems.add m
    let (ok, unitBounds) = g.boundsOfItems(unitItems)
    if not ok: continue
    var grIds: seq[string]
    for r in groupRoots:
      fixedContainerByRoot[idOf(r)] = parentId
      grIds.add idOf(r)
    groupConstraints.add GroupConstraint(groupId: grp.id, parentId: parentId, bounds: unitBounds,
                                         rootIds: grIds)
  if originals.len == 0 and explicitEdges.len == 0:
    return Action(kind: "select")
  Action(kind: "move", startWorld: world, hasStartWorld: true, originals: originals,
         originalEdges: originalEdges, explicitEdges: explicitEdges, rootIds: rootIds,
         moved: false, before: before, fixedContainerByRoot: fixedContainerByRoot,
         groupConstraints: groupConstraints)

proc startEdgeMoveAction(g: Graph, edge: Val, world: Pt, before: string): Action =
  Action(kind: "edgeMove", itemId: idOf(edge), startWorld: world, hasStartWorld: true,
         original: clone(edge), originalPoints: edgePoints(edge, g.byId), before: before)

proc containerContentBounds(g: Graph, container: Val): Rect =
  result = rect(nodeX(container), nodeY(container), nodeW(container), nodeH(container))
  if container.eqs("shape", "swimlane"):
    let vertical = container["horizontal"].isFalse
    let header = jsMax(0, jsMin(if vertical: result.width else: result.height,
                                container.nn("headerHeight", 26)))
    if vertical:
      result.x += header
      result.width -= header
    else:
      result.y += header
      result.height -= header

proc stopDragAutoScroll(g: Graph) =
  g.dragAutoScroll = false
  if g.dragAutoScrollTimer:
    g.dragAutoScrollTimer = false
    if g.hooks.timer != nil: g.hooks.timer("autoscroll", 0, true)

proc updateDragAutoScroll(g: Graph, screen: Pt, alt: bool) =
  if g.pageView or g.action == nil or g.action.kind != "move":
    g.stopDragAutoScroll()
    return
  const threshold = 44.0
  let m = viewMetrics()
  let width = max(1.0, m.clientWidth)
  let height = max(1.0, m.clientHeight)
  proc edgeSpeed(position, size: float64): float64 =
    if position < threshold: return -min(28.0, max(5.0, (threshold - position) * 0.55))
    if position > size - threshold: return min(28.0, max(5.0, (position - size + threshold) * 0.55))
    0.0
  let dx = edgeSpeed(screen.x, width)
  let dy = edgeSpeed(screen.y, height)
  if dx == 0 and dy == 0:
    g.stopDragAutoScroll()
    return
  g.dragAutoScroll = true
  g.dragAutoScrollDx = dx
  g.dragAutoScrollDy = dy
  g.dragAutoScrollScreen = screen
  g.dragAutoScrollNoSnap = alt
  if g.dragAutoScrollTimer: return
  g.dragAutoScrollTimer = true
  if g.hooks.timer != nil: g.hooks.timer("autoscroll", 30, false)

proc dragAutoScrollTick*(g: Graph) =
  g.dragAutoScrollTimer = false
  if not g.dragAutoScroll or g.action == nil or g.action.kind != "move" or g.pageView: return
  g.updateWorldSize()
  var m = viewMetrics()
  setScroll(m.scrollLeft + g.dragAutoScrollDx, NaN)
  m = viewMetrics()
  setScroll(NaN, m.scrollTop + g.dragAutoScrollDy)
  g.updateWorldSize()
  m = viewMetrics()
  let world = pt((g.dragAutoScrollScreen.x + m.scrollLeft) / g.zoom - g.worldOriginX,
                 (g.dragAutoScrollScreen.y + m.scrollTop) / g.zoom - g.worldOriginY)
  g.moveAction(world, g.dragAutoScrollNoSnap)
  if g.dragAutoScroll and g.action != nil and g.action.kind == "move":
    g.dragAutoScrollTimer = true
    if g.hooks.timer != nil: g.hooks.timer("autoscroll", 30, false)

proc followMovedConnectorCorners(g: Graph, action: Action, movedIds: HashSet[string],
                                 dx, dy: float64): seq[Val] =
  proc oldTerminalPoint(edge: Val, source: bool): (bool, Pt) =
    let idV = if source: edge["sourceId"] else: edge["targetId"]
    let id = strOrEmpty(idV)
    var node = if not nullish(idV) and action.originals.hasKey(id): action.originals[id] else: nil
    if node == nil: node = lookup(g.byId, idV)
    if node == nil:
      let p = if source: edge["sourcePoint"] else: edge["targetPoint"]
      if truthy(p): return (true, toPt(p))
      return (false, Pt())
    let anchor = if source: edge["sourceAnchor"] else: edge["targetAnchor"]
    var side = if truthy(anchor) and truthy(anchor["side"]): str(anchor["side"]) else: ""
    if side.len == 0:
      let s = if source: edge["sourceSide"] else: edge["targetSide"]
      side = if truthy(s): str(s) elif source: "east" else: "west"
    (true, nodeAnchor(node, anchor, side))

  for edgeId in jsKeysOf(action.originalEdges):
    let original = action.originalEdges[edgeId]
    let edge = g.byId.getOrDefault(edgeId, nil)
    if edge == nil or not edge.eqs("lineStyle", "orthogonal") or not original["route"].isArr or
        original["route"].len == 0: continue
    let sourceMoved = not nullish(original["sourceId"]) and movedIds.contains(str(original["sourceId"]))
    let targetMoved = not nullish(original["targetId"]) and movedIds.contains(str(original["targetId"]))
    if not sourceMoved and not targetMoved: continue
    let route = clone(original["route"])
    if sourceMoved and targetMoved:
      for r in route:
        r["x"] = jnum(num(r["x"]) + dx)
        r["y"] = jnum(num(r["y"]) + dy)
    elif sourceMoved:
      let (has, oldSource) = oldTerminalPoint(original, true)
      let first = route[0]
      let sa = original["sourceAnchor"]
      let sourceSide = if truthy(sa) and truthy(sa["side"]): str(sa["side"])
                       else: original.so("sourceSide", "east")
      if has and abs(num(first["y"]) - oldSource.y) <= 1: first["y"] = jnum(num(first["y"]) + dy)
      elif has and abs(num(first["x"]) - oldSource.x) <= 1: first["x"] = jnum(num(first["x"]) + dx)
      elif sourceSide == "east" or sourceSide == "west": first["y"] = jnum(num(first["y"]) + dy)
      else: first["x"] = jnum(num(first["x"]) + dx)
    elif targetMoved:
      let (has, oldTarget) = oldTerminalPoint(original, false)
      let last = route[route.len - 1]
      let ta = original["targetAnchor"]
      let targetSide = if truthy(ta) and truthy(ta["side"]): str(ta["side"])
                       else: original.so("targetSide", "west")
      if has and abs(num(last["y"]) - oldTarget.y) <= 1: last["y"] = jnum(num(last["y"]) + dy)
      elif has and abs(num(last["x"]) - oldTarget.x) <= 1: last["x"] = jnum(num(last["x"]) + dx)
      elif targetSide == "east" or targetSide == "west": last["y"] = jnum(num(last["y"]) + dy)
      else: last["x"] = jnum(num(last["x"]) + dx)
    edge["route"] = route
    g.reindex(edge)
    result.add edge

proc moveExplicitEdges(g: Graph, action: Action, movedIds: HashSet[string], dx, dy: float64): seq[Val] =
  for edgeId in jsKeysOf(action.explicitEdges):
    let record = action.explicitEdges[edgeId]
    let original = record.edge
    let edge = g.byId.getOrDefault(edgeId, nil)
    let points = record.points
    if edge == nil or points.len < 2: continue
    var translated: seq[Pt]
    for p in points: translated.add pt(p.x + dx, p.y + dy)
    let keepSource = not nullish(original["sourceId"]) and movedIds.contains(str(original["sourceId"]))
    let keepTarget = not nullish(original["targetId"]) and movedIds.contains(str(original["targetId"]))
    g.unregisterEdge(edge)
    edge["sourceId"] = if keepSource: original["sourceId"] else: jnull
    edge["targetId"] = if keepTarget: original["targetId"] else: jnull
    edge["sourceSide"] = original["sourceSide"]
    edge["targetSide"] = original["targetSide"]
    edge["sourceAnchor"] = if keepSource and truthy(original["sourceAnchor"]): clone(original["sourceAnchor"]) else: jnull
    edge["targetAnchor"] = if keepTarget and truthy(original["targetAnchor"]): clone(original["targetAnchor"]) else: jnull
    if keepSource: edge.del("sourcePoint") else: edge["sourcePoint"] = ptVal(translated[0])
    if keepTarget: edge.del("targetPoint") else: edge["targetPoint"] = ptVal(translated[^1])
    edge["route"] = if translated.len > 2: ptsVal(translated[1 ..< translated.len - 1]) else: jnull
    g.registerEdge(edge)
    g.reindex(edge)
    if not action.detachedExplicitEdges.contains(edgeId):
      g.rendererRemove([edgeId])
      action.detachedExplicitEdges.incl edgeId
    result.add edge

proc moveAction(g: Graph, world: Pt, noSnap: bool) =
  let action = g.action
  let dx = world.x - action.startWorld.x
  let dy = world.y - action.startWorld.y
  if not action.moved and abs(dx) < 0.5 / g.zoom and abs(dy) < 0.5 / g.zoom: return
  action.moved = true
  var changed: seq[Val]
  let useGrid = not noSnap and g.gridEnabled
  var guideDx = 0.0
  var guideDy = 0.0
  action.hasGuideX = false
  action.hasGuideY = false
  let keys = jsKeysOf(action.originals)
  let first = if keys.len > 0: action.originals[keys[0]] else: nil

  if g.guidesEnabled and not noSnap and first != nil:
    var movingIds = initHashSet[string]()
    for k in keys: movingIds.incl k
    let px = if useGrid: snap(nodeX(first) + dx, g.gridSize) else: nodeX(first) + dx
    let py = if useGrid: snap(nodeY(first) + dy, g.gridSize) else: nodeY(first) + dy
    let xAnchors = [px, px + nodeW(first) / 2, px + nodeW(first)]
    let yAnchors = [py, py + nodeH(first) / 2, py + nodeH(first)]
    let tolerance = 6 / g.zoom
    var bestX = tolerance
    var bestY = tolerance
    for other in g.items:
      if other.eqs("type", "edge") or movingIds.contains(idOf(other)) or other["visible"].isFalse: continue
      let ox = [nodeX(other), nodeX(other) + nodeW(other) / 2, nodeX(other) + nodeW(other)]
      let oy = [nodeY(other), nodeY(other) + nodeH(other) / 2, nodeY(other) + nodeH(other)]
      for ax in xAnchors:
        for bx in ox:
          let deltaX = bx - ax
          if abs(deltaX) < abs(bestX):
            bestX = deltaX
            guideDx = deltaX
            action.guideX = bx
            action.hasGuideX = true
      for ay in yAnchors:
        for by in oy:
          let deltaY = by - ay
          if abs(deltaY) < abs(bestY):
            bestY = deltaY
            guideDy = deltaY
            action.guideY = by
            action.hasGuideY = true

  var appliedDx = if first != nil and useGrid: snap(nodeX(first) + dx, g.gridSize) - nodeX(first) else: dx
  var appliedDy = if first != nil and useGrid: snap(nodeY(first) + dy, g.gridSize) - nodeY(first) else: dy
  appliedDx += guideDx
  appliedDy += guideDy

  for constraint in action.groupConstraints:
    let parent = g.byId.getOrDefault(constraint.parentId, nil)
    if parent == nil: continue
    let content = g.containerContentBounds(parent)
    let minDx = content.x - constraint.bounds.x
    let maxDx = content.x + content.width - constraint.bounds.x - constraint.bounds.width
    let minDy = content.y - constraint.bounds.y
    let maxDy = content.y + content.height - constraint.bounds.y - constraint.bounds.height
    appliedDx = if minDx <= maxDx: clamp(appliedDx, minDx, maxDx) else: 0.0
    appliedDy = if minDy <= maxDy: clamp(appliedDy, minDy, maxDy) else: 0.0

  for id in keys:
    let original = action.originals[id]
    let item = g.byId.getOrDefault(id, nil)
    if item == nil: continue
    item["x"] = jnum(nodeX(original) + appliedDx)
    item["y"] = jnum(nodeY(original) + appliedDy)
    g.reindexNodeAndEdges(item)
    changed.add item
  var movedIds = initHashSet[string]()
  for k in keys: movedIds.incl k
  for e in g.followMovedConnectorCorners(action, movedIds, appliedDx, appliedDy): changed.add e
  for e in g.moveExplicitEdges(action, movedIds, appliedDx, appliedDy):
    if not changed.contains(e): changed.add e
  var dropTarget = g.findContainerTarget(action.rootIds, movedIds, true, world)
  var fixedParentId = ""
  var rootsFixedTogether = action.rootIds.len > 0
  for rootId in action.rootIds:
    let f = action.fixedContainerByRoot.getOrDefault(rootId, "")
    if f.len == 0:
      rootsFixedTogether = false
      break
    if fixedParentId.len == 0: fixedParentId = f
    if f != fixedParentId:
      rootsFixedTogether = false
      break
  if rootsFixedTogether and g.byId.hasKey(fixedParentId): dropTarget = g.byId[fixedParentId]
  action.dropTargetId = if dropTarget != nil: idOf(dropTarget) else: ""
  g.rendererUpsert(changed, true)
  g.updateWorldSize()
  g.render(true)

proc edgeMoveAction(g: Graph, world: Pt, noSnap: bool) =
  let action = g.action
  let edge = g.byId.getOrDefault(action.itemId, nil)
  let points = action.originalPoints
  if edge == nil or points.len < 2: return
  let dx = world.x - action.startWorld.x
  let dy = world.y - action.startWorld.y
  if not action.moved and abs(dx) < 0.5 / g.zoom and abs(dy) < 0.5 / g.zoom: return
  let useGrid = not noSnap and g.gridEnabled
  let appliedDx = if useGrid: snap(points[0].x + dx, g.gridSize) - points[0].x else: dx
  let appliedDy = if useGrid: snap(points[0].y + dy, g.gridSize) - points[0].y else: dy
  var translated: seq[Pt]
  for p in points: translated.add pt(p.x + appliedDx, p.y + appliedDy)
  if not action.detached:
    g.unregisterEdge(edge)
    action.detached = true
  edge["sourceId"] = jnull
  edge["targetId"] = jnull
  edge["sourceAnchor"] = jnull
  edge["targetAnchor"] = jnull
  edge["sourcePoint"] = ptVal(translated[0])
  edge["targetPoint"] = ptVal(translated[^1])
  edge["route"] = if translated.len > 2: ptsVal(translated[1 ..< translated.len - 1]) else: jnull
  action.moved = true
  g.reindex(edge)
  if not action.rendererDetached:
    g.rendererRemove([idOf(edge)])
    action.rendererDetached = true
  g.rendererUpsert([edge], true)
  g.updateWorldSize()
  g.render(true)

proc resizeAction(g: Graph, world: Pt, noSnap: bool) =
  let original = g.action.original
  let item = g.byId.getOrDefault(g.action.itemId, nil)
  if item == nil: return
  let center = nodeCenter(original)
  let local = rotatePoint(world, center, -rot(original))
  var left = nodeX(original)
  var right = nodeX(original) + nodeW(original)
  var top = nodeY(original)
  var bottom = nodeY(original) + nodeH(original)
  let index = g.action.handle
  if index in [0, 3, 5]: left = local.x
  if index in [2, 4, 7]: right = local.x
  if index in [0, 1, 2]: top = local.y
  if index in [5, 6, 7]: bottom = local.y
  if not noSnap and g.gridEnabled:
    left = snap(left, g.gridSize)
    right = snap(right, g.gridSize)
    top = snap(top, g.gridSize)
    bottom = snap(bottom, g.gridSize)
  if right - left < 30:
    if index in [0, 3, 5]: left = right - 30 else: right = left + 30
  if bottom - top < 24:
    if index in [0, 1, 2]: top = bottom - 24 else: bottom = top + 24
  let worldCenter = rotatePoint(pt((left + right) / 2, (top + bottom) / 2), center, rot(original))
  item["width"] = jnum(right - left)
  item["height"] = jnum(bottom - top)
  item["x"] = jnum(worldCenter.x - (right - left) / 2)
  item["y"] = jnum(worldCenter.y - (bottom - top) / 2)
  g.reindexNodeAndEdges(item)
  g.rendererUpsert([item], true)
  g.updateWorldSize()
  g.render(true)

proc round3(x: float64): float64 {.inline.} = jsRound(x * 1000) / 1000

proc customHandleAction(g: Graph, world: Pt, noSnap: bool) =
  let action = g.action
  let item = g.byId.getOrDefault(action.itemId, nil)
  let original = action.original
  if item == nil or original == nil: return
  let center = nodeCenter(original)
  let local = rotatePoint(world, center, -rot(original))
  let x = nodeX(original)
  let y = nodeY(original)
  let w = nodeW(original)
  let h = nodeH(original)
  var value: float64
  case action.customType
  of "headerSize":
    let vertical = original["horizontal"].isFalse
    value = if vertical: local.x - x else: local.y - y
    if not noSnap and g.gridEnabled: value = snap(value, g.gridSize)
    item["headerHeight"] = jnum(jsRound(clamp(value, 0, if vertical: w else: h)))
    if item.eqs("childLayout", "stackLayout"): discard g.layoutStackContainers(@[idOf(item)])
  of "cornerRadius":
    value = x + w - local.x
    if not noSnap and g.gridEnabled: value = snap(value, g.gridSize)
    item["radius"] = jnum(jsRound(clamp(value, 0, jsMin(w, h) / 2)))
  of "cylinderSize":
    item["shapeSize"] = jnum(round3(clamp((local.y - y) / h, 0, 0.5)))
  of "cubeSize":
    value = jsMax(local.x - x, local.y - y) / jsMin(w, h)
    item["shapeSize"] = jnum(round3(clamp(value, 0, 0.45)))
  of "isoCubeAngle":
    value = arctan2(clamp(local.y - y, 0, h / 2), max(1.0, w)) * 200 / PI
    item["isoAngle"] = jnum(jsRound(clamp(value, 0.01, 94) * 100) / 100)
  of "cornerCutWidth":
    value = local.x - x
    if not noSnap and g.gridEnabled: value = snap(value, g.gridSize)
    let loop = original.eqs("shape", "loopLimit")
    item["shapeSize"] = jnum(jsRound(clamp(value, 0, if loop: w / 2 else: w)))
    if item.nul("dy"):
      item["dy"] = jnum(if loop: jsRound(clamp(original.nn("shapeSize", 20), 0, w / 2) * 0.8)
                        else: jsRound(clamp(original.nn("shapeSize", 30), 0, w)))
  of "cornerCutHeight":
    value = local.y - y
    if not noSnap and g.gridEnabled: value = snap(value, g.gridSize)
    item["dy"] = jnum(jsRound(clamp(value, 0, h)))
  of "noteSize":
    value = ((x + w - local.x) + (local.y - y)) / 2 / jsMin(w, h)
    item["shapeSize"] = jnum(round3(clamp(value, 0.08, 0.5)))
  of "blockArrowSize":
    item["arrowSize"] = jnum(round3(clamp((x + w - local.x) / w, 0.1, 0.8)))
    item["arrowWidth"] = jnum(round3(clamp(1 - 2 * (local.y - y) / h, 0.1, 1)))
  of "shapeSize":
    item["shapeSize"] = jnum(round3(clamp((local.x - x) / w, 0, 0.48)))
  else: discard
  g.rendererUpsert([item], true)
  g.render(true)

proc tableResizeAction(g: Graph, world: Pt, noSnap: bool) =
  let action = g.action
  let item = g.byId.getOrDefault(action.itemId, nil)
  let original = action.original
  if item == nil or original == nil or not original.eqs("shape", "table"): return
  let center = nodeCenter(original)
  let local = rotatePoint(world, center, -rot(original))
  let grid = tableGrid(original)
  let divider = action.divider
  let minimum = jsMin(18, (if action.axis == "column": nodeW(original) else: nodeH(original)) / 4)
  if action.axis == "column":
    if divider <= 0 or divider >= grid.columns.len: return
    let left = grid.columns[divider - 1].pos
    let right = grid.columns[divider].pos + grid.columns[divider].size
    var x = if noSnap or not g.gridEnabled: local.x else: snap(local.x, g.gridSize)
    x = clamp(x, left + minimum, right - minimum)
    var w: seq[float64]
    for c in grid.columns: w.add c.size
    w[divider - 1] = x - left
    w[divider] = right - x
    item["columnWeights"] = weightsVal(w)
  else:
    if divider <= 0 or divider >= grid.rows.len: return
    let top = grid.rows[divider - 1].pos
    let bottom = grid.rows[divider].pos + grid.rows[divider].size
    var y = if noSnap or not g.gridEnabled: local.y else: snap(local.y, g.gridSize)
    y = clamp(y, top + minimum, bottom - minimum)
    var w: seq[float64]
    for r in grid.rows: w.add r.size
    w[divider - 1] = y - top
    w[divider] = bottom - y
    item["rowWeights"] = weightsVal(w)
  g.rendererUpsert([item], true)
  g.render(true)

proc groupResizeAction(g: Graph, world: Pt, noSnap: bool) =
  let frame = g.action.frame
  if frame.width <= 0 or frame.height <= 0: return
  let index = g.action.handle
  var left = frame.x
  var right = frame.x + frame.width
  var top = frame.y
  var bottom = frame.y + frame.height
  if index in [0, 3, 5]: left = world.x
  if index in [2, 4, 7]: right = world.x
  if index in [0, 1, 2]: top = world.y
  if index in [5, 6, 7]: bottom = world.y
  if not noSnap and g.gridEnabled:
    left = snap(left, g.gridSize)
    right = snap(right, g.gridSize)
    top = snap(top, g.gridSize)
    bottom = snap(bottom, g.gridSize)
  if right - left < 40:
    if index in [0, 3, 5]: left = right - 40 else: right = left + 40
  if bottom - top < 32:
    if index in [0, 1, 2]: top = bottom - 32 else: bottom = top + 32
  let scaleX = (right - left) / frame.width
  let scaleY = (bottom - top) / frame.height
  var changed: seq[Val]
  for id in jsKeysOf(g.action.originals):
    let original = g.action.originals[id]
    let item = g.byId.getOrDefault(id, nil)
    if item == nil: continue
    item["x"] = jnum(left + (nodeX(original) - frame.x) * scaleX)
    item["y"] = jnum(top + (nodeY(original) - frame.y) * scaleY)
    item["width"] = jnum(max(1.0, nodeW(original) * scaleX))
    item["height"] = jnum(max(1.0, nodeH(original) * scaleY))
    g.reindexNodeAndEdges(item)
    changed.add item
  g.rendererUpsert(changed, true)
  g.updateWorldSize()
  g.render(true)

proc applyGroupRotation(g: Graph, degrees: float64) =
  let center = g.action.center
  var changed: seq[Val]
  for id in jsKeysOf(g.action.originals):
    let original = g.action.originals[id]
    let item = g.byId.getOrDefault(id, nil)
    if item == nil: continue
    let moved = rotatePoint(pt(nodeX(original) + nodeW(original) / 2, nodeY(original) + nodeH(original) / 2),
                            center, degrees)
    item["rotation"] = jnum(jsRound(jsMod(jsMod(original.fo("rotation", 0) + degrees, 360) + 360, 360) * 10) / 10)
    item["x"] = jnum(moved.x - nodeW(original) / 2)
    item["y"] = jnum(moved.y - nodeH(original) / 2)
    g.reindexNodeAndEdges(item)
    changed.add item
  g.rendererUpsert(changed, true)
  g.updateWorldSize()
  g.render(true)

proc groupRotateAction(g: Graph, world: Pt, hardSnap, noSnap: bool) =
  let center = g.action.center
  let angle = arctan2(world.y - center.y, world.x - center.x)
  let degrees = snapRotation((angle - g.action.startAngle) * 180 / PI, hardSnap, noSnap)
  g.action.moved = true
  g.applyGroupRotation(degrees)

proc rotateAction(g: Graph, world: Pt, hardSnap, noSnap: bool) =
  let angle = arctan2(world.y - g.action.center.y, world.x - g.action.center.x)
  let degrees = snapRotation(g.action.originalRotation + (angle - g.action.startAngle) * 180 / PI,
                             hardSnap, noSnap)
  let item = g.byId.getOrDefault(g.action.itemId, nil)
  if item == nil: return
  item["rotation"] = jnum(jsRound(jsMod(jsMod(degrees, 360) + 360, 360) * 10) / 10)
  g.action.moved = true
  g.reindexNodeAndEdges(item)
  g.rendererUpsert([item], true)
  g.render(true)

proc circularArcAction(g: Graph, world: Pt, noSnap: bool) =
  let edge = g.byId.getOrDefault(g.action.itemId, nil)
  if edge == nil: return
  let circular = circularArc(edge, g.byId)
  if not circular.valid: return
  if circular.closed:
    let radius = hypot(world.x - circular.center.x, world.y - circular.center.y)
    edge["circleRadius"] = jnum(clamp(if noSnap or not g.gridEnabled: radius else: snap(radius, g.gridSize), 5, 10000))
    let sweep = abs(num(edge["arcSweep"]))
    edge["arcSweep"] = jnum(clamp(if sweep == sweep and sweep != 0: sweep else: 360.0, 1, 360))
  else:
    let source = circular.source
    let target = circular.target
    let dx = target.x - source.x
    let dy = target.y - source.y
    let chord = hypot(dx, dy)
    if chord < 0.01: return
    let middle = pt((source.x + target.x) / 2, (source.y + target.y) / 2)
    let nx = -dy / chord
    let ny = dx / chord
    let signedSagitta = (world.x - middle.x) * nx + (world.y - middle.y) * ny
    edge["arcSide"] = jnum(if signedSagitta < 0: -1.0 else: 1.0)
    let sagitta = max(0.01, abs(signedSagitta))
    edge["arcSweep"] = jnum(clamp(4 * arctan(2 * sagitta / chord) * 180 / PI, 1, 180))
  edge["route"] = jnull
  g.action.moved = true
  g.reindex(edge)
  g.rendererUpsert([edge], true)
  g.updateWorldSize()
  g.render(true)

proc segmentAction(g: Graph, world: Pt, noSnap: bool) =
  let edge = g.byId.getOrDefault(g.action.itemId, nil)
  if edge == nil: return
  var points = g.action.originalPoints
  let index = g.action.segment
  let start = points[0]
  let finish = points[^1]
  let snapped = g.snapConnectorPoint(edge, world, noSnap)
  if g.action.orientation == "vertical":
    points[index].x = snapped.x
    points[index + 1].x = snapped.x
  else:
    points[index].y = snapped.y
    points[index + 1].y = snapped.y
  var interior = points[1 ..< points.len - 1]
  if interior.len > 0:
    let first = interior[0]
    if abs(start.x - first.x) > 0.01 and abs(start.y - first.y) > 0.01:
      interior.insert(if g.action.orientation == "horizontal": pt(start.x, first.y) else: pt(first.x, start.y), 0)
    let last = interior[^1]
    if abs(last.x - finish.x) > 0.01 and abs(last.y - finish.y) > 0.01:
      interior.add(if g.action.orientation == "horizontal": pt(finish.x, last.y) else: pt(last.x, finish.y))
  edge["route"] = ptsVal(interior)
  g.reindex(edge)
  g.rendererUpsert([edge], true)
  g.render(true)

# ------------------------------------------------------------ pointer --

proc pointerDown*(g: Graph, ev: PointerEv): int =
  let world = g.eventWorld(ev.screen)
  g.lastPointer = world
  if g.interactionLocked:
    if ev.button != 0 and ev.button != 1: return 0
    let m = viewMetrics()
    g.action = Action(kind: "pan", startScreen: ev.screen, scrollLeft: m.scrollLeft, scrollTop: m.scrollTop)
    return FlagCapture or FlagPrevent
  if ev.button == 1 or g.spacePressed:
    let m = viewMetrics()
    g.action = Action(kind: "pan", startScreen: ev.screen, scrollLeft: m.scrollLeft, scrollTop: m.scrollTop)
    return FlagCapture or FlagPrevent
  if ev.button != 0: return 0
  let foldingHit = g.hitTest(world)
  if foldingHit != nil and foldingHit.tr("collapsible") and g.hitFoldingBadge(world, foldingHit):
    g.action = Action(kind: "select")
    g.toggleFoldFor(foldingHit)
    return FlagCapture or FlagPrevent
  let hit = g.hitControl(world)
  let before = g.snapshot()
  let kind = if hit.found: hit.control.kind else: ""

  if kind == "port":
    g.action = Action(kind: "connect", sourceId: idOf(hit.item), sourceSide: hit.control.side,
      sourceAnchor: clone(if hit.control.anchorSpec != nil: hit.control.anchorSpec
                          else: anchorSpec(hit.control.side)),
      startWorld: world, hasStartWorld: true, current: world, moved: false,
      cloneTarget: ev.ctrl or ev.meta, before: before)
  elif kind == "edgeTerminal":
    g.action = Action(kind: "reconnect", itemId: idOf(hit.item), terminal: hit.control.terminal,
      startWorld: world, hasStartWorld: true, current: world, moved: false, before: before)
  elif kind == "resize":
    g.action = Action(kind: "resize", itemId: idOf(hit.item), handle: hit.control.index,
      original: clone(hit.item), startWorld: world, hasStartWorld: true, before: before)
  elif kind == "custom":
    g.action = Action(kind: "customHandle", itemId: idOf(hit.item), customType: hit.control.customType,
      original: clone(hit.item), before: before)
  elif kind == "tableColumnResize" or kind == "tableRowResize":
    g.action = Action(kind: "tableResize", itemId: idOf(hit.item),
      axis: if kind == "tableColumnResize": "column" else: "row", divider: hit.control.index,
      original: clone(hit.item), before: before)
  elif kind == "tableRowMove":
    g.action = Action(kind: "tableRowSwap", itemId: idOf(hit.item), sourceRow: hit.control.row,
      targetRow: hit.control.row, startWorld: world, hasStartWorld: true, current: world,
      moved: false, before: before)
  elif kind == "rotate":
    let center = nodeCenter(hit.item)
    g.action = Action(kind: "rotate", itemId: idOf(hit.item), center: center,
      originalRotation: rot(hit.item), startAngle: arctan2(world.y - center.y, world.x - center.x),
      moved: false, before: before)
  elif kind == "arcSweep" or kind == "circleRadius":
    g.action = Action(kind: "circularArc", itemId: idOf(hit.item), handleKind: kind,
                      before: before, moved: false)
  elif kind == "segment":
    g.action = Action(kind: "segment", itemId: idOf(hit.item), segment: hit.control.index,
      orientation: hit.control.orientation, originalPoints: hit.control.points, before: before)
  elif kind == "waypoint":
    if ev.alt:
      discard g.removeWaypoint(hit.item, hit.control.index)
      g.action = Action(kind: "select")
    else:
      g.action = Action(kind: "waypoint", itemId: idOf(hit.item), index: hit.control.index,
        originalRoute: clone(if hit.item["route"].isArr: hit.item["route"] else: newArr()),
        startWorld: world, hasStartWorld: true, moved: false, before: before)
  elif kind == "virtual":
    if ev.shift:
      g.action = Action(kind: "select")
    else:
      let routeBeforeInsert = clone(if hit.item["route"].isArr: hit.item["route"] else: newArr())
      let created = g.insertWaypointAt(hit.item, hit.control.index, world)
      g.action = Action(kind: "waypoint", itemId: idOf(hit.item), index: created,
        originalRoute: clone(if hit.item["route"].isArr: hit.item["route"] else: newArr()),
        routeBeforeInsert: routeBeforeInsert, hasRouteBeforeInsert: true,
        startWorld: world, hasStartWorld: true, moved: false, before: before)
      g.rendererUpsert([hit.item], true)
  elif kind == "groupResize":
    g.action = Action(kind: "groupResize", groupId: hit.group.id, handle: hit.control.index,
      frame: hit.frame, originals: g.cloneById(hit.group.items), before: before)
  elif kind == "groupRotate":
    let groupCenter = pt(hit.frame.x + hit.frame.width / 2, hit.frame.y + hit.frame.height / 2)
    g.action = Action(kind: "groupRotate", groupId: hit.group.id, center: groupCenter,
      originals: g.cloneById(hit.group.items),
      startAngle: arctan2(world.y - groupCenter.y, world.x - groupCenter.x), moved: false, before: before)
  else:
    let hitItem = g.hitTest(world)
    var cellHit = false
    var cellBox: CellBox
    if hitItem != nil and hitItem.eqs("shape", "table") and g.isSelected(idOf(hitItem)) and not ev.alt:
      (cellHit, cellBox) = g.tableCellAtWorld(hitItem, world)
    if cellHit:
      discard g.selectTableCellBox(hitItem, cellBox, ev.shift)
      g.action = Action(kind: "select")
    elif hitItem != nil:
      if g.tableSelection.active and g.tableSelection.nodeId == idOf(hitItem):
        discard g.clearTableCellSelection(false)
      let selectionHit = g.selectionCellForHit(hitItem, ev.alt)
      let selectionGroup = g.effectiveGroup(selectionHit)
      if ev.shift: g.toggleSelection(idOf(selectionHit))
      elif ev.alt: g.setSelection(@[idOf(selectionHit)], true)
      elif selectionGroup.len > 0:
        if not g.isSelected(idOf(selectionHit)):
          var ids: seq[string]
          for m in g.getGroupMembers(selectionGroup): ids.add idOf(m)
          g.setSelection(ids)
      elif not g.isSelected(idOf(selectionHit)): g.setSelection(@[idOf(selectionHit)])
      var movableGroup = false
      if selectionGroup.len > 0:
        for m in g.getGroupMembers(selectionGroup):
          if not m.tr("locked") and not m["movable"].isFalse:
            movableGroup = true
            break
      if selectionGroup.len > 0 and movableGroup:
        g.action = g.startMoveAction(world, before)
      elif selectionHit.eqs("type", "edge") and not selectionHit.tr("locked") and
          not selectionHit["movable"].isFalse:
        g.action = g.startEdgeMoveAction(selectionHit, world, before)
      elif not selectionHit.eqs("type", "edge") and not selectionHit.tr("locked") and
          not selectionHit["movable"].isFalse:
        g.action = g.startMoveAction(world, before)
      else:
        g.action = Action(kind: "select")
    else:
      var frameHit = false
      var frameGroup: GroupInfo
      if not ev.shift: (frameHit, frameGroup) = g.groupFrameAt(world)
      if frameHit:
        var frameIds: seq[string]
        var frameSelected = true
        for m in frameGroup.items:
          frameIds.add idOf(m)
          if not g.isSelected(idOf(m)): frameSelected = false
        if not frameSelected: g.setSelection(frameIds)
        g.action = g.startMoveAction(world, before)
      elif g.mobileMode and ev.touch:
        if not ev.shift: g.setSelection(@[])
        let m = viewMetrics()
        g.action = Action(kind: "pan", startScreen: ev.screen, scrollLeft: m.scrollLeft, scrollTop: m.scrollTop)
      else:
        if not ev.shift: g.setSelection(@[])
        g.action = Action(kind: "marquee", startWorld: world, hasStartWorld: true, current: world,
                          additive: ev.shift, originalSelection: g.selection)
  g.drawOverlay()
  FlagCapture or FlagPrevent

proc pointerLeave*(g: Graph) = g.hideTooltip()

proc pointerMove*(g: Graph, ev: PointerEv): int =
  let world = g.eventWorld(ev.screen)
  g.lastPointer = world
  if g.interactionLocked and g.action == nil:
    g.setCursor("grab")
    return 0
  if g.action == nil:
    let control = g.hitControl(world)
    let hit = if control.found: nil else: g.hitTest(world)
    let previousHover = g.hoverId
    g.hoverId = if control.found and control.item != nil: idOf(control.item)
                elif hit != nil: idOf(hit) else: ""
    var tableCellHover = false
    if hit != nil and hit.eqs("shape", "table") and g.isSelected(idOf(hit)):
      tableCellHover = g.tableCellAtWorld(hit, world)[0]
    var cursor: string
    if control.found: cursor = control.control.cursor
    elif hit != nil and hit.tr("collapsible") and g.hitFoldingBadge(world, hit): cursor = "pointer"
    elif g.getClickableLinkForCell(hit, ev.screen, ev.ctrl or ev.meta).len > 0: cursor = "pointer"
    elif tableCellHover: cursor = "text"
    elif hit != nil: cursor = if hit.eqs("type", "edge"): "pointer" else: "move"
    elif g.groupFrameAt(world)[0]: cursor = "move"
    else: cursor = "default"
    g.setCursor(cursor)
    g.updateTooltip(hit)
    if previousHover != g.hoverId: g.drawOverlay()
    return 0

  let action = g.action
  case action.kind
  of "pan":
    setScroll(action.scrollLeft - (ev.screen.x - action.startScreen.x),
              action.scrollTop - (ev.screen.y - action.startScreen.y))
  of "move":
    g.moveAction(world, ev.alt)
    g.updateDragAutoScroll(ev.screen, ev.alt)
  of "edgeMove": g.edgeMoveAction(world, ev.alt)
  of "resize": g.resizeAction(world, ev.alt)
  of "customHandle": g.customHandleAction(world, ev.alt)
  of "tableResize": g.tableResizeAction(world, ev.alt)
  of "tableRowSwap":
    action.current = world
    if hypot(world.x - action.startWorld.x, world.y - action.startWorld.y) > 3 / g.zoom: action.moved = true
    let swapTable = g.byId.getOrDefault(action.itemId, nil)
    let swapRow = g.tableRowAt(swapTable, world)
    if swapRow >= 0: action.targetRow = swapRow
    g.drawOverlay()
  of "groupResize": g.groupResizeAction(world, ev.alt)
  of "groupRotate": g.groupRotateAction(world, ev.shift, ev.alt)
  of "rotate": g.rotateAction(world, ev.shift, ev.alt)
  of "circularArc": g.circularArcAction(world, ev.alt)
  of "segment": g.segmentAction(world, ev.alt)
  of "waypoint":
    if not action.hasStartWorld or hypot(world.x - action.startWorld.x, world.y - action.startWorld.y) > 2 / g.zoom:
      action.moved = true
      g.waypointAction(world, ev.alt)
  of "connect", "reconnect":
    action.current = if ev.alt or not g.gridEnabled: world
                     else: pt(snap(world.x, g.gridSize), snap(world.y, g.gridSize))
    if action.hasStartWorld and hypot(world.x - action.startWorld.x, world.y - action.startWorld.y) > 4 / g.zoom:
      action.moved = true
    action.cloneTarget = action.cloneTarget or ev.ctrl or ev.meta
    let ignoreId = if action.kind == "connect" and not g.allowLoops: action.sourceId else: ""
    var referencePoint: Pt
    var referenceSide = ""
    var hasReference = false
    if action.kind == "connect":
      let connectionSource = g.byId.getOrDefault(action.sourceId, nil)
      if connectionSource != nil:
        referencePoint = nodeAnchor(connectionSource, action.sourceAnchor, action.sourceSide)
        referenceSide = action.sourceSide
        hasReference = true
    else:
      let reconnecting = g.byId.getOrDefault(action.itemId, nil)
      if reconnecting != nil:
        let pts = edgePoints(reconnecting, g.byId)
        if pts.len > 1:
          referencePoint = if action.terminal == "source": pts[^1] else: pts[0]
          hasReference = true
    let targetInfo = g.findConnectionTarget(world, ignoreId, referencePoint, referenceSide, hasReference)
    let namedSource = action.kind == "connect" and action.sourceAnchor != nil and
      action.sourceAnchor.eqs("portKind", "output")
    let namedTarget = targetInfo.anchor != nil and targetInfo.anchor.eqs("portKind", "input")
    if targetInfo.found and (not namedSource or namedTarget):
      action.targetId = idOf(targetInfo.node)
      action.targetSide = targetInfo.side
      action.targetAnchor = clone(targetInfo.anchor)
    else:
      action.targetId = ""
      action.targetSide = ""
      action.targetAnchor = nil
    g.drawOverlay()
  of "marquee":
    action.current = world
    g.drawOverlay()
  else: discard
  FlagPrevent

proc finishMarquee(g: Graph, action: Action) =
  let x = min(action.startWorld.x, action.current.x)
  let y = min(action.startWorld.y, action.current.y)
  let b = rect(x, y, abs(action.startWorld.x - action.current.x), abs(action.startWorld.y - action.current.y))
  var ids = if action.additive: action.originalSelection else: @[]
  for id in g.index.query(b):
    let item = g.byId.getOrDefault(id, nil)
    if item != nil and item.eqs("type", "edge"):
      var points: seq[Pt]
      if item.eqs("lineStyle", "circular"):
        let arc = circularArc(item, g.byId)
        points = if arc.valid: arc.samples else: edgePoints(item, g.byId)
      else: points = edgePoints(item, g.byId)
      var enclosed = points.len > 0
      for p in points:
        if not (p.x >= b.x and p.y >= b.y and p.x <= b.x + b.width and p.y <= b.y + b.height):
          enclosed = false
          break
      if enclosed and not ids.contains(idOf(item)): ids.add idOf(item)
    elif item != nil:
      let ib = itemBounds(item, g.byId)
      if ib.x >= b.x and ib.y >= b.y and ib.x + ib.width <= b.x + b.width and
          ib.y + ib.height <= b.y + b.height and not ids.contains(idOf(item)):
        ids.add idOf(item)
  g.setSelection(ids)

proc pointerUp*(g: Graph, ev: PointerEv): int =
  if g.action == nil: return 0
  g.stopDragAutoScroll()
  let action = g.action

  if action.kind == "select" or (action.kind == "move" and not action.moved):
    let linkHit = g.hitTest(g.eventWorld(ev.screen))
    let href = g.getClickableLinkForCell(linkHit, ev.screen, ev.ctrl or ev.meta)
    if href.len > 0:
      discard g.openLink(href)
      g.action = nil
      g.updateWorldSize()
      g.render()
      return FlagRelease or FlagPrevent

  case action.kind
  of "connect":
    if not action.moved:
      if action.sourceAnchor == nil or not action.sourceAnchor.eqs("portKind", "output"):
        discard g.connectVertex(g.byId.getOrDefault(action.sourceId, nil), action.sourceSide,
                                false, Pt(), action.before)
    elif action.targetId.len > 0:
      discard g.addEdge(obj(("sourceId", jstr(action.sourceId)), ("targetId", jstr(action.targetId)),
        ("sourceSide", jstr(action.sourceSide)),
        ("targetSide", if action.targetSide.len > 0: jstr(action.targetSide) else: jnull),
        ("sourceAnchor", clone(action.sourceAnchor)), ("targetAnchor", clone(action.targetAnchor))), false)
      g.setSelection(@[action.targetId])
      g.commit(action.before, "Connect")
    elif action.cloneTarget:
      discard g.connectVertex(g.byId.getOrDefault(action.sourceId, nil), action.sourceSide,
                              true, action.current, action.before)
    else:
      let danglingTarget = pt(
        if ev.alt or not g.gridEnabled: action.current.x else: snap(action.current.x, g.gridSize),
        if ev.alt or not g.gridEnabled: action.current.y else: snap(action.current.y, g.gridSize))
      discard g.addEdge(obj(("sourceId", jstr(action.sourceId)), ("targetId", jnull),
        ("sourceSide", jstr(action.sourceSide)), ("sourceAnchor", clone(action.sourceAnchor)),
        ("targetPoint", ptVal(danglingTarget)), ("targetSide", jnull)), false)
      g.commit(action.before, "Connect")
  of "reconnect":
    if action.targetId.len > 0:
      let edge = g.byId.getOrDefault(action.itemId, nil)
      if edge != nil:
        g.unregisterEdge(edge)
        let side = if action.targetSide.len > 0: jstr(action.targetSide) else: jnull
        if action.terminal == "source":
          edge["sourceId"] = jstr(action.targetId)
          edge["sourceSide"] = side
          edge["sourceAnchor"] = clone(action.targetAnchor)
          edge.del("sourcePoint")
        else:
          edge["targetId"] = jstr(action.targetId)
          edge["targetSide"] = side
          edge["targetAnchor"] = clone(action.targetAnchor)
          edge.del("targetPoint")
        g.registerEdge(edge)
        g.reindex(edge)
        g.rendererRemove([idOf(edge)])
        g.rendererUpsert([edge])
        g.commit(action.before, "Reconnect Connector")
    elif action.moved:
      let edge = g.byId.getOrDefault(action.itemId, nil)
      if edge != nil:
        let freePoint = pt(
          if ev.alt or not g.gridEnabled: action.current.x else: snap(action.current.x, g.gridSize),
          if ev.alt or not g.gridEnabled: action.current.y else: snap(action.current.y, g.gridSize))
        g.unregisterEdge(edge)
        if action.terminal == "source":
          edge["sourceId"] = jnull
          edge["sourceAnchor"] = jnull
          edge["sourcePoint"] = ptVal(freePoint)
        else:
          edge["targetId"] = jnull
          edge["targetAnchor"] = jnull
          edge["targetPoint"] = ptVal(freePoint)
        g.registerEdge(edge)
        g.reindex(edge)
        g.rendererRemove([idOf(edge)])
        g.rendererUpsert([edge])
        g.setSelection(@[idOf(edge)])
        g.commit(action.before, "Disconnect Connector")
  of "move":
    if action.moved:
      g.finishContainment(action)
      g.commit(action.before, "Move")
  of "edgeMove":
    if action.moved:
      let moved = g.byId.getOrDefault(action.itemId, nil)
      if moved != nil:
        g.normalizeEdgeRoute(moved)
        g.reindex(moved)
        g.rendererUpsert([moved])
      g.commit(action.before, "Move Connector")
  of "tableRowSwap":
    if action.moved and action.targetRow != action.sourceRow:
      discard g.swapTableRows(g.byId.getOrDefault(action.itemId, nil), action.sourceRow,
                              action.targetRow, action.before)
  of "resize", "customHandle":
    let item = g.byId.getOrDefault(action.itemId, nil)
    if item != nil:
      var ids = @[idOf(item)]
      if item.tr("containerId"): ids.add str(item["containerId"])
      discard g.layoutStackContainers(ids)
      discard g.extendParentContainersOf(@[item])
    g.commit(action.before, if action.kind == "resize": "Resize" else: "Adjust Shape")
  of "tableResize":
    g.commit(action.before, if action.axis == "column": "Resize Table Column" else: "Resize Table Row")
  of "groupResize", "groupRotate":
    if action.kind == "groupRotate" and not action.moved: g.applyGroupRotation(90)
    var parents: seq[string]
    var members: seq[Val]
    for id in jsKeysOf(action.originals):
      let m = g.byId.getOrDefault(id, nil)
      if m == nil: continue
      members.add m
      if m.tr("containerId") and not parents.contains(str(m["containerId"])):
        parents.add str(m["containerId"])
    discard g.layoutStackContainers(parents)
    discard g.extendParentContainersOf(members)
    g.commit(action.before, if action.kind == "groupResize": "Resize Group" else: "Rotate Group")
  of "rotate":
    if not action.moved:
      let item = g.byId.getOrDefault(action.itemId, nil)
      if item != nil:
        item["rotation"] = jnum(jsMod(item.fo("rotation", 0) + 90, 360))
        g.reindexNodeAndEdges(item)
        g.rendererUpsert([item])
    g.commit(action.before, "Rotate")
  of "circularArc":
    let edge = g.byId.getOrDefault(action.itemId, nil)
    if edge != nil:
      discard g.normalizeCircularEdge(edge)
      g.reindex(edge)
      g.rendererUpsert([edge])
    if action.moved: g.commit(action.before, "Adjust Circular Connector")
  of "segment":
    let edge = g.byId.getOrDefault(action.itemId, nil)
    if edge != nil:
      g.normalizeEdgeRoute(edge)
      g.reindex(edge)
      g.rendererUpsert([edge])
    g.commit(action.before, "Route Connector")
  of "waypoint":
    let edited = g.byId.getOrDefault(action.itemId, nil)
    if not action.moved and edited != nil:
      let route = clone(if action.hasRouteBeforeInsert: action.routeBeforeInsert
                        elif action.originalRoute != nil: action.originalRoute else: newArr())
      edited["route"] = if route.len > 0: route else: jnull
      g.reindex(edited)
      g.rendererUpsert([edited])
      g.render()
    else:
      if edited != nil:
        g.normalizeEdgeRoute(edited)
        g.reindex(edited)
        g.rendererUpsert([edited])
      g.commit(action.before, "Move Waypoint")
  of "marquee": g.finishMarquee(action)
  else: discard

  g.action = nil
  g.updateWorldSize()
  g.render()
  FlagRelease or FlagPrevent

# ------------------------------------------------------------- links --

proc openLink*(g: Graph, href0: string): bool =
  let href = jsTrim(href0)
  if href.len == 0: return false
  if href.toLowerAscii().startsWith("javascript:"):
    g.toast("JavaScript links are not allowed")
    return false
  if g.hooks.openLink != nil: g.hooks.openLink(href)
  true

# ------------------------------------------------------ text editing --

proc richBlockAt(g: Graph, node: Val, world: Pt): (bool, int, Rect) =
  if node == nil or not truthy(node["richText"]) or not node["richText"]["blocks"].isArr: return
  let local = rotatePoint(world, nodeCenter(node), -rot(node))
  if local.x < nodeX(node) or local.x > nodeX(node) + nodeW(node) or
      local.y < nodeY(node) or local.y > nodeY(node) + nodeH(node): return
  let base = obj(("fontSize", if truthy(node["fontSize"]): node["fontSize"] else: jnum(14)),
    ("fontFamily", if truthy(node["fontFamily"]): node["fontFamily"] else: jstr("Arial, sans-serif")),
    ("fontWeight", if node.tr("bold"): jnum(700) elif truthy(node["fontWeight"]): node["fontWeight"] else: jnum(500)),
    ("color", if truthy(node["textColor"]): node["textColor"] else: jstr("#172033")),
    ("align", if truthy(node["textAlign"]): node["textAlign"] else: jstr("center")),
    ("verticalAlign", if truthy(node["verticalAlign"]): node["verticalAlign"] else: jstr("middle")),
    ("wrap", jbool(not node["wordWrap"].isFalse)),
    ("padding", jnum(if node.nul("textPadding"): 9.0 else: jsMax(0, node.nor("textPadding", 0)))))
  let padding = num(base["padding"])
  let layout = richtext.layout(node["richText"], base,
    if base["wrap"].isTrue: max(10.0, nodeW(node) - padding * 2) else: 0.0)
  var y = nodeY(node) + (nodeH(node) - layout.height) / 2
  let vertical = str(base["verticalAlign"])
  if vertical == "top": y = nodeY(node) + padding
  if vertical == "bottom": y = nodeY(node) + nodeH(node) - layout.height - padding
  let blocks = node["richText"]["blocks"]
  var ranges: seq[(int, Rect)]
  for line in layout.lines:
    var index = -1
    for i, b in blocks.a:
      if b == line.blk:
        index = i
        break
    if index < 0:
      y += line.height
      continue
    if ranges.len > 0 and ranges[^1][0] == index: ranges[^1][1].height += line.height
    else: ranges.add (index, rect(nodeX(node), y, nodeW(node), line.height))
    y += line.height
  for (index, r) in ranges:
    if local.y >= r.y and local.y <= r.y + r.height: return (true, index, r)

proc taskRowAt(g: Graph, node: Val, world: Pt): (bool, int, Rect) =
  if node == nil or not node.eqs("kind", "taskList") or not node["tasks"].isArr or node["tasks"].len == 0:
    return
  let local = rotatePoint(world, nodeCenter(node), -rot(node))
  let headerHeight = node.fo("headerHeight", 28)
  if local.x < nodeX(node) or local.x > nodeX(node) + nodeW(node) or
      local.y < nodeY(node) + headerHeight or local.y > nodeY(node) + nodeH(node): return
  let count = node["tasks"].len
  let rowHeight = (nodeH(node) - headerHeight) / float64(count)
  let index = min(count - 1, int(floor((local.y - nodeY(node) - headerHeight) / rowHeight)))
  (true, index, rect(nodeX(node) + 22, nodeY(node) + headerHeight + float64(index) * rowHeight,
                     max(20.0, nodeW(node) - 28), rowHeight))


proc startTextEdit*(g: Graph, node: Val, scope: EditScope = EditScope()) =
  if node == nil or node.tr("locked"): return
  if g.textEditor.open: g.finishTextEdit(true)
  var bounds: Rect
  case scope.kind
  of "rich", "task", "cell", "title": bounds = scope.box
  else:
    if node.eqs("type", "edge"):
      let points = edgePoints(node, g.byId)
      let a = points[max(0, (points.len - 1) div 2)]
      let b = points[min(points.len - 1, (points.len - 1) div 2 + 1)]
      bounds = rect((a.x + b.x) / 2 - 70, (a.y + b.y) / 2 - 22, 140, 44)
    else:
      bounds = rect(nodeX(node), nodeY(node), nodeW(node), nodeH(node))

  let zoom = g.zoom
  var source: Val
  if scope.kind == "rich":
    let selectedBlock = clone(node["richText"]["blocks"][scope.index])
    selectedBlock.del("hidden")
    let selectedModel = obj(("blocks", newArr([selectedBlock])))
    source = obj(("text", jstr(toPlain(selectedModel))), ("richText", selectedModel))
  elif scope.kind == "task":
    let taskValue = node["tasks"][scope.index]
    source = if taskValue.isStr: obj(("text", taskValue))
             elif truthy(taskValue): taskValue else: obj(("text", jstr("")))
  elif scope.kind == "title":
    source = obj(("text", if truthy(node["tableTitle"]): node["tableTitle"] else: jstr("")))
  elif scope.kind == "cell":
    source = g.getCell(node, scope.row, scope.column)
  else:
    source = node
  let isCell = scope.kind == "cell" or scope.kind == "title"
  let vertical = if scope.kind.len > 0: "middle" else: node.so("verticalAlign", "middle")
  var align: string
  if scope.kind == "task": align = "left"
  elif isCell:
    align = if scope.kind == "title": "center"
            elif truthy(source["align"]): str(source["align"])
            elif truthy(node["cellAlign"]): str(node["cellAlign"])
            else: "center"
  else: align = node.so("textAlign", "center")
  let scoped = scope.kind.len > 0
  let editorWidth = if scoped: max(1.0, bounds.width * zoom) else: max(40.0, bounds.width * zoom)
  let editorHeight = if scoped: max(1.0, bounds.height * zoom) else: max(24.0, bounds.height * zoom)

  let model = if truthy(source["richText"]): source["richText"] else: nil
  let cellSource = scope.kind == "cell"
  let fontFamily = if cellSource and truthy(source["fontFamily"]): str(source["fontFamily"])
                   else: node.so("fontFamily", "Arial, sans-serif")
  let fontSizeV = if scope.kind == "task": 13.0
                  elif cellSource and truthy(source["fontSize"]): num(source["fontSize"])
                  else: node.fo("fontSize", 14)
  let fontWeight = if scope.kind == "title": jnum(700)
                   elif source.nul("fontWeight"):
                     (if node.tr("bold"): jnum(700) elif truthy(node["fontWeight"]): node["fontWeight"] else: jnum(500))
                   else: source["fontWeight"]
  let italic = source["italic"].isTrue or (node.tr("italic") and not isCell)
  let horizontalPadding = if scope.kind == "task": 0.0
                          elif isCell: 5.0
                          elif node.nul("textPadding"): 9.0
                          else: jsMax(0, node.nor("textPadding", 0))
  var decoration = ""
  if source["underline"].isTrue or (node.tr("underline") and not isCell): decoration.add "underline "
  if source["strikethrough"].isTrue or (node.tr("strikethrough") and not isCell): decoration.add "line-through"
  let description = obj(
    ("left", jnum((bounds.x + g.worldOriginX) * zoom)), ("top", jnum((bounds.y + g.worldOriginY) * zoom)),
    ("width", jnum(editorWidth)), ("height", jnum(editorHeight)),
    ("alignItems", jstr(if vertical == "top": "flex-start" elif vertical == "bottom": "flex-end" else: "center")),
    ("html", if model != nil: jstr(toHtml(model)) else: jnull),
    ("text", jstr(if model == nil: (if truthy(source["text"]): str(source["text"]) else: "") else: "")),
    ("fontFamily", jstr(fontFamily)), ("fontSize", jnum(max(8.0, fontSizeV))),
    ("fontWeight", fontWeight), ("fontStyle", jstr(if italic: "italic" else: "normal")),
    ("color", jstr(if truthy(source["textColor"]): str(source["textColor"]) else: node.so("textColor", "#172033"))),
    ("textAlign", jstr(align)), ("fieldWidth", jnum(max(1.0, bounds.width))),
    ("padding", jnum(horizontalPadding)), ("zoom", jnum(zoom)), ("textDecoration", jstr(decoration)),
    ("tabbable", jbool(scope.kind == "cell" or scope.kind == "task")))
  if rot(node) != 0:
    let c = nodeCenter(node)
    description["transformOrigin"] = jstr(jsNumStr((c.x - bounds.x) * zoom) & "px " & jsNumStr((c.y - bounds.y) * zoom) & "px")
    description["transform"] = jstr("rotate(" & str(node["rotation"]) & "deg)")

  g.textEditor = TextEditorState(open: true, node: node, taskIndex: -1, richBlockIndex: -1,
    before: g.snapshot(), originalText: source["text"],
    originalRich: if truthy(source["richText"]): clone(source["richText"]) else: nil)
  if isCell:
    g.textEditor.cell = if scope.kind == "title":
        obj(("tableTitle", jtrue), ("x", jnum(bounds.x)), ("y", jnum(bounds.y)),
            ("width", jnum(bounds.width)), ("height", jnum(bounds.height)))
      else:
        obj(("row", jnum(scope.row)), ("column", jnum(scope.column)), ("x", jnum(bounds.x)),
            ("y", jnum(bounds.y)), ("width", jnum(bounds.width)), ("height", jnum(bounds.height)))
    if scope.kind == "cell": g.textEditor.originalCell = clone(source)
    else: g.textEditor.originalTableTitle = node["tableTitle"]
  if scope.kind == "task":
    g.textEditor.taskIndex = scope.index
    g.textEditor.originalTask = clone(node["tasks"][scope.index])
  if scope.kind == "rich":
    g.textEditor.richBlockIndex = scope.index
    g.textEditor.originalNodeRich = clone(node["richText"])

  if scope.kind == "rich":
    node["richText"]["blocks"][scope.index]["hidden"] = jtrue
  elif scope.kind == "task":
    let tasks = node["tasks"]
    if tasks[scope.index].isStr: tasks.a[scope.index] = jstr("")
    else: tasks[scope.index]["text"] = jstr("")
  elif scope.kind == "title":
    node["tableTitle"] = jstr("")
  elif scope.kind == "cell":
    if nullish(node["cells"]): node["cells"] = newObj()
    node["cells"].remove($scope.row & "," & $scope.column)
  else:
    node["text"] = jstr("")
    node.del("richText")
  g.rendererUpsert([node], true)
  g.render(true)
  if g.hooks.textEditorOpen != nil: g.hooks.textEditorOpen(description)

proc editAdjacentTask(g: Graph, node: Val, index, direction: int) =
  let next = index + direction
  if node == nil or not node["tasks"].isArr or next < 0 or next >= node["tasks"].len: return
  let headerHeight = node.fo("headerHeight", 28)
  let rowHeight = (nodeH(node) - headerHeight) / float64(node["tasks"].len)
  g.startTextEdit(node, EditScope(kind: "task", index: next,
    box: rect(nodeX(node) + 22, nodeY(node) + headerHeight + float64(next) * rowHeight,
              max(20.0, nodeW(node) - 28), rowHeight)))

proc editAdjacentCell(g: Graph, node: Val, row, column, direction: int) =
  let columns = int(max(1.0, node.fo("columns", 3)))
  let rows = int(max(1.0, node.fo("rows", 3)))
  let index = row * columns + column + direction
  if index < 0 or index >= rows * columns: return
  let grid = tableGrid(node)
  let r = index div columns
  let c = index mod columns
  g.startTextEdit(node, EditScope(kind: "cell", row: r, column: c,
    box: rect(grid.columns[c].pos, grid.rows[r].pos, grid.columns[c].size, grid.rows[r].size)))

proc finishTextEdit*(g: Graph, commit: bool) =
  if not g.textEditor.open: return
  let data = g.textEditor
  g.textEditor = TextEditorState(taskIndex: -1, richBlockIndex: -1)
  # The page reads the editable field: its plain text and parsed rich model.
  var plain = ""
  var edited: Val = nil
  if g.hooks.textEditorClose != nil:
    (plain, edited) = g.hooks.textEditorClose()
  let node = data.node

  if data.richBlockIndex >= 0:
    let originalModel = clone(data.originalNodeRich)
    let nextModel = clone(data.originalNodeRich)
    if commit:
      var replacements: seq[Val]
      if truthy(edited):
        for b in edited["blocks"]:
          let c = clone(b)
          c.del("hidden")
          replacements.add c
      if replacements.len == 0:
        replacements.add obj(("type", jstr("p")), ("indent", jnum(0)), ("runs", newArr()))
      nextModel["blocks"].a.delete(data.richBlockIndex)
      for i, r in replacements: nextModel["blocks"].a.insert(r, data.richBlockIndex + i)
    for b in nextModel["blocks"]: b.del("hidden")
    node["richText"] = nextModel
    node["text"] = jstr(toPlain(nextModel))
    node["html"] = jstr(toHtml(nextModel))
    g.rendererUpsert([node])
    if commit and toJson(nextModel) != toJson(originalModel): g.commit(data.before, "Edit Rich Text")
    g.render()
    g.emit("texteditend")
    return

  var model: Val = nil
  if commit and data.taskIndex < 0 and truthy(edited) and not isPlain(edited): model = edited
  let contentText = if commit: jstr(plain) else: data.originalText
  let contentRich = if commit: model else: data.originalRich

  if data.taskIndex >= 0:
    if not node["tasks"].isArr: node["tasks"] = newArr()
    if commit:
      let updated = if data.originalTask.isObj: clone(data.originalTask) else: newObj()
      updated["text"] = contentText
      node["tasks"][data.taskIndex] = updated
    else:
      node["tasks"][data.taskIndex] = clone(data.originalTask)
  elif data.cell != nil and data.cell["tableTitle"].isTrue:
    node["tableTitle"] = if commit: contentText else: data.originalTableTitle
  elif data.cell != nil:
    if nullish(node["cells"]): node["cells"] = newObj()
    let key = str(data.cell["row"]) & "," & str(data.cell["column"])
    let updated = clone(if truthy(data.originalCell): data.originalCell else: newObj())
    updated["text"] = contentText
    updated.del("html")
    if truthy(contentRich): updated["richText"] = contentRich
    else: updated.del("richText")
    var authored = false
    for k in updated.keys():
      if k notin ["text", "richText", "html"]:
        authored = true
        break
    if (nullish(contentText) or isStrVal(contentText, "")) and nullish(contentRich) and not authored:
      node["cells"].remove(key)
    else:
      node["cells"].put(key, updated)
  else:
    node["text"] = contentText
    if truthy(contentRich): node["richText"] = contentRich
    else: node.del("richText")

  g.rendererUpsert([node])
  let changed = not strictEq(contentText, data.originalText) or
    toJson(if contentRich == nil: jnull else: contentRich) !=
      toJson(if data.originalRich == nil: jnull else: data.originalRich)
  if commit and changed:
    g.commit(data.before, if data.taskIndex >= 0: "Edit Task"
                          elif data.cell != nil: "Edit Cell" else: "Edit Text")
  g.render()
  g.emit("texteditend")

proc textEditorTab*(g: Graph, backwards: bool) =
  ## Tab walks to the next table cell or task row.
  if not g.textEditor.open: return
  let current = g.textEditor
  g.finishTextEdit(true)
  if current.cell != nil and not current.cell["tableTitle"].isTrue:
    g.editAdjacentCell(current.node, int(num(current.cell["row"])), int(num(current.cell["column"])),
                       if backwards: -1 else: 1)
  elif current.taskIndex >= 0:
    g.editAdjacentTask(current.node, current.taskIndex, if backwards: -1 else: 1)

proc isEditingText*(g: Graph): bool = g.textEditor.open

proc doubleClick*(g: Graph, ev: PointerEv): int =
  let world = g.eventWorld(ev.screen)
  let control = g.hitControl(world)
  if control.found and control.item != nil and control.item.eqs("type", "edge") and
      control.control.kind == "waypoint":
    discard g.removeWaypoint(control.item, control.control.index)
    return FlagPrevent
  let hit = g.hitTest(world)
  if hit == nil: return 0
  if hit.eqs("kind", "visualScript"):
    # Script blocks are edited in the inspector, not inline.
    g.setSelection(@[idOf(hit)])
    g.emit("scriptblockopen", obj(("id", jstr(idOf(hit)))))
    return FlagPrevent
  if hit.eqs("kind", "taskList"):
    let (ok, index, box) = g.taskRowAt(hit, world)
    if ok:
      g.startTextEdit(hit, EditScope(kind: "task", index: index, box: box))
      return FlagPrevent
  if hit.eqs("shape", "table"):
    let (ok, cell) = g.tableCellAtWorld(hit, world)
    if ok:
      discard g.selectTableCellBox(hit, cell)
      g.startTextEdit(hit, EditScope(kind: "cell", row: cell.row, column: cell.column,
                                     box: rect(cell.x, cell.y, cell.width, cell.height)))
      return 0
    let grid = tableGrid(hit)
    if not hit.nul("tableTitle") and world.y >= nodeY(hit) and world.y <= nodeY(hit) + grid.titleHeight:
      g.startTextEdit(hit, EditScope(kind: "title",
                                     box: rect(nodeX(hit), nodeY(hit), nodeW(hit), grid.titleHeight)))
      return 0
  if not nullish(hit["richText"]):
    let (ok, index, box) = g.richBlockAt(hit, world)
    if ok:
      g.startTextEdit(hit, EditScope(kind: "rich", index: index, box: box))
      return FlagPrevent
  g.startTextEdit(hit)
  0

proc startTextEditSelected*(g: Graph) =
  ## Enter/F2 on a single selection.
  let sel = g.getSelectedTableCell()
  let selected = g.getSelection()
  if sel.found:
    g.startTextEdit(sel.node, EditScope(kind: "cell", row: sel.row, column: sel.column,
                                        box: rect(sel.x, sel.y, sel.width, sel.height)))
  elif selected.len > 0 and not selected[0].eqs("type", "edge"):
    g.startTextEdit(selected[0])

# ------------------------------------------------------- context menu --

proc contextMenu*(g: Graph, ev: PointerEv): Val =
  let world = g.eventWorld(ev.screen)
  let hit = g.hitTest(world)
  var cellHit = false
  var cell: CellBox
  if hit != nil and hit.eqs("shape", "table"): (cellHit, cell) = g.tableCellAtWorld(hit, world)
  let sel = g.getSelectedTableCell()
  let keepRange = sel.found and sel.node == hit and cellHit and cell.row >= sel.startRow and
    cell.row <= sel.endRow and cell.column >= sel.startColumn and cell.column <= sel.endColumn
  if cellHit and not keepRange: discard g.selectTableCellBox(hit, cell)
  elif hit != nil and not g.isSelected(idOf(hit)): g.setSelection(@[idOf(hit)])
  obj(("item", if hit == nil: jnull else: hit),
      ("point", obj(("screen", ptVal(ev.screen)), ("world", ptVal(world)))))

# --------------------------------------------------------- drag & drop --

proc replaceTargetAt(g: Graph, world: Pt): ReplaceTarget =
  let hit = g.hitTest(world)
  if hit == nil or hit.tr("locked") or g.isLayerLocked(hit): return
  var center: Pt
  if hit.eqs("type", "edge"):
    let points = edgePoints(hit, g.byId)
    if points.len == 0: return
    let middle = float64(points.len - 1) / 2
    let low = points[int(floor(middle))]
    let high = points[int(ceil(middle))]
    center = pt((low.x + high.x) / 2, (low.y + high.y) / 2)
  else:
    center = nodeCenter(hit)
  ReplaceTarget(active: true, id: idOf(hit), center: center, radius: 13 / g.zoom, hot: false)

proc dragOver*(g: Graph, screen: Pt, isShapeDrag: bool) =
  var target: ReplaceTarget
  if isShapeDrag:
    let world = g.eventWorld(screen)
    target = g.replaceTargetAt(world)
    if target.active:
      target.hot = hypot(world.x - target.center.x, world.y - target.center.y) <= target.radius
  let previous = g.replaceTarget
  let changed = previous.active != target.active or (previous.active and target.active and
    (previous.id != target.id or previous.hot != target.hot))
  g.replaceTarget = target
  if changed: g.drawOverlay()

proc clearReplaceTarget*(g: Graph) =
  if not g.replaceTarget.active: return
  g.replaceTarget = ReplaceTarget()
  g.drawOverlay()

proc drop*(g: Graph, screen: Pt, templ: Val): Val =
  ## A palette/scratchpad shape dropped at `screen` (files are handled by the
  ## page, which then calls insertImage).
  let replaceNode = if g.replaceTarget.active and g.replaceTarget.hot:
                      g.byId.getOrDefault(g.replaceTarget.id, nil) else: nil
  g.clearReplaceTarget()
  let point = g.eventWorld(screen)
  let before = g.snapshot()
  let data = clone(if truthy(templ): templ else: newObj())
  if replaceNode != nil:
    let replaced = g.replaceShape(@[replaceNode], data)
    if replaced.len > 0:
      g.setSelection(@[idOf(replaceNode)])
      return replaceNode
  let node = g.addTemplate(data, obj(("x", jnum(point.x - data.fo("width", 160) / 2)),
                                     ("y", jnum(point.y - data.fo("height", 80) / 2))), true)
  var moved = initHashSet[string]()
  moved.incl idOf(node)
  let dropTarget = g.findContainerTarget(@[idOf(node)], moved, true, point)
  if dropTarget != nil:
    node["containerId"] = dropTarget["id"]
    dropTarget["container"] = jtrue
    g.rendererUpsert([node, dropTarget])
    discard g.layoutStackContainers(@[idOf(dropTarget)])
    discard g.extendParentContainersOf(@[node])
    g.updateWorldSize()
    g.render()
  g.commit(before, "Add Shape")
  node

# ----------------------------------------------------------- keyboard --

proc keyDown*(g: Graph, key, code: string, shift, ctrl, meta, alt: bool): int =
  ## Returns FlagPrevent when the key was handled; "externalpaste" is raised
  ## as an event for the page.
  let mods = ctrl or meta
  let lower = key.toLowerAscii()
  if code == "Space":
    g.spacePressed = true
    g.setCursor("grab")
    return 0
  if key == "Delete" or key == "Backspace":
    g.removeSelection()
    return FlagPrevent
  if mods and lower == "z":
    if shift: g.redo() else: g.undo()
    return FlagPrevent
  if mods and lower == "y":
    g.redo()
    return FlagPrevent
  if mods and lower == "c":
    g.copy()
    return FlagPrevent
  if mods and lower == "x":
    g.cut()
    return FlagPrevent
  if mods and not shift and not alt and lower == "v":
    if g.clipboard.len > 0 or g.tableCellClipboard != nil: g.paste()
    else: g.emit("externalpaste", newObj())
    return FlagPrevent
  if mods and lower == "d":
    g.duplicate()
    return FlagPrevent
  if mods and lower == "a":
    g.selectByType("", true)
    return FlagPrevent
  if key in ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"]:
    let sel = g.getSelectedTableCell()
    if sel.found:
      var nextRow = sel.row + (if key == "ArrowUp": -1 elif key == "ArrowDown": 1 else: 0)
      var nextColumn = sel.column + (if key == "ArrowLeft": -1 elif key == "ArrowRight": 1 else: 0)
      nextRow = max(0, min(nextRow, max(0, int(sel.node.nm("rows")) - 1)))
      nextColumn = max(0, min(nextColumn, max(0, int(sel.node.nm("columns")) - 1)))
      discard g.selectTableCell(sel.node, nextRow, nextColumn, 1, 1)
    else:
      let amount = if shift: g.gridSize else: 1.0
      g.nudgeSelection(if key == "ArrowLeft": -amount elif key == "ArrowRight": amount else: 0.0,
                       if key == "ArrowUp": -amount elif key == "ArrowDown": amount else: 0.0)
    return FlagPrevent
  if (key == "Enter" or key == "F2") and g.getSelection().len == 1:
    g.startTextEditSelected()
    return FlagPrevent
  if key == "Escape":
    if g.clearTableCellSelection(): discard
    elif g.enteredGroups.len > 0: g.exitGroup()
    else: g.setSelection(@[])
    return FlagPrevent
  0

proc keyUp*(g: Graph, code: string) =
  if code == "Space":
    g.spacePressed = false
    g.setCursor("default")
