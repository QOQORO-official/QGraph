## Frame presentation (CanvasRenderer).
##
## The scene is painted by a pool of render workers, each holding its own
## copy of the scene (another instance of this module) and painting one band
## of the viewport in parallel, or on the main thread while a
## gesture runs: the realtime painter shares the editor's scene, so it needs
## no copy at all. Finished frames reach the visible canvas through a WebGL
## (or Canvas2D) presenter, without any per-object DOM.

import std/[sets, strutils, math]
import ../jsval, ../host, ../painter, ../geometry, ../graph, ../canvas
import ../web/qweb
import media, wire

type
  Surface* = object
    ## A canvas the painter replays into, with its current backing size.
    canvas*, ctx*: Node
    width*, height*: int

  Band = object
    top, rows, margin: int    ## device rows it owns, and the overlap above them
    width, height: int
    bitmap: Node

  Renderer* = ref object
    canvas: Node
    presenter: Node
    backend: string
    painter*: ScenePainter          ## the realtime painter (shares the scene)
    realtime: Surface
    fallback: Surface
    pool: seq[int32]
    readyCount: int
    bands: seq[Band]
    bandsArrived: int
    bandStats: Val
    frameView: Val
    composite: Surface
    compositeCtx: Ctx
    workerMode*, ready*, destroyed*: bool
    inFlight, queued: bool
    realtimeActive*: bool
    frameId: int
    latestView*: Val
    realtimeFrame, fallbackFrame: int32
    interactiveDpr: float64
    pendingUpserts: seq[string]
    pendingSet: HashSet[string]
    parallaxTarget: Pt
    animating*, parallaxAnimating*: bool
    pendingStencils: Val
    onStats*: proc(stats: Val)
    itemsJson*: proc(ids: seq[string], all: bool): string

proc newSurface*(canvas: Node = nilNode): Surface =
  let c = if canvas.isNil: createElement("canvas") else: canvas
  Surface(canvas: c, ctx: c.context2d(alpha = false, desynchronized = true))

proc statsVal(s: RenderStats): Val =
  result = newObj()
  result["visible"] = jnum(s.visible)
  result["total"] = jnum(s.total)
  result["pixelWidth"] = jnum(s.pixelWidth)
  result["pixelHeight"] = jnum(s.pixelHeight)

proc paint*(p: ScenePainter, surface: var Surface, view: Val): Val =
  ## ScenePainter.render: advance parallax, record the frame, size the
  ## canvas to it and replay the commands.
  playback.parallaxFrameTime = perfNow()
  if p.hasLayeredItems: discard playback.advanceParallax(playback.parallaxFrameTime)
  let stats = p.render(view)
  if surface.width != stats.pixelWidth:
    surface.canvas.setProp("width", stats.pixelWidth)
    surface.width = stats.pixelWidth
  if surface.height != stats.pixelHeight:
    surface.canvas.setProp("height", stats.pixelHeight)
    surface.height = stats.pixelHeight
  replay(surface.ctx, addr p.ctx.buf)
  statsVal(stats)

proc roundMs(started: float64): float64 = jsRound((perfNow() - started) * 100) / 100

proc requestedCanvas2d(): bool =
  ## ?renderer=canvas2d forces the Canvas2D presenter.
  let search = location.getStr("search").toLowerAscii()
  let i = search.find("renderer=")
  if i < 0: return false
  var e = search.find('&', i)
  if e < 0: e = search.len
  search[i + 9 ..< e] == "canvas2d"

proc queryInt(name: string, fallback: int): int =
  let search = location.getStr("search")
  let i = search.find(name & "=")
  if i < 0: return fallback
  var e = search.find('&', i)
  if e < 0: e = search.len
  let n = hostParseNum(search[i + name.len + 1 ..< e])
  if n != n or n < 1: fallback else: int(n)

# -------------------------------------------------------------- worker pool --
#
# Full-resolution frames are painted by a pool of render workers, one per
# spare core. Each holds a copy of the scene and paints one horizontal band
# of the viewport, so a heavy frame is rasterised on every core at once; the
# bands are stitched on the page (or presented directly with one worker).

proc sendFrame(r: Renderer)
proc requestFrame*(r: Renderer, view: Val, realtime = false)

proc broadcast(r: Renderer, header: Val, payload = "") =
  for w in r.pool: send(w, header, payload)

proc useFallback(r: Renderer) =
  r.pool.setLen(0)
  r.workerMode = false
  r.ready = true
  if r.fallback.canvas.isNil: r.fallback = newSurface()
  if r.latestView != nil: r.requestFrame(r.latestView)

proc present(r: Renderer, source: Node) =
  if not r.destroyed: present(r.presenter, source)

proc closeBitmap(bitmap: Node) =
  if not bitmap.isNil:
    bitmap.call("close")
    release(bitmap)

proc dropBands(r: Renderer) =
  for b in r.bands.mitems:
    closeBitmap(b.bitmap)
    b.bitmap = nilNode
  r.bandsArrived = 0

proc finishFrame(r: Renderer) =
  ## Every band of the current frame is in: stitch and present it.
  var source: Node
  if r.bands.len == 1:
    source = r.bands[0].bitmap
  else:
    let width = r.bands[0].width
    var height = 0
    for b in r.bands: height += b.rows
    if r.composite.canvas.isNil: r.composite = newSurface()
    if r.composite.width != width:
      r.composite.canvas.setProp("width", width)
      r.composite.width = width
    if r.composite.height != height:
      r.composite.canvas.setProp("height", height)
      r.composite.height = height
    let ctx = r.compositeCtx
    ctx.reset()
    for b in r.bands:
      if not b.bitmap.isNil:
        # Bands overlap by a few rows so strokes crossing a seam are painted
        # whole by both; only the owned rows are copied.
        ctx.drawImage(b.bitmap.id, 0, float64(b.margin), float64(b.width), float64(b.rows),
                      0, float64(b.top), float64(b.width), float64(b.rows))
    ctx.finish()
    replay(r.composite.ctx, addr ctx.buf)
    source = r.composite.canvas
  r.present(source)
  let stats = r.bandStats
  stats["visible"] = jnum(r.painter.getVisibleItems(r.frameView).len)
  stats["backend"] = jstr(r.backend)
  stats["worker"] = jtrue
  stats["bands"] = jnum(r.bands.len)
  r.dropBands()
  if r.onStats != nil: r.onStats(stats)

proc onFrame(r: Renderer, header: Val, handles: seq[Node]) =
  let bitmap = if handles.len > 0: handles[0] else: nilNode
  let frameId = int(num(header["frameId"]))
  let band = int(num(header["band"]))
  if frameId != r.frameId or band < 0 or band >= r.bands.len:
    closeBitmap(bitmap)
    return
  let stats = header["stats"]
  r.bands[band].bitmap = bitmap
  r.bands[band].width = int(num(stats["pixelWidth"]))
  r.bands[band].height = int(num(stats["pixelHeight"]))
  if band == 0:
    r.bandStats = stats
    if r.bands.len > 1: stats["pixelHeight"] = jnum(r.bands[0].rows)
  else:
    r.bandStats["pixelHeight"] = jnum(num(r.bandStats["pixelHeight"]) + float64(r.bands[band].rows))
    r.bandStats["renderMs"] = jnum(max(num(r.bandStats["renderMs"]), num(stats["renderMs"])))
  inc r.bandsArrived
  if r.bandsArrived < r.bands.len: return
  r.inFlight = false
  # A worker frame can be a pointer event or more behind: while a gesture
  # runs the realtime painter owns the screen, and a queued newer view makes
  # this frame stale.
  if r.realtimeActive or r.queued:
    r.dropBands()
    if not r.realtimeActive and r.queued and r.latestView != nil:
      r.queued = false
      r.sendFrame()
    elif r.realtimeActive:
      r.queued = false
    return
  r.finishFrame()
  if r.queued and r.latestView != nil:
    r.queued = false
    r.sendFrame()

proc onWorker(r: Renderer, worker: int32, header: Val, payload: string, handles: seq[Node]) =
  case str(header["type"])
  of "ready":
    if r.pendingStencils != nil: send(worker, typeMsg("stencils"), toJson(r.pendingStencils))
    send(worker, typeMsg("sync"), r.itemsJson(@[], true))
    let p = typeMsg("parallax")
    p["x"] = jnum(r.parallaxTarget.x)
    p["y"] = jnum(r.parallaxTarget.y)
    send(worker, p)
    inc r.readyCount
    if r.readyCount == r.pool.len:
      r.ready = true
      r.pendingUpserts.setLen(0)
      r.pendingSet.clear()
      if r.latestView != nil: r.requestFrame(r.latestView)
  of "failed":
    r.useFallback()
  of "invalidate":
    # A worker decoded an image after the frame that asked for it.
    if r.latestView != nil and not r.realtimeActive: r.requestFrame(r.latestView)
  of "frame":
    r.onFrame(header, handles)
  else: discard

proc newRenderer*(canvas: Node, painter: ScenePainter): Renderer =
  let r = Renderer(canvas: canvas, painter: painter, interactiveDpr: 1.25, compositeCtx: newCtx())
  r.presenter = newPresenter(canvas, requestedCanvas2d())
  r.backend = r.presenter.getStr("name")
  r.realtime = newSurface()
  # One band per spare core, at most four; ?bands=N overrides.
  let cores = hardwareConcurrency()
  let count = min(8, queryInt("bands", clamp(cores - 1, 1, 4)))
  let rr = r
  for i in 0 ..< count:
    var id: int32
    id = startWorker(WorkerRender,
      proc(header: Val, payload: string, handles: seq[Node]) = rr.onWorker(id, header, payload, handles),
      proc() = rr.useFallback())
    if id == 0: break
    r.pool.add id
  if r.pool.len > 0:
    r.workerMode = true
  else:
    r.useFallback()
  r

# ---------------------------------------------------------------- scene sync --

proc sendStencils*(r: Renderer, programs: Val) =
  ## Ships parsed stencil programs to the workers so they can draw them too.
  r.pendingStencils = programs
  if r.workerMode: r.broadcast(typeMsg("stencils"), toJson(programs))

proc setParallaxTarget*(r: Renderer, x, y: float64) =
  let cx = clamp(if x != x: 0.0 else: x, -1, 1)
  let cy = clamp(if y != y: 0.0 else: y, -1, 1)
  r.parallaxTarget = pt(cx, cy)
  playback.setParallaxTarget(cx, cy)
  if r.workerMode:
    let p = typeMsg("parallax")
    p["x"] = jnum(cx)
    p["y"] = jnum(cy)
    r.broadcast(p)

proc sync*(r: Renderer, mediaItems: Val) =
  ## The engine replaced its whole scene (load, undo).
  r.pendingUpserts.setLen(0)
  r.pendingSet.clear()
  playback.retainVideos(mediaItems)
  # Learn which sources animate without waiting for a main-thread draw; in
  # worker mode that draw may never come.
  playback.scanForAnimation(mediaItems)
  if r.workerMode: r.broadcast(typeMsg("sync"), r.itemsJson(@[], true))

proc upsert*(r: Renderer, ids: seq[string], deferWorker: bool, mediaItems: Val) =
  if mediaItems != nil and mediaItems.len > 0: playback.scanForAnimation(mediaItems)
  if r.workerMode:
    if deferWorker or r.realtimeActive:
      for id in ids:
        if id notin r.pendingSet:
          r.pendingSet.incl id
          r.pendingUpserts.add id
    else:
      r.broadcast(typeMsg("upsert"), r.itemsJson(ids, false))

proc remove*(r: Renderer, ids: seq[string], mediaItems: Val) =
  playback.retainVideos(mediaItems)
  for id in ids:
    if id in r.pendingSet:
      r.pendingSet.excl id
      let at = r.pendingUpserts.find(id)
      if at >= 0: r.pendingUpserts.delete(at)
  if r.workerMode:
    let msg = typeMsg("remove")
    msg["ids"] = idsVal(ids)
    r.broadcast(msg)

proc flushWorkerUpserts(r: Renderer) =
  if not r.workerMode or r.pendingUpserts.len == 0: return
  let ids = move(r.pendingUpserts)
  r.pendingUpserts = @[]
  r.pendingSet.clear()
  r.broadcast(typeMsg("upsert"), r.itemsJson(ids, false))

# ------------------------------------------------------------------- frames --

proc sendFrame(r: Renderer) =
  ## Splits the view into device-pixel bands, one per worker.
  if r.pool.len == 0 or r.latestView == nil: return
  let view = r.latestView
  r.inFlight = true
  inc r.frameId
  r.frameView = view
  let dpr = clamp(if truthy(view["dpr"]): num(view["dpr"]) else: 1.0, 1, 2)
  let totalRows = max(1, int(floor(num(view["height"]) * dpr)))
  let count = max(1, min(r.pool.len, totalRows))
  r.dropBands()
  r.bands.setLen(count)
  for k in 0 ..< count:
    let top = totalRows * k div count
    let bottom = totalRows * (k + 1) div count
    const overlap = 4
    let above = if k == 0: 0 else: overlap
    let below = if k == count - 1: 0 else: overlap
    r.bands[k] = Band(top: top, rows: bottom - top, margin: above)
    let band = if count == 1: view else: shallowCopy(view)
    if count > 1:
      # Half a row of slack so floor(height * dpr) lands on the band size.
      band["height"] = jnum((float64(bottom - top + above + below) + 0.5) / dpr)
      band["scrollY"] = jnum(num(view["scrollY"]) + float64(top - above) / dpr)
    let msg = typeMsg("render")
    msg["frameId"] = jnum(r.frameId)
    msg["band"] = jnum(k)
    msg["view"] = band
    send(r.pool[k], msg)

proc requestRealtimeFrame(r: Renderer) =
  if r.realtimeFrame != 0 or r.latestView == nil: return
  let rr = r
  r.realtimeFrame = requestAnimationFrame(proc(now: float64) =
    rr.realtimeFrame = 0
    if not rr.realtimeActive or rr.destroyed: return
    let started = perfNow()
    let latest = rr.latestView
    let view = shallowCopy(latest)
    let dpr = if truthy(latest["dpr"]): num(latest["dpr"]) else: 1.0
    # A slightly lower transient resolution keeps high-DPI interaction in
    # the frame budget; the worker replaces it with a full-DPI frame once
    # the gesture settles. GIF playback keeps full resolution.
    let frameDpr = if rr.animating and not rr.parallaxAnimating: dpr else: min(rr.interactiveDpr, dpr)
    view["dpr"] = jnum(frameDpr)
    view["overscan"] = jnum(20)
    let stats = rr.painter.paint(rr.realtime, view)
    let paintMs = perfNow() - started
    if paintMs > 14: rr.interactiveDpr = max(0.75, rr.interactiveDpr - 0.15)
    elif paintMs < 7: rr.interactiveDpr = min(1.25, rr.interactiveDpr + 0.05)
    if not rr.realtimeActive or rr.destroyed: return
    rr.present(rr.realtime.canvas)
    stats["backend"] = jstr(rr.backend)
    stats["worker"] = jfalse
    stats["realtime"] = jtrue
    stats["interactiveDpr"] = jnum(frameDpr)
    stats["renderMs"] = jnum(roundMs(started))
    if rr.onStats != nil: rr.onStats(stats))

proc requestFrame*(r: Renderer, view: Val, realtime = false) =
  r.latestView = view
  if not r.ready or r.destroyed: return
  if realtime:
    r.realtimeActive = true
    r.requestRealtimeFrame()
    return
  r.realtimeActive = false
  if r.realtimeFrame != 0:
    cancelAnimationFrame(r.realtimeFrame)
    r.realtimeFrame = 0
  if r.workerMode:
    r.flushWorkerUpserts()
    if r.inFlight: r.queued = true
    else: r.sendFrame()
  else:
    if r.fallbackFrame != 0: cancelAnimationFrame(r.fallbackFrame)
    let rr = r
    r.fallbackFrame = requestAnimationFrame(proc(now: float64) =
      rr.fallbackFrame = 0
      let started = perfNow()
      let stats = rr.painter.paint(rr.fallback, rr.latestView)
      rr.present(rr.fallback.canvas)
      stats["backend"] = jstr(rr.backend)
      stats["worker"] = jfalse
      stats["renderMs"] = jnum(roundMs(started))
      if rr.onStats != nil: rr.onStats(stats))

proc destroy*(r: Renderer) =
  r.destroyed = true
  if r.fallbackFrame != 0: cancelAnimationFrame(r.fallbackFrame)
  if r.realtimeFrame != 0: cancelAnimationFrame(r.realtimeFrame)
