# Included from editorui.nim: the shape library -- search, category chips
# and collapsible groups of SVG tiles, plus the Saved (scratchpad) group.
# Hundreds of tiles are built through the command buffer in one flush.

const
  ScratchpadKey = "pixel-graph-scratchpad"

proc newSidebar(): Sidebar =
  # The classic inventory's palette order.
  Sidebar(thumbWidth: 36, thumbHeight: 32, thumbPadding: 0, thumbBorder: 0,
    originalPalettes: @[
      Palette(id: "general", name: "General", expanded: true, classic: "general"),
      Palette(id: "misc", name: "Misc", classic: "misc"),
      Palette(id: "advanced", name: "Advanced", classic: "advanced"),
      Palette(id: "basic", name: "Basic", stencilLibrary: "mxgraph.basic"),
      Palette(id: "arrows", name: "Arrows", stencilLibrary: "mxgraph.arrows"),
      Palette(id: "uml", name: "UML", classic: "uml"),
      Palette(id: "bpmn", name: "BPMN General", classic: "bpmn"),
      Palette(id: "flowchart", name: "Flowchart", stencilLibrary: "mxgraph.flowchart")])

proc escapeXmlValue(s: string): string =
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

proc classicTemplate(sb: Sidebar, entry: Val): Val =
  ## A diagram template from a classic mxGraph style string, through the
  ## same importer that reads .qochart, so a palette shape and the same
  ## shape loaded from a document share one mapping. Cached per entry.
  let extra = entry["extra"]
  let key = valStr(entry["kind"]) & "|" & valStr(entry["style"]) & "|" & valStr(entry["width"]) & "x" &
    valStr(entry["height"]) & "|" & valStr(entry["value"]) & "|" & valStr(entry["xml"]) &
    "|" & (if truthy(extra): toJson(extra) else: "") &
    "|" & (if truthy(entry["processBar"]): "processBar" else: "") &
    "|" & (if truthy(entry["listTemplate"]): "list" else: "") &
    "|" & (if truthy(entry["containerTemplate"]): "container" else: "") &
    "|" & (if truthy(entry["listItemTemplate"]): "listItem" else: "") &
    "|" & valStr(entry["titledTable"])
  if sb.classicCache.hasKey(key): return sb.classicCache[key]
  var templ: Val = nil

  # Entries stored as a whole diagram (pools, cross-functional flowcharts,
  # tables, UML class stacks): import it and rebuild the parent/child
  # nesting as a template tree, so one drop recreates the whole group.
  if truthy(entry["xml"]):
    try:
      var documentItems: seq[Val]
      for item in importLegacyGraph(str(entry["xml"]))["items"]:
        let copy = clone(item)
        for name in ["z", "layer", "groups", "groupId", "mx"]: copy.remove(name)
        documentItems.add copy
      var roots: seq[Val]
      var byParent = initTable[string, seq[Val]]()
      for item in documentItems:
        if not truthy(item["containerId"]): roots.add item
        else: byParent.mgetOrPut(str(item["containerId"]), @[]).add item
      if roots.len > 0:
        proc nest(item: Val): Val =
          let kids = byParent.getOrDefault(idOf(item), @[])
          if kids.len > 0:
            let children = newArr()
            for kid in kids:
              kid["x"] = jnum(num(kid["x"]) - num(item["x"]))
              kid["y"] = jnum(num(kid["y"]) - num(item["y"]))
              children.push nest(kid)
            item["children"] = children
          item.remove("containerId")
          item.remove("id")
          item
        templ = nest(roots[0])
        templ["x"] = jnum(0)
        templ["y"] = jnum(0)
        if truthy(extra):
          for (k, v) in extra.pairs: templ.put(k, clone(v))
    except CatchableError:
      templ = nil
    sb.classicCache[key] = templ
    return templ

  let value = escapeXmlValue(valStr(entry["value"]))
  let style = valStr(entry["style"]).replace("\"", "&quot;")
  let width = valStr(entry["width"])
  let height = valStr(entry["height"])
  let isEdge = entry.eqs("kind", "edge")
  let cell = if isEdge:
      "<mxCell id=\"t\" value=\"" & value & "\" style=\"" & style & "\" edge=\"1\" parent=\"1\">" &
      "<mxGeometry relative=\"1\" as=\"geometry\">" &
      "<mxPoint x=\"0\" y=\"0\" as=\"sourcePoint\"/>" &
      "<mxPoint x=\"" & width & "\" y=\"" & height & "\" as=\"targetPoint\"/>" &
      "</mxGeometry></mxCell>"
    else:
      "<mxCell id=\"t\" value=\"" & value & "\" style=\"" & style & "\" vertex=\"1\" parent=\"1\">" &
      "<mxGeometry x=\"0\" y=\"0\" width=\"" & width & "\" height=\"" & height &
      "\" as=\"geometry\"/></mxCell>"
  try:
    let scene = importLegacyGraph("<mxGraphModel><root><mxCell id=\"0\"/>" &
      "<mxCell id=\"1\" parent=\"0\"/>" & cell & "</root></mxGraphModel>")
    let items = scene["items"]
    if items.isArr and items.len > 0:
      templ = clone(items[0])
      for name in ["id", "z", "mx", "layer", "groups", "groupId"]: templ.remove(name)
      if isEdge:
        templ["type"] = jstr("edge")
        templ.remove("sourceId")
        templ.remove("targetId")
      elif truthy(entry["processBar"]):
        templ["shape"] = jstr("text")
        templ["fill"] = jstr("transparent")
        templ["stroke"] = jstr("transparent")
        templ["strokeWidth"] = jnum(0)
        templ["text"] = jstr("Process Bar")
        templ["verticalAlign"] = jstr("top")
        templ["children"] = parseJson("""[
          {"shape":"step","text":"Step 1","x":10,"y":33,"width":100,"height":57},
          {"shape":"step","text":"Step 2","x":98,"y":33,"width":100,"height":57},
          {"shape":"step","text":"Step 3","x":186,"y":33,"width":100,"height":57}]""")
      elif truthy(entry["listTemplate"]):
        templ["kind"] = jstr("list")
        templ["container"] = jtrue
        templ["containerRole"] = jstr("list")
        templ["collapsible"] = jtrue
        templ["fill"] = jstr("transparent")
        let children = newArr()
        for index, label in ["Item 1", "Item 2", "Item 3"]:
          let child = parseJson("""{"kind":"listItem","shape":"text"}""")
          child["text"] = jstr(label)
          child["x"] = jnum(0)
          child["y"] = jnum(26 + index * 26)
          for (k, v) in parseJson("""{"width":140,"height":26,"fill":"transparent","stroke":"transparent","strokeWidth":0,"textAlign":"left","verticalAlign":"top","textPadding":4,"rotatable":false}""").pairs:
            child.put(k, v)
          children.push child
        templ["children"] = children
      elif truthy(entry["containerTemplate"]):
        templ["kind"] = jstr("container")
        templ["container"] = jtrue
        templ["containerRole"] = jstr("container")
        templ["collapsible"] = jtrue
        if nullish(templ["headerHeight"]): templ["headerHeight"] = jnum(26)
      elif truthy(entry["listItemTemplate"]):
        templ["kind"] = jstr("listItem")
        templ["container"] = jfalse
      elif truthy(entry["titledTable"]):
        let second = num(entry["titledTable"]) == 2
        templ = parseJson("""{"type":"node","kind":"table","shape":"table","sourceType":"htmlTable",
          "width":180,"height":150,"fill":"#ffffff","stroke":"#4a5564",
          "strokeWidth":1,"radius":0,"text":"","tableTitle":"Table",
          "tableTitleHeight":30,"tableBorder":1,"gridStroke":"#4a5564",
          "fontSize":11,"fontFamily":"Arial, Helvetica, sans-serif",
          "fontWeight":400,"textColor":"#172033"}""")
        templ["cellAlign"] = jstr(if second: "left" else: "center")
        templ["rows"] = jnum(3)
        templ["columns"] = jnum(if second: 2 else: 3)
        templ["rowWeights"] = parseJson(if second: "[30,30,30]" else: "[40,40,40]")
        templ["columnWeights"] = parseJson(if second: "[40,140]" else: "[60,60,60]")
        templ["fixedRows"] = jbool(second)
        templ["rowLines"] = jbool(not second)
        templ["firstRowLine"] = jbool(second)
        templ["reorderRows"] = jtrue
        templ["rowIndexColumn"] = if second: jnum(0) else: jnull
        templ["cells"] = if second: parseJson("""{"0,0":{"text":"1","align":"center"},
          "0,1":{"text":"Value 1","align":"left"},"1,0":{"text":"2","align":"center"},
          "1,1":{"text":"Value 2","align":"left"},"2,0":{"text":"3","align":"center"},
          "2,1":{"text":"Value 3","align":"left"}}""") else: newObj()
      # Properties no style string can carry (connector end labels, a link):
      # applied after the chain above, since an edge entry always takes the
      # edge arm.
      if truthy(extra):
        for (k, v) in extra.pairs: templ.put(k, clone(v))
  except CatchableError:
    templ = nil
  sb.classicCache[key] = templ
  templ

proc createThumb(sb: Sidebar, shapeName: string, custom: Val, previewSource: Val): Node =
  ## Library tiles are SVG previews: sharp at any pixel density.
  let templ = if custom != nil: custom else: nodeTemplate(shapeName)
  if templ != nil:
    let svg = preview(templ, sb.thumbWidth, sb.thumbHeight, previewSource)
    if not svg.isNil:
      svg.setAttribute("class", "qg-shape-svg")
      return svg
  result = div0("qg-shape-text")
  result.text = if templ != nil and truthy(templ["text"]): str(templ["text"])
                elif templ != nil and truthy(templ["shape"]): str(templ["shape"]) else: "Shape"

proc loadScratchpad(): seq[Val] =
  let (found, text) = storageGet(ScratchpadKey)
  if not found: return
  try:
    let stored = parseJson(if text.len > 0: text else: "[]")
    if stored.isArr:
      for entry in stored: result.add entry
  except JsonError: discard

proc saveScratchpad(ui: EditorUi, list: seq[Val]) =
  if not storageSet(ScratchpadKey, toJson(newArr(list))):
    ui.toast("Your browser storage is full: remove a block and try again")

proc renderScratchpad(ui: EditorUi)

proc stripTags(s: string): string =
  var inTag = false
  for c in s:
    if c == '<': inTag = true
    elif c == '>' and inTag: inTag = false
    elif not inTag: result.add c

proc shortName(label: string): string =
  ## Up to 24 UTF-16 units of the label, whole characters only.
  result = jsTrim(stripTags(label))
  var units = 0
  var cut = result.len
  var i = 0
  while i < result.len:
    let c = ord(result[i])
    let width = if c < 0x80: 1 elif c < 0xE0: 2 elif c < 0xF0: 3 else: 4
    let u = if width == 4: 2 else: 1
    if units + u > 24:
      cut = i
      break
    units += u
    i += width
  result.setLen(min(cut, result.len))

proc blockThumb(items: seq[Val]): string =
  ## A painted PNG preview of a block, drawn by the scene painter itself.
  if items.len == 0: return ""
  var scene = initTable[string, Val]()
  for it in items: scene[idOf(it)] = it
  var minX, minY = Inf
  var maxX, maxY = -Inf
  for it in items:
    let b = itemBounds(it, scene)
    minX = min(minX, b.x)
    minY = min(minY, b.y)
    maxX = max(maxX, b.x + b.width)
    maxY = max(maxY, b.y + b.height)
  if minX > maxX: return ""
  const width = 112.0
  const height = 84.0
  const pad = 8.0
  let bw = max(1.0, maxX - minX)
  let bh = max(1.0, maxY - minY)
  let scale = min(2.0, min((width - pad * 2) / bw, (height - pad * 2) / bh))
  let p = newScenePainter()
  p.sync(items)
  let canvas = createElement("canvas")
  var surface = newSurface(canvas)
  let view = newObj()
  view["zoom"] = jnum(scale)
  view["dpr"] = jnum(2)
  view["width"] = jnum(width)
  view["height"] = jnum(height)
  view["scrollX"] = jnum(minX * scale - (width - bw * scale) / 2)
  view["scrollY"] = jnum(minY * scale - (height - bh * scale) / 2)
  view["background"] = jstr("#ffffff")
  view["grid"] = jfalse
  view["pageView"] = jfalse
  discard p.paint(surface, view)
  result = canvas.invoke("toDataURL", "image/png").toStr
  release(surface.ctx)
  release(canvas)

proc templateItem(templ: Val): Val =
  ## A single template as a scene item, for its thumbnail.
  result = clone(templ)
  result["id"] = jstr("block-preview")
  if not result.eqs("type", "edge"): result["type"] = jstr("node")
  result["x"] = jnum(0)
  result["y"] = jnum(0)
  result.remove("children")

proc selectionFragment(ui: EditorUi): seq[Val] =
  ## The selection, plus whatever sits inside selected containers and the
  ## connectors running between selected shapes.
  let g = ui.graph.g
  var ids = initHashSet[string]()
  for item in g.getSelection(): ids.incl idOf(item)
  var grew = true
  while grew:
    grew = false
    for item in g.items:
      let id = idOf(item)
      if id in ids: continue
      let parent = strOrEmpty(item["containerId"])
      let bothEnds = item.eqs("type", "edge") and strOrEmpty(item["sourceId"]) in ids and
        strOrEmpty(item["targetId"]) in ids
      if (parent.len > 0 and parent in ids) or bothEnds:
        ids.incl id
        grew = true
  for item in g.items:
    if idOf(item) in ids: result.add clone(item)

proc storeBlock(ui: EditorUi, name: string, data: Val, items: seq[Val]) =
  let record = newObj()
  record["name"] = jstr(if name.len > 0: name else: "Block")
  if data != nil: record["data"] = data
  if items.len > 0: record["items"] = newArr(items)
  let thumb = if items.len > 0: blockThumb(items) else: blockThumb(@[templateItem(data)])
  if thumb.len > 0: record["thumb"] = jstr(thumb)
  var list = loadScratchpad()
  list.add record
  ui.saveScratchpad(list)
  ui.renderScratchpad()
  if ui.sidebar.blocksSection != nil: ui.sidebar.blocksSection.outer.addClass("is-open")
  ui.toast("Saved “" & valStr(record["name"]) & "” to My Blocks")

proc addToScratchpad(ui: EditorUi, node: Val = nil) =
  ## Saves a template (a dropped library tile) or the current selection as a
  ## reusable block.
  if node != nil:
    let entry = clone(node)
    for key in ["id", "x", "y", "z", "groups", "groupId", "layer", "foldedAway", "foldedBy"]:
      entry.remove(key)
    let label = if truthy(node["text"]): str(node["text"])
                elif truthy(node["shape"]): str(node["shape"]) else: "Shape"
    ui.storeBlock(shortName(label), entry, @[])
    return
  let fragment = ui.selectionFragment()
  if fragment.len == 0:
    ui.toast("Select shapes on the canvas, then save them as a block")
    return
  let first = fragment[0]
  let suggested = shortName(if truthy(first["text"]): str(first["text"])
                            elif truthy(first["shape"]): str(first["shape"]) else: "Block")
  let (ok, typed) = prompt("Name this block", if suggested.len > 0: suggested else: "Block")
  if not ok: return
  let name = shortName(typed)
  if fragment.len == 1 and not first.eqs("type", "edge"):
    let entry = clone(first)
    for key in ["id", "x", "y", "z", "groups", "groupId", "layer", "foldedAway", "foldedBy",
                "containerId"]:
      entry.remove(key)
    ui.storeBlock(name, entry, @[])
    return
  # Several items: keep them together as one group when inserted.
  var shared = ""
  var common = true
  for item in fragment:
    let groups = item["groups"]
    let top = if groups.isArr and groups.len > 0: str(groups[groups.len - 1]) else: ""
    if shared.len == 0 and top.len > 0: shared = top
    if top.len == 0 or top != shared: common = false
  if not common:
    for item in fragment:
      let groups = if item["groups"].isArr: item["groups"] else: newArr()
      groups.push jstr("block-group")
      item["groups"] = groups
      item["groupId"] = groups[0]
  for item in fragment:
    item.remove("layer")
    item.remove("z")
  ui.storeBlock(name, nil, fragment)

proc removeScratchpad(ui: EditorUi, index: int) =
  var list = loadScratchpad()
  if index < 0 or index >= list.len: return
  list.delete(index)
  ui.saveScratchpad(list)
  ui.renderScratchpad()

proc insertBlockJson(ui: EditorUi, json: string, point: Val = nil) =
  ## Inserts a multi-item block, centred on `point` or the viewport.
  var items: seq[Val]
  try:
    for item in parseJson(json): items.add item
  except JsonError: return
  if items.len == 0: return
  discard ui.insertImportedItems(items, "block", "Insert Block", point)

proc exportBlocks(ui: EditorUi) =
  let list = loadScratchpad()
  if list.len == 0:
    ui.toast("My Blocks is empty")
    return
  let payload = newObj()
  payload["type"] = jstr("qgraph-blocks")
  payload["version"] = jnum(1)
  payload["blocks"] = newArr(list)
  ui.editor.downloadText(toJsonPretty(payload, 2), "qgraph-blocks.json", "application/json")

proc importBlocks(ui: EditorUi, text: string) =
  var incoming: seq[Val]
  try:
    let parsed = parseJson(text)
    let source = if parsed.isArr: parsed elif parsed.isObj and parsed["blocks"].isArr: parsed["blocks"] else: nil
    if source != nil:
      for entry in source:
        if entry.isObj and (entry["data"].isObj or entry["items"].isArr): incoming.add entry
  except JsonError:
    ui.toast("That file is not a QGraph block library")
    return
  if incoming.len == 0:
    ui.toast("No blocks found in that file")
    return
  var list = loadScratchpad()
  for entry in incoming:
    if not truthy(entry["thumb"]):
      var items: seq[Val]
      if entry["items"].isArr:
        for it in entry["items"]: items.add it
      else: items.add templateItem(entry["data"])
      let thumb = blockThumb(items)
      if thumb.len > 0: entry["thumb"] = jstr(thumb)
    list.add entry
  ui.saveScratchpad(list)
  ui.renderScratchpad()
  ui.toast("Imported " & $incoming.len & " block" & (if incoming.len == 1: "" else: "s"))

proc replaceSelectionShape(ui: EditorUi, templ: Val, title: string) =
  ## The classic Shift-click on a palette entry: change what the selected
  ## objects are drawn as, keeping position, size, colours and labels.
  let gv = ui.graph
  if templ == nil: return
  let selection = gv.getSelection()
  if selection.len == 0:
    ui.toast("Select something first to change its shape")
    return
  let replaced = gv.call("replaceShape", newArr(selection), templ)
  if replaced.len == 0:
    ui.toast(if templ.eqs("type", "edge"): "Select a connector to change it" else: "Select a shape to change it")
    return
  ui.toast("Changed " & $replaced.len & " object" & (if replaced.len == 1: "" else: "s") &
    " to " & (if title.len > 0: title else: "the selected shape"))

proc createItem(ui: EditorUi, shapeName, title: string, custom: Val, previewSource: Val = nil,
                scratchpadItem = false): Node =
  let sb = ui.sidebar
  let elt = el("button", "qg-shape")
  elt.typ = "button"
  elt.setAttribute("title", title & " — Shift+click changes the selected shapes" &
    (if scratchpadItem: "; right-click removes it from Saved" else: ""))
  elt.setAttribute("aria-label", title)
  if shapeName.len > 0: elt.setData("shape", shapeName)
  elt.setData("search", title.toLowerAscii())
  elt.setProp("draggable", true)
  elt.appendChild(sb.createThumb(shapeName, custom, previewSource))
  let customJson = if custom != nil: toJson(custom) else: ""
  elt.on("dragstart", proc(e: Event) =
    let dt = e.dataTransfer
    if customJson.len > 0: dt.call("setData", "application/x-pixel-shape-data", customJson)
    else: dt.call("setData", "application/x-pixel-shape", shapeName)
    dt.setProp("effectAllowed", "copy"))
  elt.on("click", proc(e: Event) =
    e.preventDefault()
    if e.shiftKey:
      ui.replaceSelectionShape(if customJson.len > 0: parseJson(customJson) else: nodeTemplate(shapeName), title)
    elif customJson.len > 0:
      discard ui.editor.addTemplateAtCenter(parseJson(customJson))
    else:
      discard ui.editor.addAtCenter(shapeName)
    # On a phone the sheet covers the canvas: show the new shape.
    if ui.layout == lmPhone and not e.shiftKey: ui.closeSheet())
  elt

proc blockTile(ui: EditorUi, entry: Val, index: int): Node =
  ## A custom block: painted thumbnail, name and a remove button.
  let name = valStr(entry["name"])
  let tile = div0("qg-block")
  tile.setData("search", name.toLowerAscii())
  let main = el("button", "qg-shape qg-block-main")
  main.typ = "button"
  main.setAttribute("title", name & " — click to insert, drag onto the canvas; right-click to remove")
  main.setAttribute("aria-label", name)
  main.setProp("draggable", true)
  if truthy(entry["thumb"]):
    let img = el("img", "qg-block-thumb")
    img.setAttribute("alt", "")
    img.setAttribute("draggable", "false")
    img.setProp("src", str(entry["thumb"]))
    main.appendChild(img)
  elif entry["data"].isObj:
    main.appendChild(ui.sidebar.createThumb("", entry["data"], nil))
  let label = el("span", "qg-block-name")
  label.text = name
  main.appendChild(label)
  let isFragment = entry["items"].isArr
  let payload = if isFragment: toJson(entry["items"]) elif entry["data"].isObj: toJson(entry["data"]) else: ""
  main.on("dragstart", proc(e: Event) =
    let dt = e.dataTransfer
    dt.call("setData", if isFragment: "application/x-qgraph-block" else: "application/x-pixel-shape-data", payload)
    dt.setProp("effectAllowed", "copy"))
  main.on("click", proc(e: Event) =
    e.preventDefault()
    if payload.len == 0: return
    if isFragment: ui.insertBlockJson(payload)
    elif e.shiftKey: ui.replaceSelectionShape(parseJson(payload), name)
    else: discard ui.editor.addTemplateAtCenter(parseJson(payload))
    if ui.layout == lmPhone and not e.shiftKey: ui.closeSheet())
  main.on("contextmenu", proc(e: Event) =
    e.preventDefault()
    ui.removeScratchpad(index))
  let remove = iconButton("close", "Remove “" & name & "”", "qg-block-remove")
  remove.on("click", proc(e: Event) =
    e.stopPropagation()
    ui.removeScratchpad(index))
  tile.appendChild(main)
  tile.appendChild(remove)
  tile

proc renderScratchpad(ui: EditorUi) =
  let list = loadScratchpad()
  let section = ui.sidebar.blocksSection
  if section != nil: section.items.setLen(0)
  for panel in ui.sidebar.scratchpadBodies:
    panel.dropChildren()
    for index, entry in list:
      let tile = ui.blockTile(entry, index)
      panel.appendChild(tile)
      if section != nil: section.items.add tile
    let drop = el("button", "qg-dropzone")
    drop.typ = "button"
    drop.setAttribute("title", "Drop a shape here, or click to save the selection")
    drop.on("click", proc(e: Event) = ui.addToScratchpad())
    drop.appendChild(icon("plus", 18))
    let t = createElement("span")
    t.text = if list.len == 0: "Drop a shape here, or select shapes and tap to save them"
             else: "Drop or tap to add the selection"
    drop.appendChild(t)
    panel.appendChild(drop)

proc newSection(ui: EditorUi, parent: Node, key, name: string, expanded: bool,
                palette: Palette): Section =
  ## A collapsible group of shape tiles.
  let outer = el("section", "qg-lib-section" & (if expanded: " is-open" else: ""))
  outer.setData("section", key)
  let title = el("button", "qg-lib-head")
  title.typ = "button"
  title.appendChild(icon("chevronRight", 16))
  let t = el("span", "qg-lib-name")
  t.text = name
  title.appendChild(t)
  let grid = div0("qg-shape-grid")
  outer.appendChild(title)
  outer.appendChild(grid)
  parent.appendChild(outer)
  title.on("click", proc(e: Event) = outer.toggleClass("is-open", not outer.matches(".is-open")))
  result = Section(title: title, outer: outer, body: grid, palette: palette)
  ui.sidebar.sections.add result

proc createScratchpad(ui: EditorUi, parent: Node) =
  ## My Blocks: the user's own reusable shapes and multi-shape blocks.
  let section = ui.newSection(parent, "saved", "My Blocks", true, Palette(id: "saved", name: "My Blocks"))
  ui.sidebar.blocksSection = section
  section.outer.addClass("qg-blocks")
  let actions = div0("qg-block-actions")
  let save = textButton("Save selection", "qg-btn qg-btn-primary qg-btn-sm", "star")
  save.setAttribute("title", "Save the selected shapes as a reusable block")
  save.on("click", proc(e: Event) = ui.addToScratchpad())
  let importButton = iconButton("folder", "Import blocks from a file")
  let exportButton = iconButton("download", "Export My Blocks to a file")
  let picker = createElement("input")
  picker.typ = "file"
  picker.setProp("accept", ".json,application/json")
  picker.hidden = true
  importButton.on("click", proc(e: Event) = picker.click())
  picker.on("change", proc(e: Event) =
    let files = picker.getNode("files")
    if files.isNil or files.getNum("length") == 0: return
    readBlob(files.invoke("item", 0).toNode, brText, proc(ok: bool, text: string) =
      if ok: ui.importBlocks(text))
    picker.value = "")
  exportButton.on("click", proc(e: Event) = ui.exportBlocks())
  actions.appendChild(save)
  actions.appendChild(importButton)
  actions.appendChild(exportButton)
  actions.appendChild(picker)
  section.outer.insertBefore(actions, section.body)
  let content = section.body
  content.addClass("qg-scratchpad")
  ui.sidebar.scratchpadBodies.add content
  content.on("dragover", proc(e: Event) =
    e.preventDefault()
    content.addClass("is-drop-target"))
  content.on("dragleave", proc(e: Event) = content.removeClass("is-drop-target"))
  content.on("drop", proc(e: Event) =
    e.preventDefault()
    content.removeClass("is-drop-target")
    let dt = e.dataTransfer
    let shape = dt.invoke("getData", "application/x-pixel-shape").toStr
    let payload = dt.invoke("getData", "application/x-pixel-shape-data").toStr
    if payload.len > 0:
      try: ui.addToScratchpad(parseJson(payload))
      except JsonError: discard
    elif shape.len > 0: ui.addToScratchpad(nodeTemplate(shape))
    else: ui.addToScratchpad())

proc filterLibrary(ui: EditorUi, query: string, category: string) =
  for section in ui.sidebar.sections:
    let inCategory = category == "all" or section.palette.id == category
    var matched = 0
    for item in section.items:
      let hit = query.len == 0 or item.get2("dataset", "search").toStr.contains(query)
      item.hidden = not hit
      if hit: inc matched
    # My Blocks stays visible while searching: it is also the drop target.
    let visible = inCategory and (query.len == 0 or matched > 0 or section.palette.id == "saved")
    section.outer.hidden = not visible
    if visible and (query.len > 0 or category != "all"): section.outer.addClass("is-open")

proc addPalette(ui: EditorUi, parent: Node, palette: Palette) =
  let sb = ui.sidebar
  let section = ui.newSection(parent, palette.id, palette.name, palette.expanded, palette)
  if palette.stencilLibrary.len > 0: sb.stencilHosts[palette.stencilLibrary.toLowerAscii()] = section
  if palette.classic.len > 0:
    # A classic palette carries its shapes as mxGraph styles.
    let source = classicPalette().get(palette.classic)
    if source.isArr:
      for entry in source:
        let templ = sb.classicTemplate(entry)
        if templ == nil: continue
        let item = ui.createItem("", valStr(entry["title"]), templ, entry)
        section.body.appendChild(item)
        section.items.add item

proc addStencilPalettes(ui: EditorUi) =
  let sb = ui.sidebar
  for library, shapes in libraries:
    let key = library.toLowerAscii()
    let host = sb.stencilHosts.getOrDefault(key, nil)
    if host == nil: continue
    var already = sb.loadedStencils.getOrDefault(key, initHashSet[string]())
    for shape in shapes:
      let shapeKey = str(shape["key"])
      if shapeKey in already: continue
      already.incl shapeKey
      let templ = newObj()
      templ["shape"] = jstr("stencil")
      templ["stencil"] = jstr(shapeKey)
      templ["text"] = jstr("")
      templ["width"] = jnum(max(60.0, jsRound(num(shape["w"]))))
      templ["height"] = jnum(max(40.0, jsRound(num(shape["h"]))))
      templ["fill"] = jstr("#ffffff")
      templ["stroke"] = jstr(if key == "mxgraph.basic": "#000000" else: "#4a5564")
      templ["strokeWidth"] = jnum(if key == "mxgraph.basic": 2.0 else: 1.5)
      let name = valStr(shape["name"])
      let item = ui.createItem("", name, templ)
      # Stencil entries keep only their name as the tooltip.
      item.setAttribute("title", name)
      host.body.appendChild(item)
      host.items.add item
    if key == "mxgraph.basic" and "__partialRectangles" notin already:
      already.incl "__partialRectangles"
      for sides in ["""{"top":false,"bottom":false}""", """{"right":false,"top":false,"bottom":false}""",
                    """{"bottom":false,"right":false}""", """{"top":false,"left":false}"""]:
        let templ = parseJson("""{"shape":"partialRectangle","text":"","width":120,"height":60,"fill":"transparent","stroke":"#000000","strokeWidth":1}""")
        for (k, v) in parseJson(sides).pairs: templ.put(k, v)
        let item = ui.createItem("", "Partial Rectangle", templ)
        host.body.appendChild(item)
        host.items.add item
    sb.loadedStencils[key] = already

proc buildSidebar(ui: EditorUi) =
  let sb = ui.sidebar
  let (root, content) = panel("Shapes", "library", proc() =
    if ui.layout == lmPhone: ui.closeSheet() else: ui.togglePane("sidebar"))
  ui.libraryPanel = root
  sb.container = root
  sb.originalPanel = content

  let searchWrap = div0("qg-search")
  searchWrap.appendChild(icon("search", 18))
  let search = el("input", "qg-search-input")
  search.typ = "search"
  search.setProp("placeholder", "Search shapes")
  search.setAttribute("aria-label", "Search shapes")
  searchWrap.appendChild(search)
  content.appendChild(searchWrap)

  let chips = div0("qg-chips")
  content.appendChild(chips)
  var category = "all"
  var chipNodes: seq[(string, Node)]
  proc addChip(key, label: string) =
    let c = chip(label, key == "all")
    c.setData("category", key)
    c.on("click", proc(e: Event) =
      category = key
      for (k, n) in chipNodes: n.toggleClass("is-active", k == key)
      ui.filterLibrary(jsTrim(search.value).toLowerAscii(), category))
    chipNodes.add (key, c)
    chips.appendChild(c)
  addChip("all", "All")
  addChip("saved", "My blocks")
  for palette in sb.originalPalettes: addChip(palette.id, palette.name)

  let sections = div0("qg-lib-sections")
  content.appendChild(sections)
  ui.createScratchpad(sections)
  for palette in sb.originalPalettes: ui.addPalette(sections, palette)
  sb.setCategory = proc(key: string) =
    category = key
    for (k, n) in chipNodes: n.toggleClass("is-active", k == key)
    ui.filterLibrary(jsTrim(search.value).toLowerAscii(), category)
  search.on("input", proc(e: Event) =
    ui.filterLibrary(jsTrim(search.value).toLowerAscii(), category))
  ui.leftDock.appendChild(root)
  ui.renderScratchpad()
  ui.addStencilPalettes()
