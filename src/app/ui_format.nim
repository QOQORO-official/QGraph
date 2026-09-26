# Included from editorui.nim: the format panel (Diagram/Style/Text/Arrange).

type Build = proc(value: string): Val

proc createFormatSection(ui: EditorUi, panel: Node, title: string, hasTitle = true): Node =
  result = div0("geFormatSection")
  if hasTitle:
    let heading = div0("geFormatTitle")
    heading.text = title
    result.appendChild(heading)
  panel.appendChild(result)

proc makeRow(ui: EditorUi, section: Node, labelText: string, input: Node): Node {.discardable.} =
  result = el("label", "geFormatRow")
  let label = createElement("span")
  label.text = labelText
  result.appendChild(label)
  result.appendChild(input)
  section.appendChild(result)

type InputOptions = openArray[(string, float64)]

proc applyOptions(input: Node, options: InputOptions) =
  for (name, value) in options: input.setProp(name, value)

proc checkbox(ui: EditorUi, section: Node, key, label: string, handler: proc(value: bool)): Node {.discardable.} =
  let input = createElement("input")
  input.typ = "checkbox"
  input.on("change", proc(e: Event) = handler(input.checked))
  ui.makeRow(section, label, input)
  ui.formatFields[key] = input
  input

proc input(ui: EditorUi, section: Node, key, label, kind: string, handler: proc(value: string),
           options: InputOptions = []): Node {.discardable.} =
  ## Diagram-level controls, bound to input as well as change so dragging a
  ## colour wheel or a number spinner updates the canvas as it happens.
  let input = createElement("input")
  input.typ = kind
  input.applyOptions(options)
  input.on("input", proc(e: Event) = handler(input.value))
  input.on("change", proc(e: Event) = handler(input.value))
  ui.makeRow(section, label, input)
  ui.formatFields[key] = input
  input

proc fillOptions(select: Node, values: openArray[(string, string)]) =
  for (value, text) in values:
    let option = createElement("option")
    option.value = value
    option.text = text
    select.appendChild(option)

proc select(ui: EditorUi, section: Node, key, label: string, values: openArray[(string, string)],
            handler: proc(value: string)): Node {.discardable.} =
  let select = createElement("select")
  select.fillOptions(values)
  select.on("change", proc(e: Event) = handler(select.value))
  ui.makeRow(section, label, select)
  ui.formatFields[key] = select
  select

proc bindLiveStyle(ui: EditorUi, control: Node, build: Build, commitLabel: string,
                   predicate: Predicate = nil, read: proc(): string = nil): Node {.discardable.} =
  ## Live style editing against a latched target.
  ##
  ## A native colour picker reports its value while open and again when it
  ## closes, and the selection can change in between, so reading the
  ## selection at event time would write to the wrong objects. The target
  ## ids are captured when the control is engaged, every intermediate value
  ## previews against those ids, and the whole drag is one undo step.
  let g = ui.graph
  let readValue = if read != nil: read else: (proc(): string = control.value)
  var open = false
  var ids: Val = nil
  var before = ""
  proc begin() =
    if open or control.getBool("disabled"): return
    open = true
    ids = g.getStyleTargetIds(predicate)
    before = g.snapshot()
    # While a session is open the control owns its value, so a refresh the
    # edit triggers cannot write over it.
    ui.liveEdit.incl control.id
  proc preview() =
    begin()
    if open: discard g.call("previewStyle", ids, build(readValue()))
  proc commit() =
    if not open: return
    open = false
    discard g.call("previewStyle", ids, build(readValue()))
    ui.liveEdit.excl control.id
    g.g.commitPreview(before, commitLabel)
  control.on("pointerdown", proc(e: Event) = begin())
  control.on("focus", proc(e: Event) = begin())
  control.on("keydown", proc(e: Event) = begin())
  control.on("input", proc(e: Event) = preview())
  control.on("change", proc(e: Event) = commit())
  control.on("blur", proc(e: Event) = commit())
  control

proc styleInput(ui: EditorUi, section: Node, key, label, kind: string, build: Build,
                commitLabel: string, predicate: Predicate = nil, options: InputOptions = []): Node {.discardable.} =
  let input = createElement("input")
  input.typ = kind
  input.applyOptions(options)
  ui.makeRow(section, label, input)
  ui.formatFields[key] = input
  ui.bindLiveStyle(input, build, commitLabel, predicate)

proc styleCheckbox(ui: EditorUi, section: Node, key, label: string, build: Build,
                   commitLabel: string, predicate: Predicate = nil): Node {.discardable.} =
  let input = createElement("input")
  input.typ = "checkbox"
  ui.makeRow(section, label, input)
  ui.formatFields[key] = input
  ui.bindLiveStyle(input, build, commitLabel, predicate,
    proc(): string = (if input.checked: "true" else: ""))

proc styleSelect(ui: EditorUi, section: Node, key, label: string, values: openArray[(string, string)],
                 build: Build, commitLabel: string, predicate: Predicate = nil): Node {.discardable.} =
  let select = createElement("select")
  select.fillOptions(values)
  ui.makeRow(section, label, select)
  ui.formatFields[key] = select
  ui.bindLiveStyle(select, build, commitLabel, predicate)

proc spriteRow(ui: EditorUi, section: Node, list: openArray[(string, string, string)]): Node {.discardable.} =
  ## A row of classic sprite buttons, e.g. the alignment controls.
  let row = div0("geFormatRow")
  row.style("justifyContent", "flex-start")
  for (sprite, title, action) in list:
    let button = el("a", "geButton geSprite geSprite-" & sprite)
    button.cssText = "display:inline-block;width:20px;height:20px;margin:2px;" &
      "opacity:0.6;cursor:pointer;border:1px solid transparent;"
    button.setAttribute("title", title)
    # Keeping focus in an open label lets these commands apply to the
    # selected range instead of closing the editor first.
    button.on("pointerdown", proc(e: Event) = e.preventDefault())
    button.on("mousedown", proc(e: Event) = e.preventDefault())
    let name = action
    button.on("click", proc(e: Event) = ui.run(name))
    button.on("mouseenter", proc(e: Event) = button.style("opacity", "1"))
    button.on("mouseleave", proc(e: Event) = button.style("opacity", "0.6"))
    row.appendChild(button)
  section.appendChild(row)
  row

proc formatButton(ui: EditorUi, section: Node, label: string, handler: proc()): Node {.discardable.} =
  let button = el("button", "geBtn")
  button.text = label
  button.on("click", proc(e: Event) = handler())
  section.appendChild(button)
  button

proc numVal(value: string, d: float64): float64 = numberOr(value, d)

proc buildFormat(ui: EditorUi) =
  let g = ui.graph
  ui.formatTabs = div0("geFormatTabs")
  ui.formatContainer.appendChild(ui.formatTabs)

  proc makePanel(name: string): Node =
    result = div0("geFormatPanel")
    result.hidden = true
    ui.formatContainer.appendChild(result)
    ui.formatPanels[name] = result

  proc makeTab(name, label: string) =
    let tab = div0("geFormatTab")
    tab.text = label
    tab.on("mousedown", proc(e: Event) = e.preventDefault())
    tab.on("click", proc(e: Event) = ui.selectFormatTab(name))
    ui.formatTabs.appendChild(tab)
    ui.formatTabButtons[name] = tab

  makeTab("diagram", "Diagram")
  makeTab("style", "Style")
  makeTab("text", "Text")
  makeTab("arrange", "Arrange")

  # The classic close affordance: the original 9px PNG and its placement.
  let closeTab = div0("geFormatClose")
  let closeImage = createElement("img")
  closeImage.setAttribute("border", "0")
  closeImage.setAttribute("src", "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAkAAAAJAQMAAADaX5RTAAAABlBMVEV7mr3///+wksspAAAAAnRSTlP/AOW3MEoAAAAdSURBVAgdY9jXwCDDwNDRwHCwgeExmASygSL7GgB12QiqNHZZIwAAAABJRU5ErkJggg==")
  closeImage.setAttribute("title", "Hide")
  closeImage.setAttribute("alt", "Hide")
  for (k, v) in [("position", "absolute"), ("display", "block"), ("right", "0px"), ("top", "8px"),
                 ("cursor", "pointer"), ("marginTop", "1px"), ("marginRight", "6px"),
                 ("border", "1px solid transparent"), ("padding", "1px"), ("opacity", "0.5")]:
    closeImage.style(k, v)
  closeImage.on("mouseenter", proc(e: Event) = closeImage.style("opacity", "1"))
  closeImage.on("mouseleave", proc(e: Event) = closeImage.style("opacity", "0.5"))
  closeImage.on("click", proc(e: Event) =
    e.stopPropagation()
    ui.run("formatPanel"))
  closeTab.appendChild(closeImage)
  ui.formatTabs.appendChild(closeTab)

  let diagramPanel = makePanel("diagram")
  let stylePanel = makePanel("style")
  let textPanel = makePanel("text")
  let arrangePanel = makePanel("arrange")

  # Diagram ---------------------------------------------------------------
  let viewSection = ui.createFormatSection(diagramPanel, "View")
  ui.checkbox(viewSection, "gridEnabled", "Grid", proc(value: bool) =
    g.setDiagramOptions(o1("gridEnabled", jbool(value))))
  ui.input(viewSection, "gridSize", "Grid Size", "number", proc(value: string) =
    g.setDiagramOptions(o1("gridSize", jnum(clamp(numVal(value, 10), 2, 200)))),
    [("min", 2.0), ("max", 200.0), ("step", 1.0)])
  ui.input(viewSection, "gridColor", "Grid Color", "color", proc(value: string) =
    g.setDiagramOptions(o1("gridColor", jstr(value))))
  ui.checkbox(viewSection, "pageView", "Page View", proc(value: bool) =
    g.setDiagramOptions(o1("pageView", jbool(value))))
  ui.input(viewSection, "backgroundColor", "Background", "color", proc(value: string) =
    g.setDiagramOptions(o1("backgroundColor", jstr(value))))

  let options = ui.createFormatSection(diagramPanel, "Options")
  ui.checkbox(options, "connectionArrows", "Connection Arrows", proc(value: bool) =
    g.setDiagramOptions(o1("connectionArrows", jbool(value)))
    g.drawOverlay())
  ui.checkbox(options, "connectionPoints", "Connection Points", proc(value: bool) =
    g.setDiagramOptions(o1("connectionPoints", jbool(value)))
    g.drawOverlay())
  ui.checkbox(options, "guidesEnabled", "Guides", proc(value: bool) =
    g.setDiagramOptions(o1("guidesEnabled", jbool(value))))

  let paper = ui.createFormatSection(diagramPanel, "Paper Size")
  ui.paperFormats = @[
    ("850,1100", "US Letter"), ("850,1400", "US Legal"),
    ("1100,1700", "US Tabloid"), ("700,1000", "US Executive"),
    ("3300,4681", "A0"), ("2339,3300", "A1"), ("1654,2336", "A2"),
    ("1169,1654", "A3"), ("827,1169", "A4"), ("583,827", "A5"),
    ("413,583", "A6"), ("291,413", "A7"), ("980,1390", "B4"),
    ("690,980", "B5"), ("900,1600", "16:9"), ("1200,1920", "16:10"),
    ("1200,1600", "4:3"), ("custom", "Custom")]
  ui.select(paper, "paperSize", "Size", ui.paperFormats, proc(value: string) =
    if value == "custom": return
    let size = value.split(',')
    var width = jsNumber(size[0])
    var height = jsNumber(size[1])
    if ui.formatFields["landscape"].checked: swap(width, height)
    let changes = newObj()
    changes["pageWidth"] = jnum(width)
    changes["pageHeight"] = jnum(height)
    g.setDiagramOptions(changes))
  ui.checkbox(paper, "landscape", "Landscape", proc(value: bool) =
    let width = g.g.pageWidth
    let height = g.g.pageHeight
    if (value and width < height) or (not value and width > height):
      let changes = newObj()
      changes["pageWidth"] = jnum(height)
      changes["pageHeight"] = jnum(width)
      g.setDiagramOptions(changes))
  ui.input(paper, "pageWidth", "Width (in)", "number", proc(value: string) =
    let width = jsNumber(value)
    if isFiniteJs(width) and width > 0:
      ui.formatFields["paperSize"].value = "custom"
      g.setDiagramOptions(o1("pageWidth", jnum(jsRound(width * 100)))),
    [("min", 0.5), ("max", 100.0), ("step", 0.01)])
  ui.input(paper, "pageHeight", "Height (in)", "number", proc(value: string) =
    let height = jsNumber(value)
    if isFiniteJs(height) and height > 0:
      ui.formatFields["paperSize"].value = "custom"
      g.setDiagramOptions(o1("pageHeight", jnum(jsRound(height * 100)))),
    [("min", 0.5), ("max", 100.0), ("step", 0.01)])
  ui.input(paper, "pageScale", "Page Scale (%)", "number", proc(value: string) =
    let scale = jsNumber(value)
    if isFiniteJs(scale) and scale > 0: g.setDiagramOptions(o1("pageScale", jnum(scale / 100))),
    [("min", 10.0), ("max", 400.0), ("step", 5.0)])
  ui.formatButton(paper, "Edit Data…", proc() = ui.editData())
  ui.formatButton(paper, "Clear Default Style", proc() = ui.run("clearDefaultStyle"))

  # Style -----------------------------------------------------------------
  let appearance = ui.createFormatSection(stylePanel, "Appearance")
  ui.styleInput(appearance, "fill", "Fill", "color",
    proc(value: string): Val = o1("fill", jstr(value)), "Fill", nodesOnly)
  ui.styleSelect(appearance, "gradientDirection", "Gradient", [
    ("", "None"), ("vertical", "Vertical"), ("horizontal", "Horizontal"),
    ("radial", "Radial"), ("diagonal", "Diagonal")],
    proc(value: string): Val =
      result = newObj()
      result.put("gradientDirection", if value.len > 0: jstr(value) else: nil)
      result.put("gradient", nil),
    "Gradient", nodesOnly)
  ui.styleInput(appearance, "gradient", "Gradient Color", "color",
    proc(value: string): Val = o1("gradient", jstr(value)), "Gradient Color", nodesOnly)
  ui.styleInput(appearance, "stroke", "Line", "color",
    proc(value: string): Val = o1("stroke", jstr(value)), "Line Color")
  ui.styleInput(appearance, "strokeWidth", "Line Width", "number",
    proc(value: string): Val = o1("strokeWidth", jnum(max(0.0, numVal(value, 0)))),
    "Line Width", nil, [("min", 0.0), ("max", 24.0), ("step", 0.5)])
  ui.styleInput(appearance, "opacity", "Opacity %", "number",
    proc(value: string): Val = o1("opacity", jnum(max(0.0, min(1.0, jsNumber(value) / 100)))),
    "Opacity", nil, [("min", 0.0), ("max", 100.0), ("step", 5.0)])
  ui.styleInput(appearance, "radius", "Corner Radius", "number",
    proc(value: string): Val = o1("radius", jnum(max(0.0, numVal(value, 0)))),
    "Corner Radius", nodesOnly, [("min", 0.0), ("max", 80.0), ("step", 1.0)])
  ui.styleCheckbox(appearance, "dashed", "Dashed",
    proc(value: string): Val = o1("dashed", jbool(value.len > 0)), "Dashed")
  ui.styleCheckbox(appearance, "shadow", "Shadow",
    proc(value: string): Val = o1("shadow", jbool(value.len > 0)), "Shadow", nodesOnly)

  let connector = ui.createFormatSection(stylePanel, "Connector")
  let connectorRoute = ui.styleSelect(connector, "lineStyle", "Route", [
    ("orthogonal", "Orthogonal"), ("straight", "Straight"), ("curved", "Curved"),
    ("circular", "Circular Arc")],
    proc(value: string): Val =
      result = o1("lineStyle", jstr(value))
      result["route"] = jnull,
    "Connector Route", edgesOnly)
  let arcSweepInput = ui.styleInput(connector, "arcSweep", "Arc Degrees", "number",
    proc(value: string): Val = o1("arcSweep", jnum(max(1.0, min(360.0, numVal(value, 180))))),
    "Circular Arc Degrees", edgesOnly, [("min", 1.0), ("max", 360.0), ("step", 1.0)])
  let arcSideInput = ui.styleSelect(connector, "arcSide", "Arc Side", [
    ("1", "Left / Clockwise"), ("-1", "Right / Counterclockwise")],
    proc(value: string): Val = o1("arcSide", jnum(if jsNumber(value) < 0: -1.0 else: 1.0)),
    "Circular Arc Side", edgesOnly)
  ui.formatFields["arcSweepRow"] = arcSweepInput.getNode("parentElement")
  ui.formatFields["arcSideRow"] = arcSideInput.getNode("parentElement")
  proc updateArcRows() =
    let visible = connectorRoute.value == "circular"
    ui.formatFields["arcSweepRow"].hidden = not visible
    ui.formatFields["arcSideRow"].hidden = not visible
  connectorRoute.on("input", proc(e: Event) = updateArcRows())
  connectorRoute.on("change", proc(e: Event) = updateArcRows())
  updateArcRows()
  let arrows = [("none", "None"), ("block", "Block"), ("open", "Open"), ("oval", "Oval"), ("diamond", "Diamond")]
  ui.styleSelect(connector, "startArrow", "Start Arrow", arrows,
    proc(value: string): Val = o1("startArrow", jstr(value)), "Start Arrow", edgesOnly)
  ui.styleSelect(connector, "endArrow", "End Arrow", arrows,
    proc(value: string): Val = o1("endArrow", jstr(value)), "End Arrow", edgesOnly)
  ui.styleInput(connector, "arrowSize", "Arrow Size", "number",
    proc(value: string): Val = o1("arrowSize", jnum(max(3.0, numVal(value, 9)))),
    "Arrow Size", edgesOnly, [("min", 3.0), ("max", 30.0), ("step", 1.0)])

  let styleActions = ui.createFormatSection(stylePanel, "", false)
  # Edit Style and Edit Media sit side by side at 100px.
  ui.formatFields["editStyleButton"] = ui.formatButton(styleActions, "Edit Style…", proc() = ui.editStyle())
  let editImage = ui.formatButton(styleActions, "Edit Media", proc() = ui.run("editImage"))
  editImage.setAttribute("title", "Edit Media")
  editImage.style("width", "100px")
  editImage.style("marginLeft", "2px")
  editImage.hidden = true
  ui.formatFields["editImageButton"] = editImage
  ui.formatButton(styleActions, "Set as Default Style", proc() = ui.run("setDefaultStyle"))

  # Text ------------------------------------------------------------------
  let text = ui.createFormatSection(textPanel, "Font")
  ui.styleSelect(text, "fontFamily", "Font", [
    ("Arial, sans-serif", "Arial"), ("Helvetica, sans-serif", "Helvetica"),
    ("Verdana, sans-serif", "Verdana"), ("Georgia, serif", "Georgia"),
    ("Courier New, monospace", "Courier New")],
    proc(value: string): Val = o1("fontFamily", jstr(value)), "Font", nodesOnly)
  ui.styleInput(text, "fontSize", "Size", "number",
    proc(value: string): Val = o1("fontSize", jnum(max(6.0, numVal(value, 14)))),
    "Font Size", nodesOnly, [("min", 6.0), ("max", 144.0), ("step", 1.0)])
  ui.styleInput(text, "textColor", "Color", "color",
    proc(value: string): Val = o1("textColor", jstr(value)), "Text Color", nodesOnly)
  ui.spriteRow(text, [
    ("bold", "Bold", "bold"), ("italic", "Italic", "italic"),
    ("underline", "Underline", "underline"),
    ("superscript", "Superscript", "superscript"),
    ("subscript", "Subscript", "subscript"),
    ("removeformat", "Clear Formatting", "removeFormat")])
  # These act on the selected range while a label is open for editing.
  ui.spriteRow(text, [
    ("unorderedlist", "Bulleted List", "unorderedlist"),
    ("orderedlist", "Numbered List", "orderedlist"),
    ("indent", "Increase Indent", "indent"),
    ("outdent", "Decrease Indent", "outdent"),
    ("fontcolor", "Text Colour", "textColor")])
  ui.styleCheckbox(text, "strikethrough", "Strikethrough",
    proc(value: string): Val = o1("strikethrough", jbool(value.len > 0)), "Strikethrough", nodesOnly)
  ui.styleCheckbox(text, "wordWrap", "Word Wrap",
    proc(value: string): Val = o1("wordWrap", jbool(value.len > 0)), "Word Wrap", nodesOnly)

  let align = ui.createFormatSection(textPanel, "Alignment")
  ui.styleSelect(align, "textAlign", "Horizontal", [
    ("left", "Left"), ("center", "Center"), ("right", "Right")],
    proc(value: string): Val = o1("textAlign", jstr(value)), "Text Align", nodesOnly)
  ui.styleSelect(align, "verticalAlign", "Vertical", [
    ("top", "Top"), ("middle", "Middle"), ("bottom", "Bottom")],
    proc(value: string): Val = o1("verticalAlign", jstr(value)), "Vertical Align", nodesOnly)
  ui.spriteRow(align, [
    ("left", "Align Text Left", "textLeft"),
    ("center", "Align Text Center", "textCenter"),
    ("right", "Align Text Right", "textRight")])

  # Arrange ---------------------------------------------------------------
  let arrangeAlign = ui.createFormatSection(arrangePanel, "Align")
  ui.spriteRow(arrangeAlign, [
    ("alignleft", "Align Left", "alignLeft"),
    ("aligncenter", "Align Center", "alignCenter"),
    ("alignright", "Align Right", "alignRight"),
    ("aligntop", "Align Top", "alignTop"),
    ("alignmiddle", "Align Middle", "alignMiddle"),
    ("alignbottom", "Align Bottom", "alignBottom")])
  ui.spriteRow(arrangeAlign, [
    ("horizontalelbow", "Distribute Horizontally", "distributeHorizontal"),
    ("verticalelbow", "Distribute Vertically", "distributeVertical")])

  let order = ui.createFormatSection(arrangePanel, "Order")
  ui.spriteRow(order, [
    ("tofront", "To Front", "toFront"),
    ("toback", "To Back", "toBack"),
    ("duplicate", "Duplicate", "duplicate"),
    ("delete", "Delete", "delete")])

  let group = ui.createFormatSection(arrangePanel, "Group")
  ui.formatButton(group, "Group", proc() = ui.run("group"))
  ui.formatButton(group, "Ungroup", proc() = ui.run("ungroup"))
  ui.formatButton(group, "Lock / Unlock", proc() = ui.run("lock"))

  let size = ui.createFormatSection(arrangePanel, "Size")
  ui.styleInput(size, "width", "Width", "number",
    proc(value: string): Val = o1("width", jnum(max(1.0, numVal(value, 1)))),
    "Width", nodesOnly, [("min", 1.0), ("step", 1.0)])
  ui.styleInput(size, "height", "Height", "number",
    proc(value: string): Val = o1("height", jnum(max(1.0, numVal(value, 1)))),
    "Height", nodesOnly, [("min", 1.0), ("step", 1.0)])
  ui.styleInput(size, "positionX", "Position X", "number",
    proc(value: string): Val = o1("x", jnum(numVal(value, 0))), "Position", nodesOnly, [("step", 1.0)])
  ui.styleInput(size, "positionY", "Position Y", "number",
    proc(value: string): Val = o1("y", jnum(numVal(value, 0))), "Position", nodesOnly, [("step", 1.0)])
  ui.styleInput(size, "rotation", "Angle", "number",
    proc(value: string): Val = o1("rotation", jnum(numVal(value, 0))),
    "Angle", nodesOnly, [("min", -360.0), ("max", 360.0), ("step", 1.0)])

  let flip = ui.createFormatSection(arrangePanel, "Flip")
  ui.formatButton(flip, "Rotate 90°", proc() = ui.run("rotate90"))
  ui.formatButton(flip, "Flip Horizontal", proc() = ui.run("flipHorizontal"))
  ui.formatButton(flip, "Flip Vertical", proc() = ui.run("flipVertical"))

  for panel in [stylePanel, textPanel, arrangePanel]:
    for control in panel.queryAll("input,select,button"): ui.styleControls.add control

  ui.selectFormatTab("diagram")

proc selectFormatTab*(ui: EditorUi, name: string) =
  if not ui.formatPanels.hasKey(name) or name in ui.formatDisabled: return
  ui.activeFormatTab = name
  for key, panel in ui.formatPanels:
    panel.hidden = key != name
    ui.formatTabButtons[key].toggleClass("geActiveTab", key == name)

proc updateFormatTabs*(ui: EditorUi, hasSelection: bool) =
  ## Diagram when nothing is selected, Style/Text/Arrange otherwise.
  let visible = if hasSelection: @["style", "text", "arrange"] else: @["diagram"]
  for key, tab in ui.formatTabButtons:
    let shown = key in visible
    tab.hidden = not shown
    if shown: ui.formatDisabled.excl key
    else:
      ui.formatDisabled.incl key
      ui.formatPanels[key].hidden = true
    ui.formatPanels[key].setData("disabled", if shown: "false" else: "true")
  if ui.activeFormatTab notin visible: ui.selectFormatTab(visible[0])
  else: ui.selectFormatTab(ui.activeFormatTab)

proc updateFormat*(ui: EditorUi) =
  if ui.formatFields.len == 0: return
  let gv = ui.graph
  let g = gv.g
  let f = ui.formatFields
  f["gridEnabled"].checked = g.gridEnabled
  f["gridSize"].value = jsStr(g.gridSize)
  f["gridColor"].value = g.gridColor
  f["pageView"].checked = g.pageView
  f["backgroundColor"].value = g.backgroundColor
  f["connectionArrows"].checked = g.connectionArrows
  f["connectionPoints"].checked = g.connectionPoints
  f["guidesEnabled"].checked = g.guidesEnabled
  f["landscape"].checked = g.pageWidth > g.pageHeight
  f["pageWidth"].value = jsStr(jsRound(g.pageWidth) / 100)
  f["pageHeight"].value = jsStr(jsRound(g.pageHeight) / 100)
  f["pageScale"].value = jsStr(jsRound(g.pageScale * 100))
  let portraitWidth = min(jsRound(g.pageWidth), jsRound(g.pageHeight))
  let portraitHeight = max(jsRound(g.pageWidth), jsRound(g.pageHeight))
  let formatValue = jsStr(portraitWidth) & "," & jsStr(portraitHeight)
  var formatFound = false
  for (value, _) in ui.paperFormats:
    if value == formatValue: formatFound = true
  f["paperSize"].value = if formatFound: formatValue else: "custom"

  let selection = gv.getSelection()
  ui.updateFormatTabs(selection.len > 0)
  for control in ui.styleControls: control.disabled = selection.len == 0

  # Edit Media appears only for media, and the pair then splits the row.
  let single = if selection.len == 1: selection[0] else: nil
  let isImage = single != nil and (single.eqs("shape", "image") or not nullish(single["src"]))
  f["editImageButton"].hidden = not isImage
  f["editStyleButton"].style("width", if isImage: "100px" else: "")

  if selection.len == 0: return

  proc common(key: string, fallback: Val): Val = gv.getCommonStyle(key, fallback)
  let active = activeElement()
  # Never overwrite a control the user is holding open; a native colour
  # picker would otherwise be reset mid-drag.
  proc busy(field: Node): bool = field.id in ui.liveEdit or same(field, active)
  proc set(key: string, value: string) =
    let field = f[key]
    if not busy(field): field.value = value
  proc toggle(key: string, value: bool) =
    let field = f[key]
    if not busy(field): field.checked = value
  proc color(key: string, value: Val) =
    if value.isStr and isHexColor(value.s): set(key, value.s)
  proc rounded(key: string, fallback: float64): string =
    jsStr(jsRound(num(common(key, jnum(fallback)))))

  color("fill", common("fill", jstr("#ffffff")))
  color("gradient", common("gradient", jstr("#ffffff")))
  let gradientDirection = common("gradientDirection", jstr(""))
  set("gradientDirection", if truthy(gradientDirection): valStr(gradientDirection) else: "")
  color("stroke", common("stroke", jstr("#4a5564")))
  color("textColor", common("textColor", jstr("#172033")))
  set("strokeWidth", valStr(common("strokeWidth", jnum(1.5))))
  set("opacity", jsStr(jsRound(num(common("opacity", jnum(1))) * 100)))
  set("radius", rounded("radius", 0))
  toggle("dashed", common("dashed", jfalse).isTrue)
  toggle("shadow", common("shadow", jfalse).isTrue)
  set("fontFamily", valStr(common("fontFamily", jstr("Arial, sans-serif"))))
  set("fontSize", valStr(common("fontSize", jnum(14))))
  toggle("strikethrough", common("strikethrough", jfalse).isTrue)
  toggle("wordWrap", not common("wordWrap", jtrue).isFalse)
  set("textAlign", valStr(common("textAlign", jstr("center"))))
  set("verticalAlign", valStr(common("verticalAlign", jstr("middle"))))
  set("lineStyle", valStr(common("lineStyle", jstr("orthogonal"))))
  let circularRoute = common("lineStyle", jstr("orthogonal")).isStrVal("circular")
  f["arcSweepRow"].hidden = not circularRoute
  f["arcSideRow"].hidden = not circularRoute
  set("arcSweep", rounded("arcSweep", 180))
  set("arcSide", if num(common("arcSide", jnum(1))) < 0: "-1" else: "1")
  set("startArrow", valStr(common("startArrow", jstr("none"))))
  set("endArrow", valStr(common("endArrow", jstr("block"))))
  set("arrowSize", valStr(common("arrowSize", jnum(9))))
  set("width", rounded("width", 0))
  set("height", rounded("height", 0))
  set("positionX", rounded("x", 0))
  set("positionY", rounded("y", 0))
  set("rotation", rounded("rotation", 0))
