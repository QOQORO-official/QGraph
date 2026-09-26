## 256x256 world-space bucket index (PixelSpatialGrid).
##
## Query results keep the JavaScript Set/Map insertion order, because the
## editor derives selection order from them (marquee selection, the first
## object of a move, etc.).

import std/[tables, sets, math]
import geometry

type
  CellKey = (int32, int32)
  SpatialGrid* = object
    cellSize*: float64
    cells: Table[CellKey, seq[string]]
    itemKeys: Table[string, seq[CellKey]]

proc initSpatialGrid*(cellSize = 256.0): SpatialGrid =
  SpatialGrid(cellSize: cellSize)

proc clear*(g: var SpatialGrid) =
  g.cells.clear()
  g.itemKeys.clear()

proc keysForBounds(g: SpatialGrid, b: Rect): seq[CellKey] =
  let size = g.cellSize
  if b.x != b.x or b.y != b.y or b.width != b.width or b.height != b.height: return
  let minX = floor(b.x / size)
  let minY = floor(b.y / size)
  let maxX = floor((b.x + max(0.0, b.width)) / size)
  let maxY = floor((b.y + max(0.0, b.height)) / size)
  # A runaway item (huge coordinates) must not allocate millions of buckets.
  if (maxX - minX + 1) * (maxY - minY + 1) > 1_000_000: return
  var y = minY
  while y <= maxY:
    var x = minX
    while x <= maxX:
      result.add (int32(x), int32(y))
      x += 1
    y += 1

proc remove*(g: var SpatialGrid, id: string) =
  if not g.itemKeys.hasKey(id): return
  let keys = g.itemKeys[id]
  for k in keys:
    g.cells.withValue(k, bucket):
      let i = bucket[].find(id)
      if i >= 0: bucket[].delete(i)
      if bucket[].len == 0: g.cells.del(k)
  g.itemKeys.del(id)

proc update*(g: var SpatialGrid, id: string, bounds: Rect) =
  g.remove(id)
  let keys = g.keysForBounds(bounds)
  g.itemKeys[id] = keys
  for k in keys:
    g.cells.mgetOrPut(k, @[]).add id

proc query*(g: SpatialGrid, bounds: Rect): seq[string] =
  let keys = g.keysForBounds(bounds)
  var seen = initHashSet[string]()
  for k in keys:
    if g.cells.hasKey(k):
      for id in g.cells[k]:
        if not seen.containsOrIncl(id): result.add id
