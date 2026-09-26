## Pictures, animated GIFs and video in the scene.
##
## - Media classification (MP4/WebM, YouTube, images) and URL parsing.
## - The image cache: <img> elements on the page, ImageBitmaps in a worker.
## - Animation sniffing (multi-frame GIF, APNG, animated WebP).
## - GIF playback: frames are decoded by the Nim GIF decoder in a worker and
##   uploaded into a small canvas the painter samples.
## - Video playback: parked <video> elements, sampled into the canvas in
##   z-order.
## - drawImageNode: the painter's media hook -- fit, alignment, opacity,
##   tiling and the pointer-parallax layer stacks.

import std/[tables, sets, strutils, math]
import ../jsval, ../canvas, ../host, ../geometry, ../painter
import ../web/qweb
import jsutil, gif, wire

# ------------------------------------------------------------ classification --

proc youtubeId*(src: string): string =
  let url = parseAbsoluteUrl(src)
  if not url.ok: return ""
  var host = url.host
  if host.startsWith("www."): host = host[4 .. ^1]
  var id = ""
  if host == "youtu.be":
    for part in url.pathname.split('/'):
      if part.len > 0:
        id = part
        break
  elif host in ["youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com"]:
    if url.pathname == "/watch":
      id = searchParam(url.search, "v")[1]
    else:
      let lower = url.pathname.toLowerAscii()
      for prefix in ["/embed/", "/shorts/", "/live/"]:
        if lower.startsWith(prefix):
          let rest = url.pathname[prefix.len .. ^1]
          var e = 0
          while e < rest.len and rest[e] notin {'/', '?', '#'}: inc e
          if e > 0: id = rest[0 ..< e]
          break
  if id.len < 6 or id.len > 15: return ""
  for c in id:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}: return ""
  id

proc youtubeStart*(src: string): int =
  let url = parseAbsoluteUrl(src)
  if not url.ok: return 0
  var value = searchParam(url.search, "start")[1]
  if value.len == 0: value = searchParam(url.search, "t")[1]
  if value.len == 0:
    let h = if url.hash.startsWith("#"): url.hash[1 .. ^1] else: url.hash
    value = searchParam(h, "t")[1]
  var plain = value.len > 0
  var dots = 0
  for c in value:
    if c == '.': inc dots
    elif c notin {'0'..'9'}: plain = false
  if plain and dots <= 1 and value[0] != '.' and value[^1] != '.':
    return max(0, int(floor(jsNumber(value))))
  var total = 0.0
  var i = 0
  let lower = value.toLowerAscii()
  while i < lower.len:
    if lower[i] in {'0'..'9'}:
      var j = i
      while j < lower.len and lower[j] in {'0'..'9'}: inc j
      if j + 1 < lower.len and lower[j] == '.' and lower[j + 1] in {'0'..'9'}:
        inc j
        while j < lower.len and lower[j] in {'0'..'9'}: inc j
      if j < lower.len and lower[j] in {'h', 'm', 's'}:
        let n = jsNumber(lower[i ..< j])
        total += n * (if lower[j] == 'h': 3600.0 elif lower[j] == 'm': 60.0 else: 1.0)
        i = j + 1
        continue
      i = j
    else: inc i
  max(0, int(floor(total)))

proc endsWithExt(value, ext: string): bool =
  ## /\.ext(?:[?#]|$)/i
  let lower = value.toLowerAscii()
  var i = lower.find(ext)
  while i >= 0:
    let e = i + ext.len
    if e == lower.len or lower[e] in {'?', '#'}: return true
    i = lower.find(ext, i + 1)
  false

proc mediaTypeFor*(src, explicitType: string): string =
  let t = explicitType.toLowerAscii()
  if t.startsWith("image/") or t == "image": return ""
  if t == "video/youtube": return "video/youtube"
  if t.startsWith("video/mp4") or t.startsWith("video/webm"): return t
  let head = src[0 ..< min(src.len, 128)]
  let lh = head.toLowerAscii()
  if lh.startsWith("data:video/mp4"): return "video/mp4"
  if lh.startsWith("data:video/webm"): return "video/webm"
  if lh.startsWith("data:"): return ""
  if youtubeId(src).len > 0: return "video/youtube"
  if endsWithExt(src, ".webm"): return "video/webm"
  if endsWithExt(src, ".mp4"): return "video/mp4"
  if t.startsWith("video/"): t else: ""

var mainRealm* = true
  ## False inside a worker, where only the plain MP4/WebM tests apply.

proc isVideoSource*(src, mediaType: string): bool =
  if mainRealm: return mediaTypeFor(src, mediaType).len > 0
  if mediaType.toLowerAscii().startsWith("video/"): return true
  let head = src[0 ..< min(src.len, 128)]
  head.toLowerAscii().startsWith("data:video/") or endsWithExt(head, ".mp4") or endsWithExt(head, ".webm")

proc isYouTube*(src: string): bool = mainRealm and youtubeId(src).len > 0

proc sv(v: Val): string = (if v != nil and v.kind == vStr: v.s else: "")

# ---------------------------------------------------------------- state --

type
  Bitmap* = object
    handle*: int32
    width*, height*: float64

  ImageState = object
    state: int              ## 0 loading, 1 ready, -1 failed
    bitmap: Bitmap

  GifPlayer = ref object
    id, src: string
    canvas, context: Node
    ready, waiting: bool
    dueAt, delay: float64
    frames: int
    width, height: float64

  VideoPlayer* = ref object
    src*, kind*: string
    video*: Node
    ready*, failed*: bool
    objectUrl: string
    width, height: float64

  Media* = ref object
    images: Table[string, ImageState]
    elements: Table[string, Node]
    animated*: HashSet[string]
    videoSources: HashSet[string]
    checkedAnimation: HashSet[string]
    gifPlayers: Table[string, GifPlayer]
    gifById: Table[string, GifPlayer]
    gifWorker: int32
    gifFailed: bool
    gifNextId: int
    videos: Table[string, VideoPlayer]
    parallax*, parallaxTarget*: Pt
    parallaxLastTime*: float64
    parallaxFrameTime*: float64
    onImageLoad*: proc(src: string)
    onGifFrame*: proc(src: string)
    onVideoFrame*: proc(src: string)
    holder, animationHolder: Node

var playback* = Media()

# ---------------------------------------------------------------- images --

proc parkedHolder(id: string, css: string): Node =
  let existing = document.invoke("getElementById", id).toNode
  if not existing.isNil: return existing
  result = createElement("div")
  result.setAttribute("id", id)
  result.setAttribute("aria-hidden", "true")
  result.cssText = css
  body.appendChild(result)

proc markAnimated(m: Media, src: string)

proc ensureElement(m: Media, src: string): Node =
  if m.elements.hasKey(src): return m.elements[src]
  let image = createElement("img")
  m.elements[src] = image
  image.on("load", proc(e: Event) =
    let w = image.getNum("naturalWidth")
    let h = image.getNum("naturalHeight")
    m.images[src] = ImageState(state: 1, bitmap: Bitmap(handle: image.id, width: w, height: h))
    if m.onImageLoad != nil: m.onImageLoad(src))
  image.on("error", proc(e: Event) =
    m.images[src] = ImageState(state: -1))
  if not src.startsWith("data:"): image.setProp("crossOrigin", "anonymous")
  image.setProp("src", src)
  image

proc scanBase64Gif(m: Media, src: string, bodyStart: int) =
  ## Looks for a second frame marker in slices, yielding between them, so a
  ## multi-megabyte embedded GIF never blocks the page.
  const chunk = 64 * 1024
  const cap = 24 * 1024 * 1024
  var offset = bodyStart
  var frames = 0
  var carry = ""
  proc step() {.closure.}
  proc step() =
    if offset >= src.len or offset - bodyStart > cap: return
    let e = min(src.len, offset + chunk)
    let bytes = base64Decode(src, offset, e)
    offset = e
    let window = carry & bytes[0 ..< min(2, bytes.len)]
    for w in 0 ..< max(0, window.len - 2):
      if window[w] == '\x21' and window[w + 1] == '\xF9' and window[w + 2] == '\x04': inc frames
    for b in 0 ..< max(0, bytes.len - 2):
      if bytes[b] == '\x21' and bytes[b + 1] == '\xF9' and bytes[b + 2] == '\x04':
        inc frames
        if frames > 1:
          m.markAnimated(src)
          return
    carry = if bytes.len >= 2: bytes[^2 .. ^1] else: bytes
    if frames > 1:
      m.markAnimated(src)
      return
    setTimeout(0, step)
  step()

proc markVideo(m: Media, src, mediaType: string, loop: bool)

proc detectAnimation*(m: Media, src: string) =
  if src.len == 0 or src in m.checkedAnimation: return
  m.checkedAnimation.incl src
  if isVideoSource(src, ""):
    if not isYouTube(src): m.markVideo(src, mediaTypeFor(src, ""), true)
    return
  if src.toLowerAscii().startsWith("data:"):
    let comma = src.find(',')
    let meta = if comma < 0: "" else: src[0 ..< comma].toLowerAscii()
    if meta.contains(";base64") and meta.contains("gif") and src.len - comma - 1 > 512 * 1024:
      m.scanBase64Gif(src, comma + 1)
      return
    let (ok, _, bytes) = decodeDataUri(src)
    if ok and bytesAreAnimated(bytes): m.markAnimated(src)
    return
  fetchBytes(src, proc(ok: bool, data: string) =
    if ok:
      if bytesAreAnimated(data): m.markAnimated(src)
    elif endsWithExt(src, ".gif"): m.markAnimated(src), preferCache = true)

proc resolveImage*(m: Media, src: string): ImageState =
  if src.len == 0: return ImageState(state: -1)
  if m.images.hasKey(src): return m.images[src]
  m.images[src] = ImageState(state: 0)
  m.detectAnimation(src)
  if mainRealm:
    discard m.ensureElement(src)
  else:
    fetchBlob(src, proc(ok: bool, blob: Node) =
      if not ok:
        m.images[src] = ImageState(state: -1)
        return
      imageBitmap(blob, proc(ok: bool, bitmap: Node) =
        release(blob)
        if not ok:
          m.images[src] = ImageState(state: -1)
          return
        m.images[src] = ImageState(state: 1, bitmap: Bitmap(handle: bitmap.id,
          width: bitmap.getNum("width"), height: bitmap.getNum("height")))
        if m.onImageLoad != nil: m.onImageLoad(src)))
  m.images[src]

proc imageLoaded*(m: Media, src: string): bool =
  m.images.hasKey(src) and m.images[src].state == 1

proc imageKnown*(m: Media, src: string): bool = m.images.hasKey(src)

proc isAnimated*(m: Media, src: string): bool = src in m.animated

# ------------------------------------------------------------ GIF playback --

var encodeCallbacks = initTable[string, proc(ok: bool, dataUrl: string)]()
var encodeSerial = 0

proc onGifMessage(m: Media, header: Val, payload: string) =
  let pendingEncode = encodeCallbacks.getOrDefault(sv(header["id"]), nil)
  if pendingEncode != nil:
    encodeCallbacks.del(sv(header["id"]))
    pendingEncode(sv(header["type"]) == "encoded", payload)
    return
  let player = m.gifById.getOrDefault(sv(header["id"]), nil)
  if player == nil: return
  let kind = sv(header["type"])
  if kind == "failed":
    m.gifPlayers.del(player.src)
    m.gifById.del(player.id)
    return
  if kind == "loaded":
    player.frames = int(num(header["frames"]))
    player.width = num(header["width"])
    player.height = num(header["height"])
    player.canvas = createElement("canvas")
    player.canvas.setProp("width", player.width)
    player.canvas.setProp("height", player.height)
    player.context = player.canvas.context2d()
    player.waiting = true
    send(m.gifWorker, obj2s("type", "next", "id", player.id))
    return
  if kind == "frame":
    if not player.context.isNil:
      player.context.putRgba(payload.toOpenArrayByte(0, payload.len - 1),
                             int(num(header["width"])), int(num(header["height"])))
    player.delay = num(header["delay"])
    player.dueAt = perfNow() + player.delay
    player.ready = true
    player.waiting = false
    if m.onGifFrame != nil: m.onGifFrame(player.src)

proc ensureGifWorker(m: Media): int32 =
  if m.gifWorker != 0 or m.gifFailed: return m.gifWorker
  let mm = m
  m.gifWorker = startWorker(WorkerGif,
    proc(header: Val, payload: string, handles: seq[Node]) = mm.onGifMessage(header, payload),
    proc() = mm.gifFailed = true)
  if m.gifWorker == 0: m.gifFailed = true
  m.gifWorker

proc encodeFile*(m: Media, file: Node, cb: proc(ok: bool, dataUrl: string)) =
  ## A picked file as a data URI, base64-encoded in the media worker so a
  ## large video never stalls the page; FileReader when no worker runs.
  if m.ensureGifWorker() == 0:
    readBlob(file, brDataUrl, cb)
    return
  inc encodeSerial
  let id = "encode-" & $encodeSerial
  encodeCallbacks[id] = cb
  send(m.gifWorker, obj2s("type", "encode", "id", id), "", [file])

proc addGif(m: Media, src: string): GifPlayer =
  if m.gifPlayers.hasKey(src): return m.gifPlayers[src]
  if m.ensureGifWorker() == 0: return nil
  inc m.gifNextId
  let player = GifPlayer(id: "gif-" & $m.gifNextId, src: src, waiting: true, delay: 100)
  m.gifPlayers[src] = player
  m.gifById[player.id] = player
  send(m.gifWorker, obj2s("type", "load", "id", player.id), src)
  player

proc gifFrame(m: Media, src: string): (bool, Bitmap) =
  let player = m.gifPlayers.getOrDefault(src, nil)
  if player == nil or not player.ready: return (false, Bitmap())
  (true, Bitmap(handle: player.canvas.id, width: player.width, height: player.height))

proc hasGifPlayers*(m: Media): bool = m.gifPlayers.len > 0

proc tickGifs*(m: Media, now: float64): bool =
  ## Requests the next frame for every player whose delay has elapsed.
  if m.gifPlayers.len == 0: return false
  for player in m.gifPlayers.values:
    result = true
    if player.waiting or m.gifWorker == 0: continue
    if player.frames <= 1: continue
    if now < player.dueAt: continue
    player.waiting = true
    send(m.gifWorker, obj2s("type", "next", "id", player.id))

proc removeGif*(m: Media, src: string) =
  let player = m.gifPlayers.getOrDefault(src, nil)
  if player == nil: return
  m.gifPlayers.del(src)
  m.gifById.del(player.id)
  if m.gifWorker != 0: send(m.gifWorker, obj2s("type", "release", "id", player.id))

proc markAnimated(m: Media, src: string) =
  if src in m.animated: return
  m.animated.incl src
  if mainRealm:
    if m.addGif(src) == nil:
      # No decoder: park the element so the browser at least animates it.
      let element = m.ensureElement(src)
      if m.animationHolder.isNil:
        m.animationHolder = parkedHolder("pixel-animation-holder",
          "position:absolute;width:0;height:0;overflow:hidden;opacity:0;pointer-events:none;left:-9999px;top:0;")
      element.cssText = "position:absolute;width:1px;height:1px;"
      m.animationHolder.appendChild(element)
  if m.onImageLoad != nil: m.onImageLoad(src)

# ----------------------------------------------------------- video playback --

proc wakeVideo(m: Media, player: VideoPlayer) =
  let v = player.video
  player.ready = v.getNum("readyState") >= 2 and v.getNum("videoWidth") > 0
  if player.ready:
    player.width = v.getNum("videoWidth")
    player.height = v.getNum("videoHeight")
    v.call("play")
  if m.onVideoFrame != nil: m.onVideoFrame(player.src)

proc addVideo*(m: Media, src, explicitType: string, loop: bool): VideoPlayer =
  if not mainRealm or not isVideoSource(src, explicitType) or youtubeId(src).len > 0: return nil
  let existing = m.videos.getOrDefault(src, nil)
  if existing != nil:
    existing.video.setProp("loop", loop)
    return existing
  let video = createElement("video")
  let player = VideoPlayer(src: src, kind: mediaTypeFor(src, explicitType), video: video)
  m.videos[src] = player
  video.setProp("preload", "auto")
  video.setProp("muted", true)
  video.setProp("defaultMuted", true)
  video.setProp("loop", loop)
  video.setProp("autoplay", true)
  video.setProp("playsInline", true)
  video.setAttribute("playsinline", "")
  video.cssText = "position:absolute;width:1px;height:1px;"
  if m.holder.isNil:
    m.holder = parkedHolder("pixel-media-holder",
      "position:absolute;width:1px;height:1px;overflow:hidden;opacity:0;pointer-events:none;left:-9999px;top:0;")
  m.holder.appendChild(video)
  for name in ["loadedmetadata", "loadeddata", "canplay", "seeked"]:
    video.on(name, proc(e: Event) = m.wakeVideo(player))
  video.on("error", proc(e: Event) =
    player.failed = true
    if m.onVideoFrame != nil: m.onVideoFrame(src))
  proc assign(source: string) =
    video.setProp("src", source)
    video.call("load")
  if src.toLowerAscii().startsWith("data:"):
    # Decoded once here; the element then buffers a Blob instead of
    # re-parsing a multi-megabyte data URI.
    let (ok, mime, bytes) = decodeDataUri(src)
    if ok:
      let blob = newBlob(bytes, mime)
      player.objectUrl = createObjectURL(blob)
      release(blob)
      assign(player.objectUrl)
    else: assign(src)
  else:
    if not src.toLowerAscii().startsWith("blob:"): video.setProp("crossOrigin", "anonymous")
    assign(src)
  player

proc videoState*(m: Media, src: string): VideoPlayer = m.videos.getOrDefault(src, nil)

proc videoFrame*(m: Media, src, kind: string, loop: bool): (bool, Bitmap) =
  var player = m.videos.getOrDefault(src, nil)
  if player == nil: player = m.addVideo(src, kind, loop)
  if player == nil or not player.ready or player.failed: return (false, Bitmap())
  player.video.setProp("loop", loop)
  (true, Bitmap(handle: player.video.id, width: player.width, height: player.height))

proc removeVideo*(m: Media, src: string) =
  let player = m.videos.getOrDefault(src, nil)
  if player == nil: return
  m.videos.del(src)
  player.video.call("pause")
  player.video.removeAttribute("src")
  player.video.call("load")
  player.video.dropTree()
  if player.objectUrl.len > 0: revokeObjectURL(player.objectUrl)

proc retainVideos*(m: Media, items: Val) =
  var keep = initHashSet[string]()
  for item in items:
    if item == nil: continue
    let src = sv(item["src"])
    if src.len > 0 and isVideoSource(src, sv(item["mediaType"])): keep.incl src
    if item["mediaLayers"].isArr:
      for layer in item["mediaLayers"]:
        let ls = sv(layer["src"])
        if ls.len > 0 and isVideoSource(ls, sv(layer["mediaType"])): keep.incl ls
  var drop: seq[string]
  for src in m.videos.keys:
    if src notin keep and not src.toLowerAscii().startsWith("blob:"): drop.add src
  for src in drop: m.removeVideo(src)

proc markVideo(m: Media, src, mediaType: string, loop: bool) =
  if src.len == 0: return
  let first = src notin m.videoSources
  m.videoSources.incl src
  m.animated.incl src
  if mainRealm: discard m.addVideo(src, mediaType, loop)
  if first and m.onImageLoad != nil: m.onImageLoad(src)

# ------------------------------------------------------------- scanning --

var hasLayeredItems* = false

proc scanForAnimation*(m: Media, items: Val) =
  for item in items:
    if item == nil: continue
    let layered = item["mediaLayers"].isArr and item["mediaLayers"].len > 0
    if layered: hasLayeredItems = true
    let src = sv(item["src"])
    if src.len > 0:
      if isVideoSource(src, sv(item["mediaType"])):
        if not isYouTube(src): m.markVideo(src, sv(item["mediaType"]), not item["mediaLoop"].isFalse)
      else: m.detectAnimation(src)
    if layered:
      for layer in item["mediaLayers"]:
        let ls = sv(layer["src"])
        if ls.len == 0: continue
        if isVideoSource(ls, sv(layer["mediaType"])): m.markVideo(ls, sv(layer["mediaType"]), true)
        else: m.detectAnimation(ls)

# ------------------------------------------------------------- parallax --

proc setParallaxTarget*(m: Media, x, y: float64) =
  m.parallaxTarget = pt(clamp(if x != x: 0.0 else: x, -1, 1), clamp(if y != y: 0.0 else: y, -1, 1))

proc advanceParallax*(m: Media, now0: float64): bool =
  let dx = m.parallaxTarget.x - m.parallax.x
  let dy = m.parallaxTarget.y - m.parallax.y
  if abs(dx) <= 0.0005 and abs(dy) <= 0.0005:
    m.parallax = m.parallaxTarget
    m.parallaxLastTime = 0
    return false
  let now = if now0 == 0 or now0 != now0: perfNow() else: now0
  var dt = if m.parallaxLastTime > 0: now - m.parallaxLastTime else: 1000 / 60
  dt = clamp(dt, 4, 34)
  m.parallaxLastTime = now
  let amount = 1 - exp(-dt / 130)
  m.parallax.x += dx * amount
  m.parallax.y += dy * amount
  true

proc parallaxLoopNeeded(m: Media, item: Val): bool =
  let layers = item["mediaLayers"]
  if not layers.isArr or layers.len == 0: return false
  for layer in layers:
    if layer != nil and (jsNumOr(layer["scrollX"], 0) != 0 or jsNumOr(layer["scrollY"], 0) != 0): return true
  abs(m.parallaxTarget.x - m.parallax.x) > 0.001 or abs(m.parallaxTarget.y - m.parallax.y) > 0.001

type AnimationState* = object
  any*, parallax*, media*: bool

proc visibleAnimationState*(m: Media, painter: ScenePainter, view: Val): AnimationState =
  if m.animated.len == 0 and not hasLayeredItems and not painter.hasLayeredItems: return
  for item in painter.getVisibleItems(view):
    let src = sv(item["src"])
    if src.len > 0 and src in m.animated: result.media = true
    if src.len > 0 and mainRealm and isVideoSource(src, sv(item["mediaType"])):
      let player = m.videos.getOrDefault(src, nil)
      if player != nil and player.ready and not player.failed and
          not player.video.getBool("paused") and not player.video.getBool("ended"):
        result.parallax = true
    if item["mediaLayers"].isArr and item["mediaLayers"].len > 0:
      if m.parallaxLoopNeeded(item): result.parallax = true
      if src.len > 0 and isVideoSource(src, sv(item["mediaType"])): result.parallax = true
      for layer in item["mediaLayers"]:
        let ls = sv(layer["src"])
        if ls.len > 0 and ls in m.animated:
          result.media = true
          if isVideoSource(ls, sv(layer["mediaType"])): result.parallax = true
    if result.parallax and result.media: break
  result.any = result.parallax or result.media

# ----------------------------------------------------------------- drawing --

proc drawFittedBitmap(ctx: Ctx, bitmap: Bitmap, node: Val, fit0: string, opacity: Val,
                      offsetX, offsetY: float64) =
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  let naturalWidth = if bitmap.width > 0: bitmap.width else: w
  let naturalHeight = if bitmap.height > 0: bitmap.height else: h
  var fit = if fit0.len > 0: fit0 else: "contain"
  ctx.save()
  if opacity != nil and opacity.kind != vNull:
    ctx.globalAlpha = ctx.globalAlpha * clamp(num(opacity), 0, 1)
  if fit == "tile":
    ctx.fillPattern(bitmap.handle, 0)
    ctx.translate(x, y)
    ctx.fillRect(0, 0, w, h)
    ctx.restore()
    return
  var scale = NaN
  var stretch = false
  if fit == "stretch": stretch = true
  elif fit == "cover": scale = jsMax(w / naturalWidth, h / naturalHeight)
  elif fit == "none": scale = 1
  else: scale = jsMin(w / naturalWidth, h / naturalHeight)
  let width = if stretch: w else: naturalWidth * scale
  let height = if stretch: h else: naturalHeight * scale
  let imageAlign = sv(node["imageAlign"])
  let imageVAlign = sv(node["imageVerticalAlign"])
  let alignX = if imageAlign == "left": 0.0 elif imageAlign == "right": w - width else: (w - width) / 2
  let alignY = if imageVAlign == "top": 0.0 elif imageVAlign == "bottom": h - height else: (h - height) / 2
  if width > w or height > h:
    ctx.beginPath()
    ctx.rect(x, y, w, h)
    ctx.clip()
  ctx.drawImage(bitmap.handle, x + alignX + offsetX, y + alignY + offsetY, width, height)
  ctx.restore()

proc layerBitmap(m: Media, layer: Val): (bool, Bitmap) =
  let src = sv(layer["src"])
  if isVideoSource(src, sv(layer["mediaType"])):
    if not mainRealm: return (false, Bitmap())
    return m.videoFrame(src, sv(layer["mediaType"]), true)
  let (hasGif, frame) = m.gifFrame(src)
  if hasGif: return (true, frame)
  let state = m.resolveImage(src)
  (state.state == 1, state.bitmap)

proc drawMediaLayers(m: Media, ctx: Ctx, node: Val, layers: Val) =
  let now = if m.parallaxFrameTime != 0: m.parallaxFrameTime else: perfNow()
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  ctx.save()
  ctx.beginPath()
  ctx.rect(x, y, w, h)
  ctx.clip()
  for layer in layers:
    if layer == nil or not layer.isObj or sv(layer["src"]).len == 0: continue
    let (ok, bitmap) = m.layerBitmap(layer)
    if not ok: continue
    let depth = clamp(jsNumOr(layer["depth"], 0), 0, 1)
    let marginX = depth * w * 0.06
    let marginY = depth * h * 0.06
    let naturalWidth = if bitmap.width > 0: bitmap.width else: w
    let naturalHeight = if bitmap.height > 0: bitmap.height else: h
    let scale = jsMax((w + 2 * marginX) / naturalWidth, (h + 2 * marginY) / naturalHeight)
    let width = naturalWidth * scale
    let height = naturalHeight * scale
    let centerX = x + (w - width) / 2 - m.parallax.x * marginX
    let centerY = y + (h - height) / 2 - m.parallax.y * marginY
    ctx.save()
    let opacity = if nullish(layer["opacity"]): 1.0 else: jsNumOr(layer["opacity"], 0)
    ctx.globalAlpha = ctx.globalAlpha * clamp(opacity, 0, 1)
    let scrollX = jsNumOr(layer["scrollX"], 0)
    let scrollY = jsNumOr(layer["scrollY"], 0)
    if scrollX != 0 or scrollY != 0:
      let shiftX = if scrollX != 0: (now / 1000 * scrollX) mod width else: 0.0
      let shiftY = if scrollY != 0: (now / 1000 * scrollY) mod height else: 0.0
      for tx in -1 .. 1:
        for ty in -1 .. 1:
          let dx = centerX - shiftX + float64(tx) * width
          let dy = centerY - shiftY + float64(ty) * height
          if dx + width <= x or dx >= x + w or dy + height <= y or dy >= y + h: continue
          ctx.drawImage(bitmap.handle, dx, dy, width, height)
    else:
      ctx.drawImage(bitmap.handle, centerX, centerY, width, height)
    ctx.restore()
  ctx.restore()

proc drawImageNode*(ctx: Ctx, node: Val) =
  ## The painter's media hook (ScenePainter.drawImageNode).
  let m = playback
  let layers = if node["mediaLayers"].isArr and node["mediaLayers"].len > 0: node["mediaLayers"] else: nil
  let src = sv(node["src"])
  let mediaType = sv(node["mediaType"])
  let videoSource = isVideoSource(src, mediaType)
  if videoSource and layers == nil and isYouTube(src):
    ctx.save()
    ctx.fillStyle = "#111111"
    ctx.fillRect(nodeX(node), nodeY(node), nodeW(node), nodeH(node))
    ctx.restore()
    return
  var ok = false
  var bitmap: Bitmap
  var failed = false
  if videoSource and mainRealm:
    (ok, bitmap) = m.videoFrame(src, mediaType, not node["mediaLoop"].isFalse)
  if not ok and not videoSource:
    (ok, bitmap) = m.gifFrame(src)
  if not ok and not videoSource:
    let state = m.resolveImage(src)
    ok = state.state == 1
    bitmap = state.bitmap
    failed = state.state == -1
  if not ok:
    let x = nodeX(node)
    let y = nodeY(node)
    let w = nodeW(node)
    let h = nodeH(node)
    ctx.save()
    ctx.fillStyle = "#eef1f5"
    ctx.fillRect(x, y, w, h)
    ctx.strokeStyle = "#b6bec9"
    ctx.lineWidth = 1
    ctx.setLineDash([4.0, 3.0])
    ctx.strokeRect(x + 0.5, y + 0.5, w - 1, h - 1)
    ctx.setLineDash([])
    ctx.fillStyle = "#8a94a2"
    ctx.font = "11px Arial, sans-serif"
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    let player = if videoSource and mainRealm: m.videos.getOrDefault(src, nil) else: nil
    let unavailable = player != nil and player.failed
    ctx.fillText(if failed or unavailable: "Media unavailable" else: "Loading media…", x + w / 2, y + h / 2)
    ctx.restore()
    return
  drawFittedBitmap(ctx, bitmap, node, sv(node["imageFit"]), node["imageOpacity"], 0, 0)
  if layers != nil: m.drawMediaLayers(ctx, node, layers)

proc installMediaHook*() =
  painter.mediaHook = drawImageNode

proc imageState*(m: Media, src: string): int =
  ## 1 decoded, -1 failed, 0 loading or unknown.
  if m.images.hasKey(src): m.images[src].state else: 0

proc imageSize*(m: Media, src: string): (float64, float64) =
  if m.images.hasKey(src): (m.images[src].bitmap.width, m.images[src].bitmap.height)
  else: (0.0, 0.0)

proc videoSize*(p: VideoPlayer): (float64, float64) = (p.width, p.height)
