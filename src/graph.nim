## Pixel-native diagram scene, interaction controller and retained model.
##
## A port of the canvas editor's Graph.js. The scene is a flat list of
## JSON items (nodes, edges, tables...) edited through selection, handles,
## connectors, groups, layers and containers, with JSON snapshot undo. The
## DOM around it -- the scrolling container, the two canvases, the label
## editor, tooltips -- belongs to the page (web/js/Graph.js), which forwards
## pointer and keyboard input here and performs the host calls made from here.

import std/[tables, sets, math, algorithm, strutils]
import jsval, host, geometry, spatial, canvas, painter, richtext

type
  GroupInfo* = object
    id*: string
    items*: seq[Val]
    bounds*: Rect

  Handle* = object
    ## A selection/connection control (the `control` objects of Graph.js).
    kind*: string
    index*: int
    point*: Pt
    cursor*: string
    side*: string
    anchorSpec*: Val
    anchor*: Pt
    center*: Pt
    customType*: string
    fromP*, toP*: Pt
    row*: int
    terminal*: string
    orientation*: string
    points*: seq[Pt]
    virtual*: bool

  HitControl* = object
    found*: bool
    item*: Val
    group*: GroupInfo
    hasGroup*: bool
    frame*: Rect
    control*: Handle

  AnchorInfo* = object
    found*: bool
    node*: Val
    anchor*: Val          ## normalised {x, y, side}
    side*: string
    point*: Pt
    distance*: float64
    outlineDistance*: float64
    hasOutlineDistance*: bool
    snapped*: bool
    automaticMidpoint*: bool

  GroupConstraint = object
    groupId, parentId: string
    bounds: Rect
    rootIds: seq[string]

  ExplicitEdge = object
    edge: Val
    points: seq[Pt]

  Action* = ref object
    kind*: string
    startScreen*, startWorld*, current*: Pt
    hasStartWorld*: bool
    scrollLeft*, scrollTop*: float64
    sourceId*, sourceSide*: string
    sourceAnchor*: Val
    targetId*, targetSide*: string
    targetAnchor*: Val
    moved*, cloneTarget*: bool
    before*: string
    itemId*, terminal*: string
    handle*: int
    handleKind*: string
    original*: Val
    customType*, axis*: string
    divider*: int
    sourceRow*, targetRow*: int
    center*: Pt
    originalRotation*, startAngle*: float64
    segment*: int
    orientation*: string
    originalPoints*: seq[Pt]
    index*: int
    originalRoute*: Val
    routeBeforeInsert*: Val
    hasRouteBeforeInsert*: bool
    groupId*: string
    frame*: Rect
    originals*: OrderedTable[string, Val]
    additive*: bool
    originalSelection*: seq[string]
    originalEdges: OrderedTable[string, Val]
    explicitEdges: OrderedTable[string, ExplicitEdge]
    detachedExplicitEdges: HashSet[string]
    rootIds*: seq[string]
    dropTargetId*: string
    fixedContainerByRoot: Table[string, string]
    groupConstraints: seq[GroupConstraint]
    guideX*, guideY*: float64
    hasGuideX*, hasGuideY*: bool
    detached*, rendererDetached*: bool

  HistoryEntry = object
    data: string
    label: string

  TableSelection = object
    active: bool
    nodeId: string
    row, column, endRow, endColumn: int

  SelectedCell* = object
    found*: bool
    node*: Val
    row*, column*: int
    cell*: Val
    startRow*, endRow*, startColumn*, endColumn*: int
    x*, y*, width*, height*: float64

  ReplaceTarget = object
    active: bool           ## there is a target
    id: string
    center: Pt
    radius: float64
    hot: bool              ## the pointer is inside the badge

  TextEditorState = object
    open: bool
    node: Val
    cell: Val              ## {row, column, x, y, width, height} or {tableTitle...}
    taskIndex: int         ## -1 = none
    originalTask: Val
    richBlockIndex: int    ## -1 = none
    originalNodeRich: Val
    before: string
    originalText: Val
    originalCell: Val
    originalTableTitle: Val
    originalRich: Val

  GraphHooks* = object
    ## How the engine reaches the page. The application installs these; every
    ## one is optional.
    emit*: proc(name: string, data: Val)
    render*: proc(view: Val, realtime: bool)
    spacer*: proc(width, height: float64)
    rendererSync*: proc(media: Val)
    rendererUpsert*: proc(ids: seq[string], deferWorker: bool, media: Val)
    rendererRemove*: proc(ids: seq[string])
    overlay*: proc(ctx: Ctx)
    cursor*: proc(cursor: string)
    tooltip*: proc(show: bool, id, text: string)
    timer*: proc(name: string, ms: float64, cancel: bool)
    openLink*: proc(href: string)
    textEditorOpen*: proc(d: Val)
    textEditorClose*: proc(): (string, Val)

  Graph* = ref object
    items*: seq[Val]
    byId*: Scene
    edgesByNode: Table[string, seq[string]]
    index*: SpatialGrid
    selection*: seq[string]
    tableSelection: TableSelection
    enteredGroups*: seq[string]
    hoverId*: string
    action*: Action
    zoom*: float64
    gridSize*: float64
    gridEnabled*: bool
    gridColor*: string
    backgroundColor*: string
    pageView*: bool
    pageWidth*, pageHeight*, pageMargin*: float64
    pageColumns*, pageRows*, pageStartColumn*, pageStartRow*: float64
    infiniteWorldWidth*, infiniteWorldHeight*: float64
    worldOriginX*, worldOriginY*: float64
    connectionArrows*, connectionPoints*, allowLoops*: bool
    defaultEdgeLength*: float64
    guidesEnabled*: bool
    portMode*: string
    history: seq[HistoryEntry]
    future: seq[HistoryEntry]
    snapshotBlobIds: Table[string, string]
    snapshotBlobsById: Table[int, (Val, string)]
    snapshotBlobs: Table[string, Val]
    snapshotBlobCounter: int
    clipboard*: seq[Val]
    tableCellClipboard: Val
    styleClipboard*: Val
    sizeClipboard: Val
    defaultNodeStyle*: Val
    defaultEdgeStyle*: Val
    spacePressed*: bool
    lastPointer: Pt
    destroyed*: bool
    pageScale*: float64
    tooltipsEnabled*: bool
    layers*: Val
    activeLayer*: string
    mobileMode*: bool
    interactionLocked*: bool
    readOnly*: bool
    extra*: Val               ## any other property the page sets on the graph
    painter*: ScenePainter    ## the realtime painter (shares the scene)
    overlay*: Ctx
    replaceTarget: ReplaceTarget
    textEditor: TextEditorState
    dragAutoScroll: bool
    dragAutoScrollDx, dragAutoScrollDy: float64
    dragAutoScrollScreen: Pt
    dragAutoScrollNoSnap: bool
    dragAutoScrollTimer: bool
    cursor: string            ## last cursor sent to the overlay canvas
    hooks*: GraphHooks

# ---------------------------------------------------------------- helpers --

const
  RotationSnapTolerance = 4.0

var uidCounter = 0

proc toBase36(x: float64): string =
  var n = int64(abs(x))
  if n == 0: return "0"
  const digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  while n > 0:
    result.insert($digits[int(n mod 36)], 0)
    n = n div 36

proc uid(prefix: string): string =
  inc uidCounter
  (if prefix.len > 0: prefix else: "item") & "-" & toBase36(dateNow()) & "-" &
    toBase36(float64(uidCounter))

proc snap(value, size: float64): float64 {.inline.} = jsRound(value / size) * size

proc rotationSnapAngles(): seq[float64] =
  var d = 0
  while d < 360:
    if d mod 30 == 0 or d mod 45 == 0: result.add float64(d)
    d += 15

let ROTATION_SNAP_ANGLES = rotationSnapAngles()

proc jsMod(a, b: float64): float64 {.inline.} =
  ## The % operator (sign of the dividend).
  a - b * trunc(a / b)

proc snapRotation(degrees: float64, hardSnap, noSnap: bool): float64 =
  if hardSnap: return jsRound(degrees / 15) * 15
  if noSnap: return degrees
  let normalized = jsMod(jsMod(degrees, 360) + 360, 360)
  var best = NaN
  for a in ROTATION_SNAP_ANGLES:
    let delta = jsMod(a - normalized + 540, 360) - 180
    if abs(delta) <= RotationSnapTolerance and (best != best or abs(delta) < abs(best)):
      best = delta
  if best != best: degrees else: degrees + best

const
  SHAPE_KEEP_PLACEMENT = ["id", "type", "x", "y", "z", "width", "height",
    "rotation", "layer", "groups", "groupId", "containerId", "container",
    "part", "folded", "foldedAway", "foldedBy", "visible", "locked",
    "sourceId", "targetId", "sourceAnchor", "targetAnchor", "sourceSide",
    "targetSide", "sourcePoint", "targetPoint", "previewPoints", "route"]
  SHAPE_KEEP_STYLE = ["fill", "gradient", "gradientDirection", "stroke",
    "strokeWidth", "opacity", "dashed", "dashPattern", "shadow", "glass",
    "fontFamily", "fontSize", "fontWeight", "fontStyle", "textColor",
    "textAlign", "verticalAlign", "strikethrough", "wordWrap"]
  SHAPE_KEEP_EDGE_STYLE = ["arrowSize"]
  SHAPE_KEEP_CONTENT = ["text", "html", "richText", "link", "tooltip",
    "cscript", "bookmark"]

proc normalizeHtml(item: Val): Val =
  ## HTML blocks keep their source; the painter needs the rich model too.
  if item == nil or item.nul("html"): return item
  if item.nul("richText"):
    item["richText"] = fromHtml(str(item["html"]))
  item

proc normalizeGroups(item: Val): Val =
  ## A group is a path of ids on every member, outermost first.
  if not item["groups"].isArr:
    let g = newArr()
    if item.tr("groupId"): g.push item["groupId"]
    item["groups"] = g
  let filtered = newArr()
  for id in item["groups"]:
    if id.isStr and id.s != "": filtered.push id
  item["groups"] = filtered
  if filtered.len > 0:
    item["groupId"] = filtered[0]
  else:
    item.del("groups")
    item.del("groupId")
  item

type SegHit = object
  point: Pt
  t: float64
  distance: float64

proc closestPointOnSegment(p, a, b: Pt): SegHit =
  let dx = b.x - a.x
  let dy = b.y - a.y
  let lengthSq = dx * dx + dy * dy
  let t = if lengthSq == 0: 0.0 else: clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq, 0, 1)
  let closest = pt(a.x + t * dx, a.y + t * dy)
  SegHit(point: closest, t: t, distance: hypot(p.x - closest.x, p.y - closest.y))

proc distanceToSegment(p, a, b: Pt): float64 = closestPointOnSegment(p, a, b).distance

proc pointInPolygon(p: Pt, points: openArray[Pt]): bool =
  var inside = false
  var j = points.len - 1
  for i in 0 ..< points.len:
    let a = points[i]
    let b = points[j]
    let d = b.y - a.y
    if ((a.y > p.y) != (b.y > p.y)) and
        p.x < (b.x - a.x) * (p.y - a.y) / (if d == 0: 0.0001 else: d) + a.x:
      inside = not inside
    j = i
  inside

proc isArrayIndexKey(k: string): bool =
  ## Canonical array-index strings, which JavaScript orders first in objects.
  if k.len == 0 or k.len > 10: return false
  if k.len > 1 and k[0] == '0': return false
  for c in k:
    if c notin {'0'..'9'}: return false
  parseBiggestInt(k) < 4294967295

proc jsKeys(keys: seq[string]): seq[string] =
  ## Object.keys order for keys inserted in `keys` order.
  var ints: seq[(int64, string)]
  for k in keys:
    if isArrayIndexKey(k): ints.add (parseBiggestInt(k).int64, k)
  if ints.len == 0: return keys
  ints.sort(proc (a, b: (int64, string)): int = cmp(a[0], b[0]))
  for x in ints: result.add x[1]
  for k in keys:
    if not isArrayIndexKey(k): result.add k

proc jsKeysOf[T](t: OrderedTable[string, T]): seq[string] =
  var ks: seq[string]
  for k in t.keys: ks.add k
  jsKeys(ks)

proc idsVal*(ids: openArray[string]): Val =
  result = newArr()
  for id in ids: result.push jstr(id)

proc itemsVal*(items: openArray[Val]): Val =
  result = newArr()
  for it in items: result.push it

proc strOrEmpty*(v: Val): string =
  if nullish(v): "" else: str(v)

proc anchorSpec(side: string): Val =
  result = newObj()
  result["x"] = jnum(if side == "west": 0.0 elif side == "east": 1.0 else: 0.5)
  result["y"] = jnum(if side == "north": 0.0 elif side == "south": 1.0 else: 0.5)
  result["side"] = jstr(side)

proc obj*(pairs: varargs[(string, Val)]): Val =
  result = newObj()
  for (k, v) in pairs: result.put(k, v)

type CellTarget = object
  found: bool
  nodeId: string
  row, column: int

type DirectionalTarget = object
  found: bool
  node: Val
  anchor: AnchorInfo
  score, z: float64

type
  PointerEv* = object
    screen*: Pt
    button*: int
    shift*, ctrl*, meta*, alt*: bool
    touch*: bool

const
  FlagPrevent* = 1
  FlagCapture* = 2
  FlagRelease* = 4

type EditScope = object
  kind: string          ## "", "cell", "title", "task", "rich"
  row, column, index: int
  box: Rect

# ------------------------------------------------------------- includes --

include graph_decls
include graph_model
include graph_hit
include graph_overlay
include graph_input
include graph_rpc
