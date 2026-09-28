# Included from editorui.nim: dialogs (style/data editors, Edit Media,
# HTML block, SVG import, whole-document editor) and autosave.

proc button(label: string, cls = "qg-btn"): Node =
  result = el("button", cls)
  result.typ = "button"
  result.text = label

proc editStyle*(ui: EditorUi) =
  let gv = ui.graph
  let selection = gv.getSelection()
  if selection.len == 0: return
  let item = selection[0]
  let selectedCell = gv.call("getSelectedTableCell")
  let hasCell = truthy(selectedCell)
  let source = if hasCell: selectedCell["cell"] else: item
  let style = newObj()
  if source.isObj:
    for (key, value) in source.pairs:
      if key in ["id", "type", "x", "y", "width", "height", "sourceId", "targetId",
                 "route", "text", "tasks", "groups", "groupId"]: continue
      style.put(if key == "align" and hasCell: "textAlign" else: key, value)
  let (ok, text) = prompt("Style JSON", toJsonPretty(style, 2))
  if not ok: return
  try: gv.applyStyle(parseJson(text), "Edit Style")
  except JsonError as error: ui.toast("Invalid style JSON: " & error.msg)

proc editData*(ui: EditorUi) =
  let gv = ui.graph
  let selection = gv.getSelection()
  if selection.len == 0:
    ui.showDialog("Diagram Data", "Select an object to edit its custom JSON data. Diagram settings are available in the Diagram panel.")
    return
  let item = selection[0]
  let (ok, text) = prompt("Object JSON", toJsonPretty(item, 2))
  if not ok: return
  try:
    let parsed = parseJson(text)
    if not parsed.isObj: raise newException(JsonError, "not an object")
    parsed["id"] = item["id"]
    parsed["type"] = item["type"]
    discard gv.g.replaceItem(idOf(item), parsed, "Edit Data")
  except JsonError as error: ui.toast("Invalid JSON: " & error.msg)

# ---------------------------------------------------------------- media --

type
  MediaDraft = ref object
    src, mediaType, sourceLabel: string
    previewSrc, previewObjectUrl: string
    encoding: bool
    depth, opacity, scrollX, scrollY: float64

proc humanBytes(bytes0: float64): string =
  let bytes = max(0.0, if bytes0 != bytes0: 0.0 else: bytes0)
  if bytes < 1024: return jsStr(bytes) & " B"
  if bytes < 1024 * 1024: return toFixed(bytes / 1024, 1) & " KB"
  toFixed(bytes / 1024 / 1024, 1) & " MB"

proc embeddedSize(src: string): float64 =
  let comma = src.find(',')
  if comma < 0: 0.0 else: jsRound(float64(src.len - comma - 1) * 0.75)

proc isDataUri(src: string): bool = src.len >= 5 and src[0 ..< 5].toLowerAscii() == "data:"

proc sourceType(src, explicitType: string): string =
  if explicitType.len > 0: explicitType else: mediaTypeFor(src, "")

proc sourceSummary(src, explicitType, label: string): string =
  if label.len > 0: return label
  if isDataUri(src):
    let semi = src.find(';')
    let e = if semi > 0: semi else: src.find(',')
    let kind = if explicitType.len > 0: explicitType
               elif e > 5: src[5 ..< e] else: "embedded media"
    return "Embedded " & (if kind.len > 0: kind else: "embedded media") & " · " &
      humanBytes(embeddedSize(src)) & " · source text hidden"
  src

proc cleanLayer(layer: Val): MediaDraft =
  let l = if layer.isObj: layer else: newObj()
  let layerOpacity = if nullish(l["opacity"]): 1.0 else: num(l["opacity"])
  MediaDraft(src: valStr(l["src"]), mediaType: valStr(l["mediaType"]),
    depth: clamp(jsNumOr(l["depth"], 0), 0, 1),
    opacity: clamp(if isFiniteJs(layerOpacity): layerOpacity else: 1.0, 0, 1),
    scrollX: jsNumOr(l["scrollX"], 0), scrollY: jsNumOr(l["scrollY"], 0))

proc validMediaFile(file: Node): bool =
  if file.isNil: return false
  let kind = file.getStr("type").toLowerAscii()
  let name = file.getStr("name").toLowerAscii()
  kind.startsWith("image/") or kind == "video/mp4" or kind == "video/webm" or
    name.endsWith(".mp4") or name.endsWith(".webm")

proc editMedia*(ui: EditorUi, target: Val = nil) =
  ## Edit Media: a live preview that reports load failures, a file picker
  ## and drop target beside the URL field, fit and alignment, parallax
  ## layers, and a one-click reset to the media's natural aspect ratio.
  let gv = ui.graph
  var node = target
  if node == nil:
    for item in gv.getSelection():
      if item.eqs("shape", "image"):
        node = item
        break
  if node == nil:
    let selection = gv.getSelection()
    if selection.len > 0: node = selection[0]
  if node == nil:
    ui.toast("Select a shape to give it media")
    return
  let nodeId = idOf(node)

  let (backdrop, dialog) = ui.dialogShell("min(720px, calc(100vw - 32px))", "qg-dialog qg-media-dialog")
  let heading = el("h2", "qg-dialog-title")
  heading.text = "Edit Media"

  let draft = MediaDraft(src: valStr(node["src"]),
    mediaType: if truthy(node["mediaType"]): str(node["mediaType"]) else: mediaTypeFor(valStr(node["src"]), ""))
  var imageFit = if truthy(node["imageFit"]): str(node["imageFit"]) else: "contain"
  var imageAlign = if truthy(node["imageAlign"]): str(node["imageAlign"]) else: "center"
  var imageVerticalAlign = if truthy(node["imageVerticalAlign"]): str(node["imageVerticalAlign"]) else: "middle"
  var imageOpacity = if nullish(node["imageOpacity"]): 1.0 else: num(node["imageOpacity"])
  var mediaLoop = not node["mediaLoop"].isFalse
  var mediaVolume = if nullish(node["mediaVolume"]): 1.0 else: num(node["mediaVolume"])
  var layers: seq[MediaDraft]
  if node["mediaLayers"].isArr:
    for layer in node["mediaLayers"]: layers.add cleanLayer(layer)
  var tooltip = valStr(node["tooltip"])
  var natural = (0.0, 0.0)
  var hasNatural = false

  let url = el("input", "qg-input")
  url.typ = "text"
  url.setProp("placeholder", "YouTube, MP4, WebM, image or GIF URL")
  var urlLocked = false
  proc syncSourceField() =
    urlLocked = draft.sourceLabel.len > 0 or isDataUri(draft.src)
    url.value = sourceSummary(draft.src, draft.mediaType, draft.sourceLabel)
    url.setProp("readOnly", urlLocked)
    url.toggleClass("is-summary", urlLocked)

  let replaceUrl = button("Replace URL…", "qg-btn")
  let sourceRow = div0("qg-media-source")
  sourceRow.appendChild(url)
  sourceRow.appendChild(replaceUrl)
  syncSourceField()

  let picker = createElement("input")
  picker.typ = "file"
  picker.setProp("accept", "image/*,video/mp4,video/webm,.mp4,.webm")
  picker.hidden = true
  let layerPicker = createElement("input")
  layerPicker.typ = "file"
  layerPicker.setProp("accept", "image/*,video/mp4,video/webm,.mp4,.webm")
  layerPicker.setProp("multiple", true)
  layerPicker.hidden = true

  let preview = div0("qg-media-preview")
  let previewCanvas = createElement("canvas")
  let previewNote = div0("qg-media-note")
  preview.appendChild(previewCanvas)
  preview.appendChild(previewNote)
  let previewContext = previewCanvas.context2d()
  let previewCtx = newCtx()
  var previewFrame = 0'i32
  var previewState = ""
  var previewDirty = true
  var lastPreviewPaint = 0.0
  var canvasW, canvasH = 0.0

  proc activeSource(): string = (if draft.previewSrc.len > 0: draft.previewSrc else: draft.src)
  proc activeMediaType(): string = sourceType(activeSource(), draft.mediaType)
  proc isVideo(): bool = isVideoSource(activeSource(), activeMediaType())

  proc previewLayers(): Val =
    result = newArr()
    for layer in layers:
      let src = if layer.previewSrc.len > 0: layer.previewSrc else: layer.src
      if src.len == 0: continue
      let l = newObj()
      l["src"] = jstr(src)
      l["mediaType"] = jstr(sourceType(src, layer.mediaType))
      l["depth"] = jnum(layer.depth)
      l["opacity"] = jnum(layer.opacity)
      l["scrollX"] = jnum(layer.scrollX)
      l["scrollY"] = jnum(layer.scrollY)
      result.push l

  proc persistentLayers(): Val =
    result = newArr()
    for layer in layers:
      if layer.src.len == 0: continue
      let l = newObj()
      l["src"] = jstr(layer.src)
      l["mediaType"] = jstr(sourceType(layer.src, layer.mediaType))
      l["depth"] = jnum(clamp(layer.depth, 0, 1))
      l["opacity"] = jnum(clamp(layer.opacity, 0, 1))
      l["scrollX"] = jnum(layer.scrollX)
      l["scrollY"] = jnum(layer.scrollY)
      result.push l

  proc describe(state, message: string) =
    previewNote.text = message
    previewNote.className = "qg-media-note " & state

  proc layerPlaybackBusy(layer: MediaDraft): bool =
    let src = if layer.previewSrc.len > 0: layer.previewSrc else: layer.src
    if src.len == 0: return false
    if isVideoSource(src, layer.mediaType): return true
    if layer.scrollX != 0 or layer.scrollY != 0: return true
    playback.imageState(src) == 0 or playback.isAnimated(src)

  proc paintPreview() =
    var dpr = window.getNum("devicePixelRatio")
    if dpr == 0 or dpr != dpr: dpr = 1
    let ratio = min(2.0, dpr)
    var width = preview.getNum("clientWidth")
    if width == 0: width = 640
    var height = preview.getNum("clientHeight")
    if height == 0: height = 210
    let boxWidth = max(20.0, width - 16)
    let boxHeight = max(20.0, height - 32)
    if canvasW != jsRound(width * ratio) or canvasH != jsRound(height * ratio):
      canvasW = jsRound(width * ratio)
      canvasH = jsRound(height * ratio)
      previewCanvas.setProp("width", canvasW)
      previewCanvas.setProp("height", canvasH)
      previewCanvas.style("width", px(width))
      previewCanvas.style("height", px(height))
    let ctx = previewCtx
    ctx.reset()
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0)
    ctx.clearRect(0, 0, width, height)
    let source = activeSource()
    if source.len == 0:
      ctx.finish()
      replay(previewContext, addr ctx.buf)
      return
    let pl = previewLayers()
    if isYouTube(source):
      ctx.fillStyle = "#111"
      ctx.fillRect(8, 8, boxWidth, boxHeight)
      ctx.fillStyle = "#ff0033"
      ctx.font = "bold 22px Arial, sans-serif"
      ctx.textAlign = "center"
      ctx.textBaseline = "middle"
      ctx.fillText("YouTube", 8 + boxWidth / 2, 8 + boxHeight / 2 - 8)
      ctx.fillStyle = "#fff"
      ctx.font = "11px Arial, sans-serif"
      ctx.fillText(if pl.len > 0: "Parallax layers require image/MP4/WebM base media"
                   else: "Streams in real time after Apply", 8 + boxWidth / 2, 8 + boxHeight / 2 + 16)
      ctx.finish()
      replay(previewContext, addr ctx.buf)
      natural = (16.0, 9.0)
      hasNatural = true
      previewState = "ok"
      if pl.len > 0: describe("is-error", "YouTube cannot be canvas-composited with parallax layers. Use MP4/WebM instead.")
      else: describe("is-ok", "YouTube · real-time streaming · no download")
      return
    let item = newObj()
    item["id"] = jstr("media-preview")
    item["src"] = jstr(source)
    item["mediaType"] = jstr(activeMediaType())
    item["mediaLayers"] = pl
    playback.scanForAnimation(newArr([item]))
    let n = newObj()
    n["x"] = jnum(8)
    n["y"] = jnum(8)
    n["width"] = jnum(boxWidth)
    n["height"] = jnum(boxHeight)
    n["src"] = jstr(source)
    n["mediaType"] = jstr(activeMediaType())
    n["mediaLoop"] = jbool(mediaLoop)
    n["imageFit"] = jstr(imageFit)
    n["imageAlign"] = jstr(imageAlign)
    n["imageVerticalAlign"] = jstr(imageVerticalAlign)
    n["imageOpacity"] = jnum(imageOpacity)
    n["mediaLayers"] = pl
    drawImageNode(ctx, n)
    ctx.finish()
    replay(previewContext, addr ctx.buf)

    var nextState = "loading"
    var size = (0.0, 0.0)
    if isVideo():
      let player = playback.videoState(source)
      if player != nil and player.ready:
        nextState = "ok"
        size = player.videoSize()
      elif player != nil and player.failed: nextState = "error"
    else:
      let state = playback.imageState(source)
      if state == 1:
        nextState = "ok"
        size = playback.imageSize(source)
      elif state == -1: nextState = "error"
    if nextState != previewState or previewDirty:
      previewState = nextState
      if nextState == "error":
        describe("is-error", "That base media could not be loaded. Check the URL or choose a file.")
      elif nextState == "loading":
        describe("is-empty", "Loading base media" &
          (if pl.len > 0: " + " & $pl.len & " layer(s)…" else: "…"))
      else:
        natural = size
        hasNatural = true
        describe("is-ok", jsStr(size[0]) & " × " & jsStr(size[1]) & " px" &
          (if isVideo(): " · streaming video" elif playback.isAnimated(source): " · animated" else: "") &
          (if pl.len > 0: " · " & $pl.len & " parallax layer(s)" else: ""))

  proc tick(now: float64) {.closure.}
  proc tick(now: float64) =
    previewFrame = requestAnimationFrame(tick)
    let source = activeSource()
    let animated = source.len > 0 and (isVideo() or playback.isAnimated(source))
    var layerBusy = false
    for layer in layers:
      if layerPlaybackBusy(layer): layerBusy = true
    let easing = abs(playback.parallaxTarget.x - playback.parallax.x) > 0.001 or
                 abs(playback.parallaxTarget.y - playback.parallax.y) > 0.001
    if animated or layerBusy: discard playback.tickGifs(now)
    let busy = source.len > 0 and (playback.imageState(source) == 0 or animated or layerBusy or easing)
    if previewDirty or (busy and (lastPreviewPaint == 0 or now - lastPreviewPaint >= 66)):
      previewDirty = false
      lastPreviewPaint = now
      paintPreview()

  var loopRow, volumeRow: Node
  proc loadPreview() =
    hasNatural = false
    previewState = ""
    previewDirty = true
    if not loopRow.isNil: loopRow.hidden = not isVideo()
    if not volumeRow.isNil: volumeRow.hidden = not isVideo()
    if activeSource().len == 0:
      describe("is-empty", "No base media yet — paste a URL or choose an image, GIF, MP4 or WebM file.")
    paintPreview()

  proc cleanupDraftSource(owner: MediaDraft) =
    if owner.previewSrc.len > 0: playback.removeVideo(owner.previewSrc)
    if owner.previewObjectUrl.len > 0: revokeObjectURL(owner.previewObjectUrl)
    owner.previewSrc = ""
    owner.previewObjectUrl = ""
    owner.encoding = false
    owner.sourceLabel = ""

  var pendingEncodes = 0
  var afterEncodes: proc() = nil

  proc encodeFileInto(owner: MediaDraft, file: Node, after: proc()) =
    if not validMediaFile(file):
      describe("is-error", "Choose an image, GIF, MP4 or WebM file.")
      return
    cleanupDraftSource(owner)
    let blobUrl = createObjectURL(file)
    owner.previewObjectUrl = blobUrl
    owner.previewSrc = blobUrl
    let name = file.getStr("name")
    let kind = file.getStr("type")
    let size = file.getNum("size")
    owner.mediaType = if kind.len > 0: kind else: sourceType(name, "")
    owner.sourceLabel = name & " · " & humanBytes(size) & " · buffering in worker"
    if tooltip.len == 0: tooltip = name
    if after != nil: after()
    loadPreview()
    owner.encoding = true
    inc pendingEncodes
    playback.encodeFile(file, proc(ok: bool, dataUrl: string) =
      dec pendingEncodes
      owner.encoding = false
      if ok:
        owner.src = dataUrl
        owner.sourceLabel = name & " · " & humanBytes(size) & " · embedded"
        if after != nil: after()
        previewDirty = true
      if pendingEncodes == 0 and afterEncodes != nil:
        let f = afterEncodes
        afterEncodes = nil
        f())

  url.on("change", proc(e: Event) =
    if urlLocked: return
    draft.src = jsTrim(url.value)
    draft.mediaType = sourceType(draft.src, "")
    draft.sourceLabel = ""
    loadPreview())
  url.on("input", proc(e: Event) =
    if urlLocked: return
    draft.src = jsTrim(url.value)
    draft.mediaType = sourceType(draft.src, "")
    previewDirty = true)
  replaceUrl.on("click", proc(e: Event) =
    cleanupDraftSource(draft)
    draft.src = ""
    draft.mediaType = ""
    syncSourceField()
    url.focus()
    loadPreview())
  picker.on("change", proc(e: Event) =
    let files = picker.getNode("files")
    if not files.isNil and files.getNum("length") > 0:
      encodeFileInto(draft, files.invoke("item", 0).toNode, syncSourceField)
    picker.value = "")
  preview.on("dragover", proc(e: Event) =
    e.preventDefault()
    preview.addClass("is-drop-target"))
  preview.on("dragleave", proc(e: Event) = preview.removeClass("is-drop-target"))
  preview.on("drop", proc(e: Event) =
    e.preventDefault()
    preview.removeClass("is-drop-target")
    let files = e.dataTransfer.getNode("files")
    let file = if not files.isNil and files.getNum("length") > 0: files.invoke("item", 0).toNode else: nilNode
    encodeFileInto(draft, file, syncSourceField))
  preview.on("click", proc(e: Event) = picker.click())
  preview.on("pointermove", proc(e: Event) =
    let r = rect(preview)
    if r.width == 0 or r.height == 0: return
    playback.setParallaxTarget(clamp(((e.clientX - r.left) / r.width - 0.5) * 2, -1, 1),
                               clamp(((e.clientY - r.top) / r.height - 0.5) * 2, -1, 1))
    previewDirty = true)
  preview.on("pointerleave", proc(e: Event) =
    playback.setParallaxTarget(0, 0)
    previewDirty = true)

  proc row(labelText: string, control: Node): Node =
    result = el("label", "qg-field")
    let caption = createElement("span")
    caption.text = labelText
    result.appendChild(caption)
    result.appendChild(control)

  proc selectControl(values: openArray[(string, string)], current: string,
                     handler: proc(value: string)): Node =
    let element = createElement("select")
    element.fillOptions(values)
    element.value = current
    element.on("change", proc(e: Event) =
      handler(element.value)
      previewDirty = true)
    element

  let options = div0("qg-media-options")
  options.appendChild(row("Fit", selectControl([
    ("contain", "Fit inside (keep ratio)"), ("cover", "Fill box (crop)"),
    ("stretch", "Stretch to box"), ("none", "Natural size"), ("tile", "Tile")],
    imageFit, proc(value: string) = imageFit = value)))
  options.appendChild(row("Horizontal", selectControl([
    ("center", "Centre"), ("left", "Left"), ("right", "Right")],
    imageAlign, proc(value: string) = imageAlign = value)))
  options.appendChild(row("Vertical", selectControl([
    ("middle", "Middle"), ("top", "Top"), ("bottom", "Bottom")],
    imageVerticalAlign, proc(value: string) = imageVerticalAlign = value)))

  proc percentInput(value: float64): Node =
    result = createElement("input")
    result.typ = "number"
    result.setProp("min", 0)
    result.setProp("max", 100)
    result.setProp("step", 5)
    result.value = jsStr(jsRound(value * 100))
  let opacity = percentInput(imageOpacity)
  opacity.on("input", proc(e: Event) =
    imageOpacity = clamp(numVal(opacity.value, 0), 0, 100) / 100
    previewDirty = true)
  options.appendChild(row("Base opacity %", opacity))
  let volume = percentInput(mediaVolume)
  volume.on("input", proc(e: Event) = mediaVolume = clamp(numVal(volume.value, 0), 0, 100) / 100)
  volumeRow = row("Initial volume %", volume)
  options.appendChild(volumeRow)
  let loop = createElement("input")
  loop.typ = "checkbox"
  loop.checked = mediaLoop
  loop.on("change", proc(e: Event) =
    mediaLoop = loop.checked
    previewDirty = true)
  loopRow = row("Loop video", loop)
  options.appendChild(loopRow)
  let alt = createElement("input")
  alt.typ = "text"
  alt.value = tooltip
  alt.on("input", proc(e: Event) = tooltip = alt.value)
  options.appendChild(row("Alt text", alt))

  let layersSection = div0("qg-media-layers")
  let layersHeader = div0("qg-media-layers-head")
  let layersTitle = div0("qg-media-layers-title")
  layersTitle.html = "<strong>Parallax Layers</strong><span>Back → front. Depth reacts to pointer; scroll values are px/s.</span>"
  let layerActions = div0("qg-media-layer-actions")
  let addLayerUrl = button("+ URL Layer")
  let addLayerFile = button("+ File Layer…")
  layerActions.appendChild(addLayerUrl)
  layerActions.appendChild(addLayerFile)
  layersHeader.appendChild(layersTitle)
  layersHeader.appendChild(layerActions)
  layersSection.appendChild(layersHeader)
  let layersList = div0("qg-media-layer-list")
  layersSection.appendChild(layersList)

  proc layerNumberInput(value, min, max, step: float64, handler: proc(value: float64), bounded = true): Node =
    let input = createElement("input")
    input.typ = "number"
    if bounded:
      input.setProp("min", min)
      input.setProp("max", max)
    input.setProp("step", step)
    input.value = jsStr(value)
    input.on("input", proc(e: Event) =
      let next = numVal(input.value, 0)
      if next != next or next == Inf or next == -Inf: return
      handler(next)
      previewDirty = true)
    input

  proc renderLayers(focusIndex = -1) {.closure.}
  proc renderLayers(focusIndex = -1) =
    layersList.dropChildren()
    if layers.len == 0:
      let empty = div0("qg-media-empty")
      empty.text = "No extra layers. Add images/GIFs/MP4/WebM for depth or moving scenery."
      layersList.appendChild(empty)
      previewDirty = true
      return
    # Each card needs its own closure environment: loop bindings can otherwise
    # make the controls of earlier cards write into the last layer.
    proc renderLayer(i: int, layer: MediaDraft) =
      let card = div0("qg-media-layer")
      let header = div0("qg-media-layer-head")
      let name = createElement("strong")
      name.text = "Layer " & $(i + 1) & (if i == 0: " · back"
        elif i == layers.len - 1: " · front" else: "")
      let buttons = div0("qg-media-layer-buttons")
      proc mini(label, title: string, handler: proc(), disabled: bool): Node =
        result = button(label, "qg-btn qg-btn-sm")
        result.typ = "button"
        result.title = title
        result.disabled = disabled
        result.on("click", proc(e: Event) = handler())
      buttons.appendChild(mini("↑", "Move layer toward the back", proc() =
        if i <= 0: return
        let moved = layers[i]
        layers.delete(i)
        layers.insert(moved, i - 1)
        renderLayers(i - 1), i == 0))
      buttons.appendChild(mini("↓", "Move layer toward the front", proc() =
        if i >= layers.len - 1: return
        let moved = layers[i]
        layers.delete(i)
        layers.insert(moved, i + 1)
        renderLayers(i + 1), i == layers.len - 1))
      buttons.appendChild(mini("Remove", "Remove this media layer", proc() =
        cleanupDraftSource(layer)
        layers.delete(i)
        renderLayers()
        loadPreview(), false))
      header.appendChild(name)
      header.appendChild(buttons)
      card.appendChild(header)

      let sourceLine = div0("qg-media-source")
      let sourceInput = el("input", "qg-input")
      sourceInput.typ = "text"
      sourceInput.setProp("placeholder", "Image, GIF, MP4 or WebM URL")
      let locked = layer.sourceLabel.len > 0 or isDataUri(layer.src)
      sourceInput.value = sourceSummary(layer.src, layer.mediaType, layer.sourceLabel)
      sourceInput.setProp("readOnly", locked)
      sourceInput.toggleClass("is-summary", locked)
      sourceInput.on("input", proc(e: Event) =
        if locked: return
        layer.src = jsTrim(sourceInput.value)
        layer.mediaType = sourceType(layer.src, "")
        previewDirty = true)
      sourceInput.on("change", proc(e: Event) = loadPreview())
      sourceLine.appendChild(sourceInput)
      let replace = button(if locked: "Replace URL…" else: "Clear", "qg-btn qg-btn-sm")
      replace.on("click", proc(e: Event) =
        cleanupDraftSource(layer)
        layer.src = ""
        layer.mediaType = ""
        renderLayers(i)
        loadPreview())
      sourceLine.appendChild(replace)
      card.appendChild(sourceLine)

      let controls = div0("qg-media-layer-controls")
      proc control(label: string, input: Node) =
        let item = createElement("label")
        let caption = createElement("span")
        caption.text = label
        item.appendChild(caption)
        item.appendChild(input)
        controls.appendChild(item)
      control("Depth %", layerNumberInput(jsRound(layer.depth * 100), 0, 100, 5,
        proc(value: float64) = layer.depth = clamp(value, 0, 100) / 100))
      control("Opacity %", layerNumberInput(jsRound(layer.opacity * 100), 0, 100, 5,
        proc(value: float64) = layer.opacity = clamp(value, 0, 100) / 100))
      control("Scroll X", layerNumberInput(layer.scrollX, 0, 0, 5,
        proc(value: float64) = layer.scrollX = value, bounded = false))
      control("Scroll Y", layerNumberInput(layer.scrollY, 0, 0, 5,
        proc(value: float64) = layer.scrollY = value, bounded = false))
      card.appendChild(controls)
      layersList.appendChild(card)
      if focusIndex == i and not locked:
        setTimeout(0, proc() = sourceInput.focus())
    for i, layer in layers:
      renderLayer(i, layer)
    previewDirty = true
    loadPreview()

  addLayerUrl.on("click", proc(e: Event) =
    let depth = min(1.0, 0.25 + float64(layers.len) * 0.2)
    let layer = cleanLayer(nil)
    layer.depth = depth
    layer.opacity = 1
    layers.add layer
    renderLayers(layers.len - 1))
  addLayerFile.on("click", proc(e: Event) = layerPicker.click())
  layerPicker.on("change", proc(e: Event) =
    let files = layerPicker.getNode("files")
    var picked: seq[Node]
    if not files.isNil:
      for k in 0 ..< int(files.getNum("length")): picked.add files.invoke("item", k).toNode
    layerPicker.value = ""
    for file in picked:
      if not validMediaFile(file): continue
      let layer = cleanLayer(nil)
      layer.depth = min(1.0, 0.25 + float64(layers.len) * 0.2)
      layer.opacity = 1
      layers.add layer
      encodeFileInto(layer, file, proc() = renderLayers())
    renderLayers())

  proc close() =
    if previewFrame != 0: cancelAnimationFrame(previewFrame)
    previewFrame = 0
    cleanupDraftSource(draft)
    for layer in layers: cleanupDraftSource(layer)
    backdrop.dropTree()

  let chooseFile = button("Choose Base File…")
  chooseFile.on("click", proc(e: Event) = picker.click())
  let resetRatio = button("Reset Ratio")
  resetRatio.setAttribute("title", "Resize the shape to the base media aspect ratio")
  resetRatio.on("click", proc(e: Event) =
    if not hasNatural or natural[0] == 0:
      ui.toast("Load base media first")
      return
    let item = gv.g.getItem(nodeId)
    if item == nil: return
    let scale = num(item["width"]) / natural[0]
    let height = max(1.0, jsRound(natural[1] * scale))
    discard gv.updateItem(nodeId, o1("height", jnum(height)))
    ui.toast("Height set to " & jsStr(height) & " px"))
  let remove = button("Remove Media")
  remove.on("click", proc(e: Event) =
    let changes = newObj()
    for key in ["src", "mediaType", "mediaLoop", "mediaVolume", "mediaLayers"]: changes.put(key, nil)
    let item = gv.g.getItem(nodeId)
    if item != nil and item.eqs("shape", "image"): changes["shape"] = jstr("rect")
    discard gv.updateItem(nodeId, changes, "Remove Media", true)
    playback.retainVideos(newArr(gv.items))
    close()
    ui.toast("Media removed"))
  let cancel = button("Cancel")
  cancel.on("click", proc(e: Event) = close())
  let apply = button("OK", "qg-btn qg-btn-primary")
  apply.on("click", proc(e: Event) =
    proc commitMedia() =
      if draft.src.len == 0:
        ui.toast("Choose base media first")
        return
      let saved = persistentLayers()
      if isYouTube(draft.src) and saved.len > 0:
        ui.toast("Parallax layers need an image, GIF, MP4 or WebM base — not YouTube")
        return
      let changes = newObj()
      changes["shape"] = jstr("image")
      changes["src"] = jstr(draft.src)
      changes["mediaType"] = jstr(sourceType(draft.src, draft.mediaType))
      changes["mediaLoop"] = jbool(mediaLoop)
      changes["mediaVolume"] = jnum(mediaVolume)
      changes["imageFit"] = jstr(imageFit)
      changes["imageAlign"] = jstr(imageAlign)
      changes["imageVerticalAlign"] = jstr(imageVerticalAlign)
      changes["imageOpacity"] = jnum(imageOpacity)
      changes["tooltip"] = jstr(tooltip)
      changes.put("mediaLayers", if saved.len > 0: saved else: nil)
      let item = gv.g.getItem(nodeId)
      if item != nil and (nullish(item["fill"]) or item.eqs("fill", "#ffffff")):
        changes["fill"] = jstr("transparent")
      discard gv.updateItem(nodeId, changes, "Edit Media", true)
      playback.retainVideos(newArr(gv.items))
      gv.emit("selectionchange", itemsVal(gv.getSelection()))
      close()
      ui.toast(if saved.len > 0: "Media + " & $saved.len & " parallax layer(s) updated" else: "Media updated")
    if pendingEncodes > 0:
      apply.disabled = true
      apply.text = "Buffering…"
      afterEncodes = proc() =
        apply.disabled = false
        apply.text = "OK"
        commitMedia()
    else:
      commitMedia())

  let footer = div0("qg-dialog-actions qg-media-actions")
  for b in [chooseFile, resetRatio, remove, cancel, apply]: footer.appendChild(b)
  for child in [heading, sourceRow, preview, options, layersSection, picker, layerPicker, footer]:
    dialog.appendChild(child)
  body.appendChild(backdrop)
  renderLayers()
  url.focus()
  loadPreview()
  tick(0)

proc insertMedia*(ui: EditorUi) =
  if ui.imageInput.isNil:
    ui.imageInput = createElement("input")
    ui.imageInput.typ = "file"
    ui.imageInput.setProp("accept", "image/*,video/mp4,video/webm,.mp4,.webm")
    ui.imageInput.hidden = true
    ui.container.appendChild(ui.imageInput)
    ui.imageInput.on("change", proc(e: Event) =
      let files = ui.imageInput.getNode("files")
      let file = if not files.isNil and files.getNum("length") > 0: files.invoke("item", 0).toNode else: nilNode
      ui.imageInput.value = ""
      if file.isNil: return
      let name = file.getStr("name")
      let kind = file.getStr("type")
      ui.toast("Buffering " & name & "…")
      playback.encodeFile(file, proc(ok: bool, dataUrl: string) =
        if not ok: return
        discard ui.graph.insertMedia(dataUrl, name, nil, kind)
        ui.toast("Media inserted")))
  let (ok, value) = prompt("Media URL — image, GIF, MP4 or WebM (leave empty to choose a file)", "")
  if not ok: return
  let url = jsTrim(value)
  if url.len == 0: ui.imageInput.click()
  else: discard ui.graph.insertMedia(url, url, nil, mediaTypeFor(url, ""))

proc toggleAutosave*(ui: EditorUi) =
  ui.autosaveEnabled = not ui.autosaveEnabled
  if ui.autosaveEnabled:
    if not ui.autosaveInstalled:
      ui.autosaveInstalled = true
      # Debounced so a burst of edits writes once.
      ui.graph.on("change", proc(d: Val) =
        if not ui.autosaveEnabled: return
        clearTimeout(ui.autosaveTimer)
        ui.autosaveTimer = setTimeout(1500, proc() =
          ui.autosaveTimer = 0
          if storageSet(DocumentKey, ui.graph.toJSON()):
            let time = construct("Date").invoke("toLocaleTimeString").toStr
            ui.setStatusText("Autosaved " & time)
          else:
            ui.toast("Autosave failed: " & lastError())))
    ui.toast("Autosave on")
  else:
    clearTimeout(ui.autosaveTimer)
    ui.toast("Autosave off")

# ------------------------------------------------------------- HTML block --

proc editHtml*(ui: EditorUi, target: Val = nil) =
  ## HTML block editor. The canvas cannot host a DOM subtree, so the markup
  ## is parsed into the rich text model and painted; the source stays on the
  ## node so it can be edited again.
  let gv = ui.graph
  let node = if target != nil and target.eqs("shape", "html"): target else: nil
  let creating = node == nil
  let (backdrop, dialog) = ui.dialogShell("min(680px, calc(100vw - 32px))")
  let heading = el("h2", "qg-dialog-title")
  heading.text = if creating: "Insert HTML Block" else: "Edit HTML"
  let hint = el("p", "qg-dialog-text")
  hint.text = "Headings, paragraphs, lists, bold, italic, underline, " &
    "colours and font sizes are rendered on the canvas. Scripts and embeds are ignored."
  let area = el("textarea", "qg-code")
  area.style("height", "32vh")
  area.setProp("spellcheck", false)
  area.value = if node != nil: valStr(node["html"])
    else: "<h3>Title</h3><p>Some <b>rich</b> text.</p><ul><li>One</li><li>Two</li></ul>"
  let preview = div0("qg-html-preview")
  let previewCanvas = createElement("canvas")
  preview.appendChild(previewCanvas)
  let previewContext = previewCanvas.context2d()

  proc refreshPreview() =
    let model = htmlToRich(area.value)
    var dpr = window.getNum("devicePixelRatio")
    if dpr == 0 or dpr != dpr: dpr = 1
    let ratio = min(2.0, dpr)
    var width = preview.getNum("clientWidth")
    if width == 0: width = 600
    let height = 130.0
    previewCanvas.setProp("width", jsRound(width * ratio))
    previewCanvas.setProp("height", jsRound(height * ratio))
    previewCanvas.style("width", px(width))
    previewCanvas.style("height", px(height))
    let ctx = newCtx()
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0)
    ctx.clearRect(0, 0, width, height)
    let base = parseJson("""{"fontSize":13,"fontFamily":"Arial, sans-serif","color":"#172033","align":"left","verticalAlign":"top","wrap":true,"padding":8}""")
    discard richtext.draw(ctx, model, 0, 0, width, height, base)
    ctx.finish()
    replay(previewContext, addr ctx.buf)

  area.on("input", proc(e: Event) = refreshPreview())
  let cancel = button("Cancel")
  cancel.on("click", proc(e: Event) = backdrop.dropTree())
  let apply = button(if creating: "Insert" else: "OK", "qg-btn qg-btn-primary")
  let nodeId = if node != nil: idOf(node) else: ""
  apply.on("click", proc(e: Event) =
    let html = area.value
    let model = htmlToRich(html)
    if creating:
      let templ = nodeTemplate("html")
      templ["html"] = jstr(html)
      templ["richText"] = model
      discard ui.editor.addTemplateAtCenter(templ)
    else:
      let changes = newObj()
      changes["html"] = jstr(html)
      changes["richText"] = model
      changes["text"] = jstr(toPlain(model))
      discard gv.updateItem(nodeId, changes, "Edit HTML", true)
    backdrop.dropTree())
  let footer = div0("qg-dialog-actions")
  footer.appendChild(cancel)
  footer.appendChild(apply)
  for child in [heading, hint, area, preview, footer]: dialog.appendChild(child)
  body.appendChild(backdrop)
  area.focus()
  refreshPreview()

# ------------------------------------------------------------ SVG import --

proc insertImportedItems*(ui: EditorUi, items: seq[Val], idPrefix = "import",
                          label = "Insert", point: Val = nil): seq[Val] =
  ## Drops freshly imported items into the diagram, centred on the viewport,
  ## as one undo step. Every id is reissued and each reference between them
  ## (terminals, containers, groups, the mx round-trip record) remapped, so
  ## they never collide with what is already on the canvas.
  let gv = ui.graph
  let g = gv.g
  if items.len == 0: return
  var importedById = initTable[string, Val]()
  for item in items: importedById[idOf(item)] = item
  var minX, minY = Inf
  var maxX, maxY = -Inf
  for item in items:
    let b = itemBounds(item, importedById)
    minX = min(minX, b.x)
    minY = min(minY, b.y)
    maxX = max(maxX, b.x + b.width)
    maxY = max(maxY, b.y + b.height)
  let zoom = max(0.2, if g.zoom != 0: g.zoom else: 1.0)
  let c = gv.container
  var tx, ty: float64
  if point != nil:
    tx = num(point["x"])
    ty = num(point["y"])
  else:
    tx = (c.getNum("scrollLeft") + c.getNum("clientWidth") / 2) / zoom - g.worldOriginX
    ty = (c.getNum("scrollTop") + c.getNum("clientHeight") / 2) / zoom - g.worldOriginY
  let dx = tx - (minX + maxX) / 2
  let dy = ty - (minY + maxY) / 2

  let before = g.snapshot()
  var used = initHashSet[string]()
  for item in g.items: used.incl idOf(item)
  var idMap = initTable[string, string]()
  for index, item in items:
    let base = idPrefix & "-" & $(index + 1)
    var id = base
    var suffix = 1
    while id in used:
      inc suffix
      id = base & "-" & $suffix
    used.incl id
    idMap[idOf(item)] = id

  # Group ids live in their own namespace; an imported group whose id
  # matched one already on the canvas would silently merge the two.
  var usedGroups = initHashSet[string]()
  for item in g.items:
    if item["groups"].isArr:
      for grp in item["groups"]: usedGroups.incl str(grp)
  var groupMap = initTable[string, string]()
  proc mapGroup(grp: string): string =
    if not groupMap.hasKey(grp):
      let base = idPrefix & "-group"
      var id = base & "-1"
      var suffix = 1
      while id in usedGroups:
        inc suffix
        id = base & "-" & $suffix
      usedGroups.incl id
      groupMap[grp] = id
    groupMap[grp]
  proc offsetPoint(p: Val): Val =
    if not truthy(p): return p
    result = newObj()
    result["x"] = jnum(num(p["x"]) + dx)
    result["y"] = jnum(num(p["y"]) + dy)

  for source in items:
    let item = clone(source)
    item["id"] = jstr(idMap[idOf(source)])
    for key in ["sourceId", "targetId", "containerId"]:
      if truthy(item.get(key)) and idMap.hasKey(str(item.get(key))): item.put(key, jstr(idMap[str(item.get(key))]))
    if item["groups"].isArr and item["groups"].len > 0:
      let mapped = newArr()
      for grp in item["groups"]: mapped.push jstr(mapGroup(str(grp)))
      item["groups"] = mapped
      item["groupId"] = mapped[0]
    else:
      item.remove("groups")
      item.remove("groupId")
    if truthy(item["mx"]):
      item["mx"]["id"] = item["id"]
      let parent = item["mx"]["parent"]
      if truthy(parent) and idMap.hasKey(str(parent)): item["mx"]["parent"] = jstr(idMap[str(parent)])
    if item.eqs("type", "edge"):
      item["sourcePoint"] = offsetPoint(item["sourcePoint"])
      item["targetPoint"] = offsetPoint(item["targetPoint"])
      let previews = newArr()
      if item["previewPoints"].isArr:
        for p in item["previewPoints"]: previews.push offsetPoint(p)
      item["previewPoints"] = previews
      if item["route"].isArr:
        let route = newArr()
        for p in item["route"]: route.push offsetPoint(p)
        item["route"] = route
      result.add g.addEdge(item, false)
    else:
      item["x"] = jnum(num(item["x"]) + dx)
      item["y"] = jnum(num(item["y"]) + dy)
      result.add g.addNode(item, false)
  var ids: seq[string]
  for item in result: ids.add idOf(item)
  discard gv.call("setSelection", idsVal(ids), jtrue)
  g.commit(before, label)

proc showSvgToMxGraphDialog*(ui: EditorUi) =
  let (backdrop, dialog) = ui.dialogShell("min(760px, calc(100vw - 32px))")
  let heading = el("h2", "qg-dialog-title")
  heading.text = "SVG to mxGraph"
  let description = el("p", "qg-dialog-text")
  description.text = "Paste SVG markup or choose an SVG file. Supported elements are inserted as editable diagram objects."
  let file = createElement("input")
  file.typ = "file"
  file.setProp("accept", ".svg,image/svg+xml")
  file.style("display", "block")
  file.style("marginBottom", "10px")
  let area = el("textarea", "qg-code")
  area.setProp("placeholder", "<svg viewBox=\"0 0 300 200\">…</svg>")
  area.setProp("spellcheck", false)
  let status = createElement("div")
  status.style("minHeight", "20px")
  status.style("marginTop", "8px")
  status.style("whiteSpace", "pre-wrap")
  status.style("fontSize", "12px")

  proc inspect(): (bool, SvgResult) =
    let markup = area.value
    if jsTrim(markup).len == 0:
      status.text = "Enter SVG markup to continue."
      status.style("color", "")
      return
    try:
      let r = convert(markup)
      status.style("color", "")
      var text = jsStr(r.width) & " × " & jsStr(r.height) & " · " & $r.items.len &
        " editable object" & (if r.items.len == 1: "" else: "s")
      if r.warnings.len > 0: text.add "\nWarnings:\n• " & r.warnings.join("\n• ")
      status.text = text
      (true, r)
    except CatchableError as error:
      status.style("color", "#c62828")
      status.text = "Invalid SVG: " & error.msg
      (false, SvgResult())

  file.on("change", proc(e: Event) =
    let files = file.getNode("files")
    if files.isNil or files.getNum("length") == 0: return
    readBlob(files.invoke("item", 0).toNode, brText, proc(ok: bool, text: string) =
      if not ok:
        status.text = "Could not read the selected SVG file."
        return
      area.value = text
      discard inspect()))
  area.on("input", proc(e: Event) = discard inspect())
  let cancel = button("Cancel")
  cancel.on("click", proc(e: Event) = backdrop.dropTree())
  let insert = button("Insert into Diagram", "qg-btn qg-btn-primary")
  insert.on("click", proc(e: Event) =
    let (ok, r) = inspect()
    if not ok: return
    var list: seq[Val]
    for item in r.items: list.add item
    let created = ui.insertImportedItems(list, "svg-import", "Insert SVG")
    backdrop.dropTree()
    ui.toast("Inserted " & $created.len & " SVG object" & (if created.len == 1: "" else: "s")))
  let footer = div0("qg-dialog-actions")
  footer.appendChild(cancel)
  footer.appendChild(insert)
  for child in [heading, description, file, area, status, footer]: dialog.appendChild(child)
  body.appendChild(backdrop)
  area.focus()
  discard inspect()

proc editDiagram*(ui: EditorUi) =
  ## Whole-document editor, the canvas equivalent of Extras > Edit Diagram.
  let gv = ui.graph
  let (backdrop, dialog) = ui.dialogShell("min(760px, calc(100vw - 32px))")
  let heading = el("h2", "qg-dialog-title")
  heading.text = "Edit Diagram"
  let area = el("textarea", "qg-code")
  area.value = gv.toJSON()
  area.setProp("spellcheck", false)
  let cancel = button("Cancel")
  cancel.on("click", proc(e: Event) = backdrop.dropTree())
  let apply = button("OK", "qg-btn qg-btn-primary")
  apply.on("click", proc(e: Event) =
    try:
      gv.fromJSON(parseJson(area.value))
      backdrop.dropTree()
      ui.toast("Diagram replaced")
    except CatchableError as error:
      ui.toast("Invalid document: " & error.msg))
  let footer = div0("qg-dialog-actions")
  footer.appendChild(cancel)
  footer.appendChild(apply)
  dialog.appendChild(heading)
  dialog.appendChild(area)
  dialog.appendChild(footer)
  body.appendChild(backdrop)
  area.focus()

proc writeSelectionToSystemClipboard(ui: EditorUi) =
  ## Copy and cut also publish the selection as JSON on the system
  ## clipboard, so another editor window can receive it.
  let selection = ui.graph.getSelection()
  if selection.len == 0: return
  let payload = newObj()
  payload["type"] = jstr("pixel-graph-selection")
  payload["items"] = newArr(selection)
  clipboardWrite(toJson(payload))
