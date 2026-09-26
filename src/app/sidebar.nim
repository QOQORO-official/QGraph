# Included from editorui.nim: the classic shape sidebar (Sidebar.js).
#
# The DOM follows the classic GraphEditor sidebar: tabs, collapsible
# palettes, search and a scratchpad. Thumbnails are SVG built through the
# command buffer, so hundreds of them cost a single flush.

const
  ScratchpadKey = "pixel-graph-scratchpad"

let
  CollapsedImage = "data:image/svg+xml;utf8," & encodeURIComponent(
    "<svg xmlns='http://www.w3.org/2000/svg' width='13' height='13'><path fill='#999999' d='M4 3 L9 6.5 L4 10 Z'/></svg>")
  ExpandedImage = "data:image/svg+xml;utf8," & encodeURIComponent(
    "<svg xmlns='http://www.w3.org/2000/svg' width='13' height='13'><path fill='#999999' d='M3 4 L10 4 L6.5 9 Z'/></svg>")

proc newSidebar(): Sidebar =
  # The classic GraphEditor compact inventory dimensions and palette order.
  Sidebar(thumbWidth: 32, thumbHeight: 30, thumbPadding: 1, thumbBorder: 1,
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
  ## Palette previews are SVG: sharp at any device pixel ratio, with HTML
  ## labels in foreignObjects as in the classic inventory.
  let templ = if custom != nil: custom else: nodeTemplate(shapeName)
  if templ != nil:
    let svg = preview(templ, sb.thumbWidth, sb.thumbHeight, previewSource)
    if not svg.isNil:
      svg.setAttribute("class", "geShapeSvg")
      return svg
  # Unknown entries get a small ordinary HTML preview.
  result = div0("geShapeHtml")
  result.text = if templ != nil and truthy(templ["text"]): str(templ["text"])
                elif templ != nil and truthy(templ["shape"]): str(templ["shape"]) else: "Shape"
  result.style("width", px(sb.thumbWidth))
  result.style("height", px(sb.thumbHeight))

proc loadScratchpad(): seq[Val] =
  let (found, text) = storageGet(ScratchpadKey)
  if not found: return
  try:
    let stored = parseJson(if text.len > 0: text else: "[]")
    if stored.isArr:
      for entry in stored: result.add entry
  except JsonError: discard

proc saveScratchpad(ui: EditorUi, list: seq[Val]) =
  if not storageSet(ScratchpadKey, toJson(newArr(list))): ui.toast("Scratchpad is full")

proc renderScratchpad(ui: EditorUi)

proc stripTags(s: string): string =
  var inTag = false
  for c in s:
    if c == '<': inTag = true
    elif c == '>' and inTag: inTag = false
    elif not inTag: result.add c

proc addToScratchpad(ui: EditorUi, node: Val = nil) =
  var source = node
  if source == nil:
    for item in ui.graph.getSelection():
      if nodesOnly(item):
        source = item
        break
  if source == nil:
    ui.toast("Select a shape to add to the scratchpad")
    return
  let entry = clone(source)
  for key in ["id", "x", "y", "z", "groups", "groupId", "layer", "foldedAway", "foldedBy"]:
    entry.remove(key)
  var list = loadScratchpad()
  let label = if truthy(source["text"]): str(source["text"])
              elif truthy(source["shape"]): str(source["shape"]) else: "Shape"
  var name = stripTags(label)
  # String.slice(0, 24) counts UTF-16 units; keep whole characters.
  var units = 0
  var cut = name.len
  var i = 0
  while i < name.len:
    let c = ord(name[i])
    let width = if c < 0x80: 1 elif c < 0xE0: 2 elif c < 0xF0: 3 else: 4
    let u = if width == 4: 2 else: 1
    if units + u > 24:
      cut = i
      break
    units += u
    i += width
  name.setLen(min(cut, name.len))
  let record = newObj()
  record["name"] = jstr(name)
  record["data"] = entry
  list.add record
  ui.saveScratchpad(list)
  ui.renderScratchpad()
  ui.toast("Added to scratchpad")

proc removeScratchpad(ui: EditorUi, index: int) =
  var list = loadScratchpad()
  if index < 0 or index >= list.len: return
  list.delete(index)
  ui.saveScratchpad(list)
  ui.renderScratchpad()

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
  let elt = el("a", "geItem")
  elt.setAttribute("title", title & " — Shift+click to change the shape of the selection" &
    (if scratchpadItem: ", right-click to remove from Scratchpad" else: ""))
  if shapeName.len > 0: elt.setData("shape", shapeName)
  elt.setData("search", title.toLowerAscii())
  elt.style("overflow", "hidden")
  elt.style("width", px(sb.thumbWidth + 2 * sb.thumbBorder))
  elt.style("height", px(sb.thumbHeight + 2 * sb.thumbBorder))
  elt.style("padding", px(sb.thumbPadding))
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
      discard ui.editor.addAtCenter(shapeName))
  elt

proc renderScratchpad(ui: EditorUi) =
  let list = loadScratchpad()
  for panel in ui.sidebar.scratchpadBodies:
    panel.dropChildren()
    if list.len == 0:
      let empty = div0("geDropTarget")
      empty.text = "Drop a shape here to reuse it"
      panel.appendChild(empty)
      continue
    for index, entry in list:
      let i = index
      let item = ui.createItem("", valStr(entry["name"]), entry["data"], nil, true)
      item.on("contextmenu", proc(e: Event) =
        e.preventDefault()
        ui.removeScratchpad(i))
      panel.appendChild(item)

proc createTitle(label: string): Node =
  result = el("a", "geTitle")
  result.text = label
  result.style("backgroundRepeat", "no-repeat")
  result.style("backgroundPosition", "0% 50%")

proc addFoldingHandler(title, content: Node, expanded: bool) =
  var open = expanded
  proc sync() =
    title.style("backgroundImage", "url('" & (if open: ExpandedImage else: CollapsedImage) & "')")
  sync()
  title.on("click", proc(e: Event) =
    open = content.get2("style", "display").toStr == "none"
    content.style("display", if open: "block" else: "none")
    sync())

proc createScratchpad(ui: EditorUi, panel: Node) =
  let title = createTitle("Scratchpad")
  let content = div0("geSidebar geScratchpadPalette")
  content.style("touchAction", "none")
  panel.appendChild(title)
  let outer = createElement("div")
  outer.appendChild(content)
  panel.appendChild(outer)
  addFoldingHandler(title, content, true)
  ui.sidebar.scratchpadBodies.add content
  content.on("dragover", proc(e: Event) =
    e.preventDefault()
    content.addClass("geSidebarDropActive"))
  content.on("dragleave", proc(e: Event) = content.removeClass("geSidebarDropActive"))
  content.on("drop", proc(e: Event) =
    e.preventDefault()
    content.removeClass("geSidebarDropActive")
    let dt = e.dataTransfer
    let shape = dt.invoke("getData", "application/x-pixel-shape").toStr
    let payload = dt.invoke("getData", "application/x-pixel-shape-data").toStr
    if payload.len > 0:
      try: ui.addToScratchpad(parseJson(payload))
      except JsonError: discard
    elif shape.len > 0: ui.addToScratchpad(nodeTemplate(shape))
    else: ui.addToScratchpad())

proc createSearch(ui: EditorUi, panel: Node) =
  let wrap = div0("geSearchWrap")
  let search = el("input", "geSearchBox")
  search.typ = "search"
  search.setProp("placeholder", "Search Shapes")
  wrap.appendChild(search)
  panel.appendChild(wrap)
  search.on("input", proc(e: Event) =
    let query = jsTrim(search.value).toLowerAscii()
    for section in ui.sidebar.sections:
      var matched = 0
      for item in section.items:
        let hit = query.len == 0 or item.get2("dataset", "search").toStr.contains(query)
        item.hidden = not hit
        if hit: inc matched
      let visible = query.len == 0 or matched > 0
      section.title.hidden = not visible
      section.outer.hidden = not visible
      if query.len > 0 and visible: section.body.style("display", "block"))

proc addPalette(ui: EditorUi, panel: Node, palette: Palette) =
  let sb = ui.sidebar
  let title = createTitle(palette.name)
  let content = div0("geSidebar")
  content.style("touchAction", "none")
  if not palette.expanded: content.style("display", "none")
  panel.appendChild(title)
  let outer = createElement("div")
  outer.appendChild(content)
  panel.appendChild(outer)
  addFoldingHandler(title, content, palette.expanded)
  let section = Section(title: title, outer: outer, body: content, palette: palette)
  sb.sections.add section
  if palette.stencilLibrary.len > 0: sb.stencilHosts[palette.stencilLibrary.toLowerAscii()] = section
  if palette.classic.len > 0:
    # A classic palette carries its shapes as mxGraph styles.
    let source = classicPalette().get(palette.classic)
    if source.isArr:
      for entry in source:
        let templ = sb.classicTemplate(entry)
        if templ == nil: continue
        let item = ui.createItem("", valStr(entry["title"]), templ, entry)
        content.appendChild(item)
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

proc buildSidebar(ui: EditorUi, container: Node) =
  let sb = ui.sidebar
  sb.container = container
  container.dropChildren()
  let tabs = div0("geSidebarTabs")
  let tabOriginal = div0("geSidebarTab active")
  tabOriginal.text = "Original"
  tabs.appendChild(tabOriginal)
  container.appendChild(tabs)
  # Only the original mxGraph inventory is part of this build.
  let panelOriginal = div0("geSidebarTabPanel active")
  panelOriginal.setAttribute("id", "originalMxGraphObj")
  container.appendChild(panelOriginal)
  sb.originalPanel = panelOriginal
  ui.createScratchpad(panelOriginal)
  ui.createSearch(panelOriginal)
  for palette in sb.originalPalettes: ui.addPalette(panelOriginal, palette)
  ui.renderScratchpad()
  ui.addStencilPalettes()
