## Video controls over the canvas (MediaOverlayManager).
##
## Native video is sampled into the canvas by the scene painter in the
## node's z-order, so the overlay only floats a transparent control bar over
## the node. YouTube keeps a full iframe overlay: a cross-origin frame can
## never be canvas-composited.

import std/[tables, sets, strutils, math]
import ../jsval, ../graph, ../geometry
import ../web/qweb
import jsutil, media, view

type
  Record = ref object
    id, src, mediaType: string
    youtube: bool
    duration, currentTime: float64
    playing: bool
    nodeVolume: float64
    volumeBefore: string
    hasVolumeBefore: bool
    wrapper, visual, controls: Node
    playButton, stopButton, seek, timeInput, durationLabel, volumeIcon, volume, fullscreenButton: Node
    frame, video: Node
    layoutKey: string
    shownPlay, shownTitle, shownDuration: string

  MediaOverlay* = ref object
    v: View
    layer: Node
    records: OrderedTable[string, Record]

proc formatTime(seconds0: float64): string =
  let seconds = max(0.0, floor(if seconds0 != seconds0: 0.0 else: seconds0))
  let hours = floor(seconds / 3600)
  let minutes = floor((seconds - hours * 3600) / 60)
  let secs = seconds - hours * 3600 - minutes * 60
  proc pad2(x: float64): string =
    result = jsStr(x)
    if result.len < 2: result = "0" & result
  (if hours > 0: jsStr(hours) & ":" & pad2(minutes) else: jsStr(minutes)) & ":" & pad2(secs)

proc parseTime(value: string): (bool, float64) =
  var parts: seq[float64]
  for part in jsTrim(value).split(':'):
    let n = jsNumber(part)
    if not isFiniteJs(n) or n < 0: return (false, 0)
    parts.add n
  case parts.len
  of 1: (true, parts[0])
  of 2: (true, parts[0] * 60 + parts[1])
  of 3: (true, parts[0] * 3600 + parts[1] * 60 + parts[2])
  else: (false, 0)

proc postYouTube(record: Record, fn: string, args: Val = nil) =
  if record.frame.isNil: return
  let win = record.frame.getNode("contentWindow")
  if win.isNil: return
  let msg = newObj()
  msg["event"] = jstr("command")
  msg["func"] = jstr(fn)
  msg["args"] = if args == nil: newArr() else: args
  win.call("postMessage", toJson(msg), "*")
  release(win)

proc updateControls(record: Record) =
  let duration = max(0.0, record.duration)
  let current = max(0.0, min(if duration > 0: duration else: Inf, record.currentTime))
  let playText = if record.playing: "❚❚" else: "▶"
  let playTitle = if record.playing: "Pause" else: "Play"
  let durationText = "/ " & formatTime(duration)
  if record.shownPlay != playText:
    record.playButton.text = playText
    record.shownPlay = playText
  if record.shownTitle != playTitle:
    record.playButton.title = playTitle
    record.shownTitle = playTitle
  if record.seek.getStr("max") != jsStr(duration): record.seek.setProp("max", duration)
  if record.seek.getStr("value") != jsStr(current): record.seek.setProp("value", current)
  let currentText = formatTime(current)
  if not same(activeElement(), record.timeInput) and record.timeInput.value != currentText:
    record.timeInput.value = currentText
  if record.shownDuration != durationText:
    record.durationLabel.text = durationText
    record.shownDuration = durationText

proc volumeGlyph(value: float64): string =
  if value == 0: "🔇" elif value < 50: "🔉" else: "🔊"

proc seekTo(record: Record, seconds0: float64) =
  let seconds = max(0.0, min(if record.duration > 0: record.duration else: Inf,
                             if seconds0 != seconds0: 0.0 else: seconds0))
  if record.youtube:
    let args = newArr()
    args.push jnum(seconds)
    args.push jtrue
    record.postYouTube("seekTo", args)
  elif not record.video.isNil:
    record.video.setProp("currentTime", seconds)
  record.currentTime = seconds
  record.updateControls()

proc createYouTube(o: MediaOverlay, record: Record, node: Val) =
  let frame = el("iframe", "pixel-media-frame")
  let src = strOrEmpty(node["src"])
  let id = youtubeId(src)
  let start = youtubeStart(src)
  record.currentTime = float64(start)
  let pageOrigin = location.getStr("origin")
  let origin = if pageOrigin.startsWith("http:") or pageOrigin.startsWith("https:"):
      "&origin=" & encodeURIComponent(pageOrigin) else: ""
  frame.setProp("allow", "autoplay; encrypted-media; picture-in-picture; fullscreen")
  frame.setAttribute("allowfullscreen", "")
  frame.setProp("referrerPolicy", "strict-origin-when-cross-origin")
  frame.setProp("src", "https://www.youtube-nocookie.com/embed/" & encodeURIComponent(id) &
    "?enablejsapi=1&controls=0&playsinline=1&rel=0&modestbranding=1" &
    (if start != 0: "&start=" & $start else: "") & origin)
  frame.on("load", proc(e: Event) =
    let win = frame.getNode("contentWindow")
    if not win.isNil:
      let hello = newObj()
      hello["event"] = jstr("listening")
      hello["id"] = jstr(record.id)
      win.call("postMessage", toJson(hello), "*")
      release(win)
    let volume = jsNumber(record.volume.value)
    let v = newArr()
    v.push jnum(if volume != volume or volume == 0: 100.0 else: volume)
    record.postYouTube("setVolume", v)
    let listen = newArr()
    listen.push jstr("onStateChange")
    record.postYouTube("addEventListener", listen))
  record.frame = frame
  record.visual.appendChild(frame)

proc createNative(o: MediaOverlay, record: Record, node: Val) =
  let player = playback.addVideo(strOrEmpty(node["src"]), strOrEmpty(node["mediaType"]),
                                 not node["mediaLoop"].isFalse)
  let video = if player != nil: player.video else: createElement("video")
  record.video = video
  record.wrapper.addClass("pixel-media-canvas")
  video.setProp("controls", false)
  video.setProp("loop", not node["mediaLoop"].isFalse)
  video.setProp("playsInline", true)
  let volume = clamp(if nullish(node["mediaVolume"]): 1.0 else: num(node["mediaVolume"]), 0, 1)
  video.setProp("volume", volume)
  video.setProp("muted", volume == 0)
  if player == nil:
    video.cssText = "position:absolute;width:1px;height:1px;"
    video.setProp("preload", "auto")
    video.setProp("autoplay", true)
    body.appendChild(video)
    video.setProp("src", strOrEmpty(node["src"]))
    video.call("load")
  proc update(e: Event) =
    let d = video.getNum("duration")
    record.duration = if isFiniteJs(d): d else: 0
    record.currentTime = video.getNum("currentTime")
    record.playing = not video.getBool("paused") and not video.getBool("ended")
    record.updateControls()
  for name in ["loadedmetadata", "durationchange", "timeupdate", "play", "pause", "ended", "seeked"]:
    video.on(name, update)

proc createRecord(o: MediaOverlay, node: Val): Record =
  let src = strOrEmpty(node["src"])
  let record = Record(id: idOf(node), src: src,
    mediaType: mediaTypeFor(src, strOrEmpty(node["mediaType"])),
    youtube: youtubeId(src).len > 0,
    nodeVolume: clamp(if nullish(node["mediaVolume"]): 1.0 else: num(node["mediaVolume"]), 0, 1))
  let wrapper = el("div", "pixel-media-overlay")
  wrapper.setData("nodeId", record.id)
  let visual = el("div", "pixel-media-visual")
  let controls = el("div", "pixel-media-controls")
  wrapper.appendChild(visual)
  wrapper.appendChild(controls)
  o.layer.appendChild(wrapper)
  record.wrapper = wrapper
  record.visual = visual
  record.controls = controls

  proc control(tag, cls, title: string): Node =
    result = el(tag, cls)
    if title.len > 0: result.title = title
    controls.appendChild(result)

  record.playButton = control("button", "pixel-media-button pixel-media-play", "Play")
  record.shownTitle = "Play"
  record.stopButton = control("button", "pixel-media-button", "Stop and return to 00:00")
  record.stopButton.text = "■"
  record.seek = control("input", "pixel-media-seek", "Playback position")
  record.seek.typ = "range"
  record.seek.setProp("min", 0)
  record.seek.setProp("max", 0)
  record.seek.setProp("step", 0.1)
  record.timeInput = control("input", "pixel-media-time", "Jump to time, for example 02:12")
  record.timeInput.typ = "text"
  record.timeInput.value = "0:00"
  record.durationLabel = control("span", "pixel-media-duration", "")
  record.durationLabel.text = "/ 0:00"
  record.shownDuration = "/ 0:00"
  record.volumeIcon = control("span", "pixel-media-volume-icon", "")
  record.volumeIcon.text = "🔊"
  record.volume = control("input", "pixel-media-volume", "Volume")
  record.volume.typ = "range"
  record.volume.setProp("min", 0)
  record.volume.setProp("max", 100)
  record.volume.setProp("step", 1)
  record.volume.setProp("value", jsRound((if nullish(node["mediaVolume"]): 1.0 else: num(node["mediaVolume"])) * 100))
  record.fullscreenButton = control("button", "pixel-media-button", "Fullscreen")
  record.fullscreenButton.text = "⛶"

  let v = o.v
  controls.on("pointerdown", proc(e: Event) =
    e.stopPropagation()
    discard v.call("setSelection", idsVal([record.id])))
  controls.on("dblclick", proc(e: Event) = e.stopPropagation())

  record.playButton.on("click", proc(e: Event) =
    e.stopPropagation()
    if record.youtube:
      record.postYouTube(if record.playing: "pauseVideo" else: "playVideo")
      record.playing = not record.playing
    elif not record.video.isNil:
      if record.video.getBool("paused"): record.video.call("play")
      else: record.video.call("pause")
    record.updateControls())
  record.stopButton.on("click", proc(e: Event) =
    e.stopPropagation()
    if record.youtube:
      record.postYouTube("stopVideo")
      let args = newArr()
      args.push jnum(0)
      args.push jtrue
      record.postYouTube("seekTo", args)
      record.currentTime = 0
      record.playing = false
    elif not record.video.isNil:
      record.video.call("pause")
      record.video.setProp("currentTime", 0)
    record.updateControls())
  record.seek.on("input", proc(e: Event) = record.seekTo(jsNumber(record.seek.value)))
  record.timeInput.on("change", proc(e: Event) =
    let (ok, seconds) = parseTime(record.timeInput.value)
    if ok: record.seekTo(seconds)
    else: record.updateControls())
  record.timeInput.on("keydown", proc(e: Event) =
    if e.key == "Enter":
      record.timeInput.blur()
      e.stopPropagation())
  record.volume.on("input", proc(e: Event) =
    var value = jsNumber(record.volume.value)
    if value != value: value = 0
    value = clamp(value, 0, 100)
    if record.youtube:
      let args = newArr()
      args.push jnum(value)
      record.postYouTube("setVolume", args)
      record.postYouTube(if value == 0: "mute" else: "unMute")
    elif not record.video.isNil:
      record.video.setProp("muted", value == 0)
      record.video.setProp("volume", value / 100)
    record.volumeIcon.text = volumeGlyph(value)
    let changes = newObj()
    changes["mediaVolume"] = jnum(value / 100)
    discard v.updateItem(record.id, changes)
    record.nodeVolume = value / 100)
  record.volume.on("pointerdown", proc(e: Event) =
    record.volumeBefore = v.snapshot()
    record.hasVolumeBefore = true)
  record.volume.on("change", proc(e: Event) =
    v.g.commit(record.volumeBefore, "Media Volume", record.hasVolumeBefore)
    record.hasVolumeBefore = false)
  record.fullscreenButton.on("click", proc(e: Event) =
    e.stopPropagation()
    # A canvas-composited video has a transparent wrapper, so fullscreen the
    # parked video element itself; YouTube keeps the wrapper.
    let target = if not record.youtube and not record.video.isNil: record.video else: wrapper
    target.call("requestFullscreen"))

  if record.youtube: o.createYouTube(record, node)
  else: o.createNative(record, node)
  record.updateControls()
  o.records[record.id] = record
  record

proc destroyRecord(o: MediaOverlay, record: Record) =
  if record == nil: return
  if record.youtube and not record.frame.isNil: record.frame.setProp("src", "about:blank")
  record.wrapper.dropTree()
  o.records.del(record.id)

proc onMessage(o: MediaOverlay, e: Event) =
  var data: Val = nil
  try: data = parseJson(e.data)
  except JsonError: return
  if data == nil or not data.isObj: return
  let event = strOrEmpty(data["event"])
  if event != "infoDelivery" and event != "onStateChange": return
  let source = e.source
  for record in o.records.values:
    if not record.youtube or record.frame.isNil: continue
    let win = record.frame.getNode("contentWindow")
    let match = not win.isNil and same(win, source)
    release(win)
    if not match: continue
    let info = if data["info"].isObj: data["info"] else: newObj()
    if not nullish(info["duration"]): record.duration = jsNumOr(info["duration"], 0)
    if not nullish(info["currentTime"]): record.currentTime = jsNumOr(info["currentTime"], 0)
    if not nullish(info["volume"]):
      record.volume.setProp("value", clamp(jsNumOr(info["volume"], 0), 0, 100))
    if not nullish(info["playerState"]): record.playing = num(info["playerState"]) == 1
    if data["info"].isNum:
      let state = num(data["info"])
      record.playing = state == 1
      let item = o.v.g.getItem(record.id)
      if state == 0 and item != nil and not item["mediaLoop"].isFalse:
        let args = newArr()
        args.push jnum(0)
        args.push jtrue
        record.postYouTube("seekTo", args)
        record.postYouTube("playVideo")
    record.updateControls()
  release(source)

proc sync*(o: MediaOverlay, view: Val) =
  let g = o.v.g
  var keep = initHashSet[string]()
  var hidden = initHashSet[string]()
  for id in g.hiddenLayerIds(): hidden.incl id
  var index = 0
  for node in o.v.mediaItems():
    let i = index
    inc index
    let src = strOrEmpty(node["src"])
    # Parallax-layered nodes composite their whole stack on the canvas; a DOM
    # overlay would hide every layer beneath the base video.
    if node.eqs("type", "edge") or src.len == 0 or
        (node["mediaLayers"].isArr and node["mediaLayers"].len > 0) or
        not isVideoSource(src, strOrEmpty(node["mediaType"])): continue
    let id = idOf(node)
    keep.incl id
    var record = o.records.getOrDefault(id, nil)
    let kind = mediaTypeFor(src, strOrEmpty(node["mediaType"]))
    if record == nil or record.src != src or record.mediaType != kind:
      if record != nil: o.destroyRecord(record)
      record = o.createRecord(node)
    let visible = not node["visible"].isFalse and not truthy(node["foldedAway"]) and
      strOrEmpty(node["layer"]) notin hidden
    record.wrapper.hidden = not visible
    if not visible: continue
    let zoom = if g.zoom != 0: g.zoom else: 1.0
    let selected = id in g.selection
    let left = (num(node["x"]) + g.worldOriginX) * zoom
    let top = (num(node["y"]) + g.worldOriginY) * zoom
    let width = max(24.0, num(node["width"]) * zoom)
    let height = max(24.0, num(node["height"]) * zoom)
    let rotation = jsNumOr(node["rotation"], 0)
    let zIndex = max(0.0, if jsNumOr(node["z"], 0) != 0: num(node["z"]) else: float64(i))
    let layoutKey = [jsStr(left), jsStr(top), jsStr(width), jsStr(height), jsStr(rotation),
      jsStr(zIndex), $int(selected), $int(width < 360), $int(width < 245)].join("|")
    if record.layoutKey != layoutKey:
      record.layoutKey = layoutKey
      record.wrapper.style("left", jsStr(left) & "px")
      record.wrapper.style("top", jsStr(top) & "px")
      record.wrapper.style("width", jsStr(width) & "px")
      record.wrapper.style("height", jsStr(height) & "px")
      record.wrapper.style("transform", "rotate(" & jsStr(rotation) & "deg)")
      record.wrapper.style("zIndex", jsStr(zIndex))
      record.wrapper.toggleClass("pixel-media-selected", selected)
      record.wrapper.toggleClass("pixel-media-compact", width < 360)
      record.wrapper.toggleClass("pixel-media-tiny", width < 245)
    let nodeVolume = clamp(if nullish(node["mediaVolume"]): 1.0 else: num(node["mediaVolume"]), 0, 1)
    if abs(nodeVolume - record.nodeVolume) > 0.001:
      record.nodeVolume = nodeVolume
      record.volume.setProp("value", jsRound(nodeVolume * 100))
      record.volumeIcon.text = volumeGlyph(nodeVolume * 100)
      if record.youtube:
        let args = newArr()
        args.push jnum(jsRound(nodeVolume * 100))
        record.postYouTube("setVolume", args)
        record.postYouTube(if nodeVolume == 0: "mute" else: "unMute")
      elif not record.video.isNil:
        record.video.setProp("volume", nodeVolume)
        record.video.setProp("muted", nodeVolume == 0)
    if not record.video.isNil:
      record.video.setProp("loop", not node["mediaLoop"].isFalse)
  var drop: seq[Record]
  for record in o.records.values:
    if record.id notin keep: drop.add record
  for record in drop: o.destroyRecord(record)

proc newMediaOverlay*(v: View): MediaOverlay =
  let o = MediaOverlay(v: v, layer: v.mediaLayer)
  window.on("message", proc(e: Event) = o.onMessage(e))
  v.overlaySync = proc(view: Val) = o.sync(view)
  o
