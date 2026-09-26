## Worker entry points. Every worker runs this same module; the page picks
## the role when it spawns one:
##
## * WorkerRender -- an OffscreenCanvas scene painter with its own copy of the
##   scene, so full-resolution frames never block the editor's thread.
## * WorkerGif -- GIF decoding (LZW and frame compositing) one frame at a
##   time, and base64 encoding of files picked for embedding.

import std/[tables, strutils]
import ../jsval, ../host, ../painter, ../stencils, ../geometry
import ../web/qweb
import jsutil, gif, media, wire, stencilxml, richhtml

# ------------------------------------------------------------------ render --

type Surface2 = object
  canvas, ctx: Node
  width, height: int

var scenePainter: ScenePainter
var surface: Surface2

proc toItems(payload: string): seq[Val] =
  try:
    let v = parseJson(payload)
    for item in v: result.add item
  except JsonError: discard

proc renderMessage(header: Val, payload: string) =
  case str(header["type"])
  of "sync": scenePainter.sync(toItems(payload))
  of "upsert": scenePainter.upsert(toItems(payload))
  of "remove": scenePainter.remove(toStrSeq(header["ids"]))
  of "parallax":
    # Worker frames are the settled state: realtime easing happens on the
    # page while the pointer moves.
    playback.setParallaxTarget(num(header["x"]), num(header["y"]))
    playback.parallax = playback.parallaxTarget
  of "stencils":
    try: registerPrograms(parseJson(payload))
    except JsonError: discard
  of "render":
    let view = header["view"]
    let started = perfNow()
    playback.parallaxFrameTime = started
    let stats = scenePainter.render(view)
    if surface.width != stats.pixelWidth:
      surface.canvas.setProp("width", stats.pixelWidth)
      surface.width = stats.pixelWidth
    if surface.height != stats.pixelHeight:
      surface.canvas.setProp("height", stats.pixelHeight)
      surface.height = stats.pixelHeight
    replay(surface.ctx, addr scenePainter.ctx.buf)
    let bitmap = surface.canvas.invoke("transferToImageBitmap").toNode
    let s = newObj()
    s["visible"] = jnum(stats.visible)
    s["total"] = jnum(stats.total)
    s["pixelWidth"] = jnum(stats.pixelWidth)
    s["pixelHeight"] = jnum(stats.pixelHeight)
    s["renderMs"] = jnum(jsRound((perfNow() - started) * 100) / 100)
    let msg = typeMsg("frame")
    msg["frameId"] = header["frameId"]
    msg["band"] = header["band"]
    msg["stats"] = s
    send(0, msg, "", [bitmap])
    release(bitmap)
  else: discard

proc startRenderWorker() =
  mainRealm = false
  installMediaHook()
  installRichHtml()
  scenePainter = newScenePainter()
  let canvas = construct("OffscreenCanvas", 1, 1)
  surface = Surface2(canvas: canvas, ctx: canvas.context2d(alpha = false, desynchronized = true))
  # An image decodes after the frame that requested it: ask for a redraw.
  playback.onImageLoad = proc(src: string) = send(0, typeMsg("invalidate"))
  onPageMessage(proc(header: Val, payload: string, handles: seq[Node]) =
    renderMessage(header, payload))
  send(0, typeMsg("ready"))

# --------------------------------------------------------------------- gif --

var sequences = initTable[string, GifSequence]()

proc reply(kind, id: string): Val =
  result = typeMsg(kind)
  result["id"] = jstr(id)

proc loadGif(id, src: string) =
  proc loaded(bytes: string) =
    let sequence = newGifSequence(bytes)
    if not sequence.valid:
      let r = reply("failed", id)
      r["error"] = jstr("not an animated gif")
      send(0, r)
      return
    sequences[id] = sequence
    let r = reply("loaded", id)
    r["width"] = jnum(sequence.info.width)
    r["height"] = jnum(sequence.info.height)
    r["frames"] = jnum(sequence.frameCount)
    send(0, r)
  if src.len >= 5 and src[0 ..< 5].toLowerAscii() == "data:":
    let (ok, _, bytes) = decodeDataUri(src)
    if ok: loaded(bytes)
    else: send(0, reply("failed", id))
    return
  fetchBytes(src, proc(ok: bool, data: string) =
    if ok: loaded(data)
    else:
      let r = reply("failed", id)
      r["error"] = jstr(data)
      send(0, r))

proc gifMessage(header: Val, payload: string, handles: seq[Node]) =
  let id = str(header["id"])
  case str(header["type"])
  of "load": loadGif(id, payload)
  of "next":
    let sequence = sequences.getOrDefault(id, nil)
    if sequence == nil: return
    let (frame, pixels) = sequence.next()
    let r = reply("frame", id)
    r["index"] = jnum(frame.index)
    r["delay"] = jnum(frame.delay)
    r["width"] = jnum(frame.width)
    r["height"] = jnum(frame.height)
    var bytes = newString(pixels.len)
    if pixels.len > 0: copyMem(addr bytes[0], unsafeAddr pixels[0], pixels.len)
    send(0, r, bytes)
  of "release": sequences.del(id)
  of "encode":
    # A picked file becomes a data URI here, off the page's thread.
    if handles.len == 0:
      send(0, reply("failed", id))
      return
    let file = handles[0]
    var mime = file.getStr("type")
    if mime.len == 0: mime = "application/octet-stream"
    readBlob(file, brBytes, proc(ok: bool, data: string) =
      release(file)
      if not ok:
        send(0, reply("failed", id))
        return
      send(0, reply("encoded", id), "data:" & mime & ";base64," & base64Encode(data)))
  else: discard

proc startGifWorker() =
  mainRealm = false
  onPageMessage(gifMessage)

proc startWorkerKind*(kind: int32) =
  case kind
  of WorkerRender: startRenderWorker()
  of WorkerGif: startGifWorker()
  else: discard
