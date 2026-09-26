# Included from editorui.nim: the inspector -- Diagram, Style, Text and
# Arrange pages of cards. Every control previews live against a latched
# selection and lands as one undo step (bindLiveStyle).

type Build = proc(value: string): Val

type InputOptions = openArray[(string, float64)]

proc applyOptions(input: Node, options: InputOptions) =
  for (name, value) in options: input.setProp(name, value)

proc fillOptions(select: Node, values: openArray[(string, string)]) =
  for (value, text) in values:
    let option = createElement("option")
    option.value = value
    option.text = text
    select.appendChild(option)

proc numVal(value: string, d: float64): float64 = numberOr(value, d)

proc control(kind: string, options: InputOptions = []): Node =
  ## A form control in the inspector's style.
  result = case kind
    of "checkbox": switchInput()
    of "color": el("input", "qg-swatch")
    of "range": el("input", "qg-range")
    else: el("input", "qg-input")
  if kind != "checkbox": result.typ = kind
  result.applyOptions(options)

proc checkbox(ui: EditorUi, section: Node, key, label: string, handler: proc(value: bool)): Node {.discardable.} =
  let input = control("checkbox")
  input.on("change", proc(e: Event) = handler(input.checked))
  field(section, label, input, "qg-field-switch")
  ui.formatFields[key] = input
  input

proc input(ui: EditorUi, section: Node, key, label, kind: string, handler: proc(value: string),
           options: InputOptions = []): Node {.discardable.} =
  ## Diagram-level controls, bound to input as well as change so dragging a
  ## colour wheel or a number spinner updates the canvas as it happens.
  let input = control(kind, options)
  input.on("input", proc(e: Event) = handler(input.value))
  input.on("change", proc(e: Event) = handler(input.value))
  field(section, label, input)
  ui.formatFields[key] = input
  input

proc select(ui: EditorUi, section: Node, key, label: string, values: openArray[(string, string)],
            handler: proc(value: string)): Node {.discardable.} =
  let select = el("select", "qg-select")
  select.fillOptions(values)
  select.on("change", proc(e: Event) = handler(select.value))
  field(section, label, select)
  ui.formatFields[key] = select
  select

proc bindLiveStyle(ui: EditorUi, control: Node, build: Build, commitLabel: string,
                   predicate: Predicate = nil, read: proc(): string = nil,
                   textCommand = ""): Node {.discardable.} =
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
  var textRange = false
  proc begin() =
    if open or control.getBool("disabled"): return
    open = true
    textRange = textCommand.len > 0 and g.hasSelectedTextRange()
    if not textRange:
      ids = g.getStyleTargetIds(predicate)
      before = g.snapshot()
    # While a session is open the control owns its value, so a refresh the
    # edit triggers cannot write over it.
    ui.liveEdit.incl control.id
  proc preview() =
    begin()
    if not open: return
    if not textRange: discard g.call("previewStyle", ids, build(readValue()))
  proc commit() =
    if not open: return
    open = false
    ui.liveEdit.excl control.id
    if textRange:
      discard g.execSelectedTextStyle(textCommand, readValue(), textCommand != "strikeThrough")
    else:
      discard g.call("previewStyle", ids, build(readValue()))
      g.g.commitPreview(before, commitLabel)
  control.on("pointerdown", proc(e: Event) = begin())
  control.on("focus", proc(e: Event) = begin())
  control.on("keydown", proc(e: Event) = begin())
  control.on("input", proc(e: Event) = preview())
  control.on("change", proc(e: Event) = commit())
  control.on("blur", proc(e: Event) = commit())
  control

proc styleInput(ui: EditorUi, section: Node, key, label, kind: string, build: Build,
                commitLabel: string, predicate: Predicate = nil, options: InputOptions = [],
                textCommand = ""): Node {.discardable.} =
  let input = control(kind, options)
  field(section, label, input)
  ui.formatFields[key] = input
  ui.bindLiveStyle(input, build, commitLabel, predicate, textCommand = textCommand)

proc styleRange(ui: EditorUi, section: Node, key, label: string, build: Build, commitLabel: string,
                predicate: Predicate, options: InputOptions, suffix = ""): Node {.discardable.} =
  ## A slider with its value read out beside it.
  let wrap = div0("qg-range-wrap")
  let input = control("range", options)
  let output = el("output", "qg-range-value")
  wrap.appendChild(input)
  wrap.appendChild(output)
  field(section, label, wrap)
  ui.formatFields[key] = input
  let sync = proc() = output.text = input.value & suffix
  input.on("input", proc(e: Event) = sync())
  ui.rangeSyncs.add sync
  ui.bindLiveStyle(input, build, commitLabel, predicate)

proc styleColor(ui: EditorUi, section: Node, key, label: string, property: string, commitLabel: string,
                predicate: Predicate = nil): Node {.discardable.} =
  ## A colour field with one-tap presets underneath.
  let input = ui.styleInput(section, key, label, "color",
    proc(value: string): Val = o1(property, jstr(value)), commitLabel, predicate,
    textCommand = (if property == "textColor": "foreColor" else: ""))
  swatchRow(section, proc(color: string) =
    if property != "textColor" or not ui.graph.execSelectedTextStyle("foreColor", color, true):
      ui.graph.applyStyle(o1(property, jstr(color)), commitLabel, predicate)
    input.value = color)
  input

proc styleCheckbox(ui: EditorUi, section: Node, key, label: string, build: Build,
                   commitLabel: string, predicate: Predicate = nil,
                   textCommand = ""): Node {.discardable.} =
  let input = control("checkbox")
  field(section, label, input, "qg-field-switch")
  ui.formatFields[key] = input
  ui.bindLiveStyle(input, build, commitLabel, predicate,
    proc(): string = (if input.checked: "true" else: ""), textCommand)

proc styleSelect(ui: EditorUi, section: Node, key, label: string, values: openArray[(string, string)],
                 build: Build, commitLabel: string, predicate: Predicate = nil,
                 textCommand = ""): Node {.discardable.} =
  let select = el("select", "qg-select")
  select.fillOptions(values)
  field(section, label, select)
  ui.formatFields[key] = select
  ui.bindLiveStyle(select, build, commitLabel, predicate, textCommand = textCommand)

proc actionIcons(ui: EditorUi, section: Node, list: openArray[(string, string, string)]): Node {.discardable.} =
  ## A row of icon buttons that run actions, e.g. the alignment controls.
  let row = iconRow(section)
  proc bindAction(button: Node, actionName: string) =
    # Each call gets its own captured argument. Capturing a loop-local here
    # makes every button run the last action in the row.
    button.on("click", proc(e: Event) = ui.run(actionName))
  for (iconName, title, action) in list:
    let button = iconButton(iconName, title)
    # Keeping focus in an open label lets text commands apply to the
    # selected range instead of closing the editor first.
    button.on("pointerdown", proc(e: Event) = e.preventDefault())
    button.on("mousedown", proc(e: Event) = e.preventDefault())
    bindAction(button, action)
    row.appendChild(button)
  row

proc formatButton(ui: EditorUi, section: Node, label: string, handler: proc(), iconName = ""): Node {.discardable.} =
  let button = textButton(label, "qg-btn qg-btn-soft", iconName)
  button.on("click", proc(e: Event) = handler())
  section.appendChild(button)
  button

proc buildFormat(ui: EditorUi) =
  let g = ui.graph
  let (root, content) = panel("Inspector", "inspector", proc() =
    if ui.layout == lmPhone: ui.closeSheet() else: ui.togglePane("inspector"))
  ui.inspectorPanel = root
  root.on("pointerdown", proc(e: Event) = ui.graph.retainTextEditorForInspector(), capture = true)
  ui.formatTabs = div0("qg-segmented qg-inspector-tabs")
  ui.formatTabs.setAttribute("role", "tablist")
  content.appendChild(ui.formatTabs)

  proc makePanel(name: string): Node =
    result = div0("qg-page")
    result.setData("page", name)
    result.hidden = true
    content.appendChild(result)
    ui.formatPanels[name] = result

  proc makeTab(name, label, iconName: string) =
    let tab = el("button", "qg-segment")
    tab.typ = "button"
    tab.setData("tab", name)
    tab.setAttribute("role", "tab")
    tab.appendChild(icon(iconName, 16))
    let t = createElement("span")
    t.text = label
    tab.appendChild(t)
    tab.on("mousedown", proc(e: Event) = e.preventDefault())
    tab.on("click", proc(e: Event) = ui.selectFormatTab(name))
    ui.formatTabs.appendChild(tab)
    ui.formatTabButtons[name] = tab

  makeTab("diagram", "Diagram", "page")
  makeTab("block", "Block", "script")
  makeTab("style", "Style", "palette")
  makeTab("text", "Text", "text")
  makeTab("arrange", "Arrange", "arrange")

  let diagramPanel = makePanel("diagram")
  ui.script.inspectorBody = makePanel("block")
  let stylePanel = makePanel("style")
  let textPanel = makePanel("text")
  let arrangePanel = makePanel("arrange")

  # Diagram ---------------------------------------------------------------
  let viewSection = card(diagramPanel, "Canvas", "grid")
  ui.checkbox(viewSection, "gridEnabled", "Grid", proc(value: bool) =
    g.setDiagramOptions(o1("gridEnabled", jbool(value))))
  ui.input(viewSection, "gridSize", "Grid size", "number", proc(value: string) =
    g.setDiagramOptions(o1("gridSize", jnum(clamp(numVal(value, 10), 2, 200)))),
    [("min", 2.0), ("max", 200.0), ("step", 1.0)])
  ui.input(viewSection, "gridColor", "Grid color", "color", proc(value: string) =
    g.setDiagramOptions(o1("gridColor", jstr(value))))
  ui.input(viewSection, "backgroundColor", "Background", "color", proc(value: string) =
    g.setDiagramOptions(o1("backgroundColor", jstr(value))))
  ui.checkbox(viewSection, "pageView", "Page view", proc(value: bool) =
    g.setDiagramOptions(o1("pageView", jbool(value))))

  let options = card(diagramPanel, "Assists", "connector")
  ui.checkbox(options, "connectionArrows", "Connection arrows", proc(value: bool) =
    g.setDiagramOptions(o1("connectionArrows", jbool(value)))
    g.drawOverlay())
  ui.checkbox(options, "connectionPoints", "Connection points", proc(value: bool) =
    g.setDiagramOptions(o1("connectionPoints", jbool(value)))
    g.drawOverlay())
  ui.checkbox(options, "guidesEnabled", "Smart guides", proc(value: bool) =
    g.setDiagramOptions(o1("guidesEnabled", jbool(value))))

  let paper = card(diagramPanel, "Paper", "page")
  paper.getNode("parentNode").setData("card", "paper")
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
  let pageSize = fieldRow(paper)
  ui.input(pageSize, "pageWidth", "W (in)", "number", proc(value: string) =
    let width = jsNumber(value)
    if isFiniteJs(width) and width > 0:
      ui.formatFields["paperSize"].value = "custom"
      g.setDiagramOptions(o1("pageWidth", jnum(jsRound(width * 100)))),
    [("min", 0.5), ("max", 100.0), ("step", 0.01)])
  ui.input(pageSize, "pageHeight", "H (in)", "number", proc(value: string) =
    let height = jsNumber(value)
    if isFiniteJs(height) and height > 0:
      ui.formatFields["paperSize"].value = "custom"
      g.setDiagramOptions(o1("pageHeight", jnum(jsRound(height * 100)))),
    [("min", 0.5), ("max", 100.0), ("step", 0.01)])
  ui.input(paper, "pageScale", "Page scale (%)", "number", proc(value: string) =
    let scale = jsNumber(value)
    if isFiniteJs(scale) and scale > 0: g.setDiagramOptions(o1("pageScale", jnum(scale / 100))),
    [("min", 10.0), ("max", 400.0), ("step", 5.0)])
  let diagramActions = div0("qg-button-row")
  diagramPanel.appendChild(diagramActions)
  ui.formatButton(diagramActions, "Edit data…", proc() = ui.editData(), "code")
  ui.formatButton(diagramActions, "Clear default style", proc() = ui.run("clearDefaultStyle"), "eraser")

  # Style -----------------------------------------------------------------
  let fillCard = card(stylePanel, "Fill", "fill")
  ui.styleColor(fillCard, "fill", "Color", "fill", "Fill", nodesOnly)
  ui.styleSelect(fillCard, "gradientDirection", "Gradient", [
    ("", "None"), ("vertical", "Vertical"), ("horizontal", "Horizontal"),
    ("radial", "Radial"), ("diagonal", "Diagonal")],
    proc(value: string): Val =
      result = newObj()
      result.put("gradientDirection", if value.len > 0: jstr(value) else: nil)
      result.put("gradient", nil),
    "Gradient", nodesOnly)
  ui.styleInput(fillCard, "gradient", "Gradient to", "color",
    proc(value: string): Val = o1("gradient", jstr(value)), "Gradient Color", nodesOnly)

  let lineCard = card(stylePanel, "Line", "pen")
  ui.styleColor(lineCard, "stroke", "Color", "stroke", "Line Color")
  ui.styleInput(lineCard, "strokeWidth", "Width", "number",
    proc(value: string): Val = o1("strokeWidth", jnum(max(0.0, numVal(value, 0)))),
    "Line Width", nil, [("min", 0.0), ("max", 24.0), ("step", 0.5)])
  ui.styleCheckbox(lineCard, "dashed", "Dashed",
    proc(value: string): Val = o1("dashed", jbool(value.len > 0)), "Dashed")

  let effects = card(stylePanel, "Effects", "shadow")
  ui.styleRange(effects, "opacity", "Opacity",
    proc(value: string): Val = o1("opacity", jnum(max(0.0, min(1.0, jsNumber(value) / 100)))),
    "Opacity", nil, [("min", 0.0), ("max", 100.0), ("step", 5.0)], "%")
  ui.styleRange(effects, "radius", "Corners",
    proc(value: string): Val = o1("radius", jnum(max(0.0, numVal(value, 0)))),
    "Corner Radius", nodesOnly, [("min", 0.0), ("max", 80.0), ("step", 1.0)])
  ui.styleCheckbox(effects, "shadow", "Shadow",
    proc(value: string): Val = o1("shadow", jbool(value.len > 0)), "Shadow", nodesOnly)

  let connector = card(stylePanel, "Connector", "connector")
  ui.formatFields["connectorCard"] = connector.getNode("parentNode")
  let connectorRoute = ui.styleSelect(connector, "lineStyle", "Route", [
    ("orthogonal", "Orthogonal"), ("straight", "Straight"), ("curved", "Curved"),
    ("circular", "Circular arc")],
    proc(value: string): Val =
      result = o1("lineStyle", jstr(value))
      result["route"] = jnull,
    "Connector Route", edgesOnly)
  let arcSweepInput = ui.styleInput(connector, "arcSweep", "Arc degrees", "number",
    proc(value: string): Val = o1("arcSweep", jnum(max(1.0, min(360.0, numVal(value, 180))))),
    "Circular Arc Degrees", edgesOnly, [("min", 1.0), ("max", 360.0), ("step", 1.0)])
  let arcSideInput = ui.styleSelect(connector, "arcSide", "Arc side", [
    ("1", "Left / clockwise"), ("-1", "Right / counterclockwise")],
    proc(value: string): Val = o1("arcSide", jnum(if jsNumber(value) < 0: -1.0 else: 1.0)),
    "Circular Arc Side", edgesOnly)
  ui.formatFields["arcSweepRow"] = arcSweepInput.closest(".qg-field")
  ui.formatFields["arcSideRow"] = arcSideInput.closest(".qg-field")
  proc updateArcRows() =
    let visible = connectorRoute.value == "circular"
    ui.formatFields["arcSweepRow"].hidden = not visible
    ui.formatFields["arcSideRow"].hidden = not visible
  connectorRoute.on("input", proc(e: Event) = updateArcRows())
  connectorRoute.on("change", proc(e: Event) = updateArcRows())
  updateArcRows()

  let ports = card(stylePanel, "Variable sockets", "connector")
  ui.styleCheckbox(ports, "portsEnabled", "Show named sockets",
    proc(value: string): Val = o1("portsEnabled", jbool(value.len > 0)),
    "Variable Sockets", nodesOnly)
  ui.styleInput(ports, "inputPorts", "Inputs", "text",
    proc(value: string): Val = o1("inputPorts", jstr(value)), "Input Sockets", nodesOnly)
  ui.styleInput(ports, "outputPorts", "Outputs", "text",
    proc(value: string): Val = o1("outputPorts", jstr(value)), "Output Sockets", nodesOnly)
  let portHint = el("small", "qg-field-hint")
  portHint.text = "Comma-separated names, optionally Name:type (float, bool, text). Drag an output socket to an input socket."
  ports.appendChild(portHint)
  let arrows = [("none", "None"), ("block", "Block"), ("open", "Open"), ("oval", "Oval"), ("diamond", "Diamond")]
  let arrowRow = fieldRow(connector)
  ui.styleSelect(arrowRow, "startArrow", "Start", arrows,
    proc(value: string): Val = o1("startArrow", jstr(value)), "Start Arrow", edgesOnly)
  ui.styleSelect(arrowRow, "endArrow", "End", arrows,
    proc(value: string): Val = o1("endArrow", jstr(value)), "End Arrow", edgesOnly)
  ui.styleInput(connector, "arrowSize", "Arrow size", "number",
    proc(value: string): Val = o1("arrowSize", jnum(max(3.0, numVal(value, 9)))),
    "Arrow Size", edgesOnly, [("min", 3.0), ("max", 30.0), ("step", 1.0)])

  let styleActions = div0("qg-button-row")
  stylePanel.appendChild(styleActions)
  ui.formatFields["editStyleButton"] = ui.formatButton(styleActions, "Edit style…", proc() = ui.editStyle(), "code")
  let editImage = ui.formatButton(styleActions, "Edit media…", proc() = ui.run("editImage"), "image")
  editImage.hidden = true
  ui.formatFields["editImageButton"] = editImage
  ui.formatButton(styleActions, "Set as default", proc() = ui.run("setDefaultStyle"), "star")

  # Text ------------------------------------------------------------------
  let text = card(textPanel, "Font", "text")
  ui.styleSelect(text, "fontFamily", "Typeface", [
    ("Arial, sans-serif", "Arial"), ("Helvetica, sans-serif", "Helvetica"),
    ("Verdana, sans-serif", "Verdana"), ("Georgia, serif", "Georgia"),
    ("Courier New, monospace", "Courier New")],
    proc(value: string): Val = o1("fontFamily", jstr(value)), "Font", nodesOnly, "fontName")
  ui.styleInput(text, "fontSize", "Size", "number",
    proc(value: string): Val = o1("fontSize", jnum(max(6.0, numVal(value, 14)))),
    "Font Size", nodesOnly, [("min", 6.0), ("max", 144.0), ("step", 1.0)], "fontSizePx")
  ui.styleColor(text, "textColor", "Color", "textColor", "Text Color", nodesOnly)
  ui.actionIcons(text, [
    ("bold", "Bold", "bold"), ("italic", "Italic", "italic"),
    ("underline", "Underline", "underline"),
    ("superscript", "Superscript", "superscript"),
    ("subscript", "Subscript", "subscript"),
    ("eraser", "Clear formatting", "removeFormat")])
  # These act on the selected range while a label is open for editing.
  ui.actionIcons(text, [
    ("listBullet", "Bulleted list", "unorderedlist"),
    ("listNumber", "Numbered list", "orderedlist"),
    ("indent", "Increase indent", "indent"),
    ("outdent", "Decrease indent", "outdent"),
    ("link", "Link", "editLink")])
  ui.styleCheckbox(text, "strikethrough", "Strikethrough",
    proc(value: string): Val = o1("strikethrough", jbool(value.len > 0)), "Strikethrough", nodesOnly,
    "strikeThrough")
  ui.styleCheckbox(text, "wordWrap", "Word wrap",
    proc(value: string): Val = o1("wordWrap", jbool(value.len > 0)), "Word Wrap", nodesOnly)

  let align = card(textPanel, "Alignment", "textCenter")
  ui.actionIcons(align, [
    ("textLeft", "Align text left", "textLeft"),
    ("textCenter", "Align text center", "textCenter"),
    ("textRight", "Align text right", "textRight")])
  let alignRow = fieldRow(align)
  ui.styleSelect(alignRow, "textAlign", "Horizontal", [
    ("left", "Left"), ("center", "Center"), ("right", "Right")],
    proc(value: string): Val = o1("textAlign", jstr(value)), "Text Align", nodesOnly)
  ui.styleSelect(alignRow, "verticalAlign", "Vertical", [
    ("top", "Top"), ("middle", "Middle"), ("bottom", "Bottom")],
    proc(value: string): Val = o1("verticalAlign", jstr(value)), "Vertical Align", nodesOnly)

  # Arrange ---------------------------------------------------------------
  let arrangeAlign = card(arrangePanel, "Align & distribute", "alignLeft")
  ui.actionIcons(arrangeAlign, [
    ("alignLeft", "Align left", "alignLeft"),
    ("alignCenter", "Align center", "alignCenter"),
    ("alignRight", "Align right", "alignRight"),
    ("alignTop", "Align top", "alignTop"),
    ("alignMiddle", "Align middle", "alignMiddle"),
    ("alignBottom", "Align bottom", "alignBottom")])
  ui.actionIcons(arrangeAlign, [
    ("distributeH", "Distribute horizontally", "distributeHorizontal"),
    ("distributeV", "Distribute vertically", "distributeVertical")])

  let order = card(arrangePanel, "Order", "arrange")
  ui.actionIcons(order, [
    ("toFront", "Bring to front", "toFront"),
    ("toBack", "Send to back", "toBack"),
    ("duplicate", "Duplicate", "duplicate"),
    ("trash", "Delete", "delete")])

  let group = card(arrangePanel, "Group", "group")
  ui.actionIcons(group, [
    ("group", "Group", "group"),
    ("ungroup", "Ungroup", "ungroup"),
    ("lock", "Lock / unlock", "lock")])

  let size = card(arrangePanel, "Geometry", "select")
  let sizeRow = fieldRow(size)
  ui.styleInput(sizeRow, "width", "W", "number",
    proc(value: string): Val = o1("width", jnum(max(1.0, numVal(value, 1)))),
    "Width", nodesOnly, [("min", 1.0), ("step", 1.0)])
  ui.styleInput(sizeRow, "height", "H", "number",
    proc(value: string): Val = o1("height", jnum(max(1.0, numVal(value, 1)))),
    "Height", nodesOnly, [("min", 1.0), ("step", 1.0)])
  let posRow = fieldRow(size)
  ui.styleInput(posRow, "positionX", "X", "number",
    proc(value: string): Val = o1("x", jnum(numVal(value, 0))), "Position", nodesOnly, [("step", 1.0)])
  ui.styleInput(posRow, "positionY", "Y", "number",
    proc(value: string): Val = o1("y", jnum(numVal(value, 0))), "Position", nodesOnly, [("step", 1.0)])
  ui.styleInput(size, "rotation", "Angle", "number",
    proc(value: string): Val = o1("rotation", jnum(numVal(value, 0))),
    "Angle", nodesOnly, [("min", -360.0), ("max", 360.0), ("step", 1.0)])

  let flip = card(arrangePanel, "Transform", "rotate")
  ui.actionIcons(flip, [
    ("rotate", "Rotate 90°", "rotate90"),
    ("flipH", "Flip horizontal", "flipHorizontal"),
    ("flipV", "Flip vertical", "flipVertical")])

  for page in [stylePanel, textPanel, arrangePanel]:
    for c in page.queryAll("input,select,button"): ui.styleControls.add c

  ui.rightDock.appendChild(root)
  ui.selectFormatTab("diagram")

proc selectFormatTab*(ui: EditorUi, name: string) =
  if not ui.formatPanels.hasKey(name) or name in ui.formatDisabled: return
  ui.activeFormatTab = name
  for key, panel in ui.formatPanels:
    panel.hidden = key != name
    ui.formatTabButtons[key].toggleClass("is-active", key == name)
    ui.formatTabButtons[key].setAttribute("aria-selected", if key == name: "true" else: "false")

proc updateFormatTabs*(ui: EditorUi, hasSelection: bool) =
  ## Diagram when nothing is selected, Style/Text/Arrange otherwise, and
  ## Block first for a single script block.
  let scriptBlock = ui.selectedScriptBlock()
  let visible = if scriptBlock != nil: @["block", "style", "text", "arrange"]
                elif hasSelection: @["style", "text", "arrange"] else: @["diagram"]
  if scriptBlock != nil and idOf(scriptBlock) != ui.script.inspectedId:
    ui.activeFormatTab = "block"
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
  ui.refreshScriptInspector()
  for control in ui.styleControls: control.disabled = selection.len == 0

  # Edit Media appears only for media, and the pair then splits the row.
  let single = if selection.len == 1: selection[0] else: nil
  let isImage = single != nil and (single.eqs("shape", "image") or not nullish(single["src"]))
  f["editImageButton"].hidden = not isImage
  var hasEdge = false
  for item in selection:
    if edgesOnly(item): hasEdge = true
  f["connectorCard"].hidden = selection.len > 0 and not hasEdge

  if selection.len == 0:
    for sync in ui.rangeSyncs: sync()
    return

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
  toggle("portsEnabled", common("portsEnabled", jfalse).isTrue)
  set("inputPorts", valStr(common("inputPorts", jstr("In"))))
  set("outputPorts", valStr(common("outputPorts", jstr("Out"))))
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
  for sync in ui.rangeSyncs: sync()
