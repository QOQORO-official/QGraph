# Included from editorui.nim: the floating quick-style bar and the zoom dock.

proc quickButton(ui: EditorUi, parent: Node, iconName, title, action: string): Node {.discardable.} =
  let button = iconButton(iconName, title)
  button.setData("action", action)
  # Keep focus in an open label so text commands apply to its selection.
  button.on("mousedown", proc(e: Event) = e.preventDefault())
  button.on("click", proc(e: Event) = ui.run(action))
  parent.appendChild(button)
  button

proc quickGroup(parent: Node): Node =
  result = div0("qg-qgroup")
  parent.appendChild(result)

proc toolSelect(ui: EditorUi, parent: Node, key, title: string, values: openArray[(string, string)],
                handler: proc(value: string), cls = "") =
  let select = el("select", "qg-select qg-select-sm" & (if cls.len > 0: " " & cls else: ""))
  select.setAttribute("title", title)
  select.setAttribute("aria-label", title)
  select.fillOptions(values)
  select.on("change", proc(e: Event) = handler(select.value))
  parent.appendChild(select)
  ui.toolbar.controls[key] = select

proc toolColor(ui: EditorUi, parent: Node, key, iconName, title, property, fallback: string,
               predicate: Predicate = nil) =
  ## An icon over a colour bar; the whole chip is the native colour picker.
  let wrapper = el("label", "qg-colorchip")
  wrapper.setAttribute("title", title)
  wrapper.appendChild(icon(iconName, 18))
  let bar = div0("qg-colorchip-bar")
  wrapper.appendChild(bar)
  let input = el("input", "qg-colorchip-input")
  input.typ = "color"
  input.value = fallback
  bar.style("background", fallback)
  input.on("input", proc(e: Event) = bar.style("background", input.value))
  # Live preview against the selection latched when the picker opened.
  ui.bindLiveStyle(input, proc(value: string): Val = o1(property, jstr(value)), title, predicate)
  wrapper.appendChild(input)
  parent.appendChild(wrapper)
  ui.toolbar.controls[key] = input
  ui.toolbar.controls[key & "Bar"] = bar

proc refreshToolbar(ui: EditorUi) =
  let gv = ui.graph
  let controls = ui.toolbar.controls
  for (key, prop, fallback) in [("fontFamily", "fontFamily", jstr("Arial, sans-serif")),
                                ("fontSize", "fontSize", jnum(14)),
                                ("strokeWidth", "strokeWidth", jnum(1.5))]:
    if not controls.hasKey(key): continue
    let value = gv.getCommonStyle(prop, fallback)
    if not value.isStrVal(""): controls[key].value = valStr(value)
  let active = activeElement()
  for (key, prop, fallback) in [("fill", "fill", "#ffffff"), ("stroke", "stroke", "#4a5564"),
                                ("textColor", "textColor", "#172033")]:
    if not controls.hasKey(key): continue
    let input = controls[key]
    let color = gv.getCommonStyle(prop, jstr(fallback))
    # Leave the swatch alone while its picker is open.
    if input.id notin ui.liveEdit and not same(input, active) and color.isStr and isHexColor(color.s):
      input.value = color.s
      controls[key & "Bar"].style("background", color.s)
  let toggles = [("bold", num(gv.getCommonStyle("fontWeight", jnum(400))) >= 700),
                 ("italic", gv.getCommonStyle("italic", jfalse).isTrue),
                 ("underline", gv.getCommonStyle("underline", jfalse).isTrue),
                 ("shadow", gv.getCommonStyle("shadow", jfalse).isTrue)]
  for (key, on) in toggles:
    if controls.hasKey(key): controls[key].toggleClass("is-on", on)

proc buildToolbar(ui: EditorUi) =
  let gv = ui.graph
  let c = ui.toolbar.controls.addr
  ui.quickbar = div0("qg-quickbar")
  ui.quickbar.setAttribute("role", "toolbar")
  ui.quickbar.setAttribute("aria-label", "Quick style")

  let colors = quickGroup(ui.quickbar)
  ui.toolColor(colors, "fill", "fill", "Fill color", "fill", "#ffffff", nodesOnly)
  ui.toolColor(colors, "stroke", "pen", "Line color", "stroke", "#4a5564")
  ui.toolColor(colors, "textColor", "fontColor", "Text color", "textColor", "#172033", nodesOnly)
  c[]["shadow"] = ui.quickButton(colors, "shadow", "Shadow", "shadow")

  let line = quickGroup(ui.quickbar)
  ui.toolSelect(line, "strokeWidth", "Line width", [
    ("1", "1 pt"), ("1.5", "1.5 pt"), ("2", "2 pt"), ("3", "3 pt"), ("4", "4 pt"), ("6", "6 pt")],
    proc(value: string) = gv.applyStyle(o1("strokeWidth", jnum(jsNumber(value))), "Line Width"))
  let connectionButton = iconButton("connector", "Connector style")
  proc route(style: string, extra: float64 = 0): proc() =
    result = proc() =
      let changes = newObj()
      changes["lineStyle"] = jstr(style)
      changes["route"] = jnull
      if extra != 0: changes["arcSweep"] = jnum(extra)
      gv.applyStyle(changes, "Connector Style", edgesOnly)
  var connectorEntries = @[
    lit("Orthogonal", route("orthogonal")), lit("Straight", route("straight")),
    lit("Curved", route("curved")), lit("Circular Arc", route("circular", 180))]
  connectorEntries.add MenuEntry(kind: ekNumber, label: "Arc degrees", min: 1, max: 360, step: 1,
    value: proc(): float64 =
      for item in gv.getSelection():
        if edgesOnly(item): return jsRound(numberOr(valStr(item["arcSweep"]), 180))
      180.0,
    numHandler: proc(value: float64) =
      let changes = newObj()
      changes["lineStyle"] = jstr("circular")
      changes["route"] = jnull
      changes["arcSweep"] = jnum(value)
      gv.applyStyle(changes, "Circular Arc Degrees", edgesOnly))
  connectorEntries.add lit("Flip Circular Arc", proc() = discard gv.call("flipCircularArc"))
  connectorEntries.add entries(["-", "resetWaypoints", "addWaypoint", "reverseConnector"])
  discard ui.attachDropdown(connectionButton, connectorEntries)
  line.appendChild(connectionButton)

  let font = quickGroup(ui.quickbar)
  ui.toolSelect(font, "fontFamily", "Font family", [
    ("Arial, sans-serif", "Arial"), ("Helvetica, sans-serif", "Helvetica"),
    ("Verdana, sans-serif", "Verdana"), ("Georgia, serif", "Georgia"),
    ("Courier New, monospace", "Courier New")],
    proc(value: string) = gv.applyStyle(o1("fontFamily", jstr(value)), "Font", nodesOnly), "qg-select-font")
  ui.toolSelect(font, "fontSize", "Font size", [
    ("10", "10"), ("12", "12"), ("14", "14"), ("16", "16"),
    ("18", "18"), ("24", "24"), ("32", "32"), ("48", "48")],
    proc(value: string) = gv.applyStyle(o1("fontSize", jnum(jsNumber(value))), "Font Size", nodesOnly))
  c[]["bold"] = ui.quickButton(font, "bold", "Bold (Ctrl+B)", "bold")
  c[]["italic"] = ui.quickButton(font, "italic", "Italic (Ctrl+I)", "italic")
  c[]["underline"] = ui.quickButton(font, "underline", "Underline (Ctrl+U)", "underline")

  let align = quickGroup(ui.quickbar)
  ui.quickButton(align, "textLeft", "Align text left", "textLeft")
  ui.quickButton(align, "textCenter", "Align text center", "textCenter")
  ui.quickButton(align, "textRight", "Align text right", "textRight")

  let arrange = quickGroup(ui.quickbar)
  ui.quickButton(arrange, "toFront", "Bring to front", "toFront")
  ui.quickButton(arrange, "toBack", "Send to back", "toBack")
  ui.quickButton(arrange, "duplicate", "Duplicate (Ctrl+D)", "duplicate")
  ui.quickButton(arrange, "star", "Save as block", "addToScratchpad")
  ui.quickButton(arrange, "trash", "Delete", "delete")
  ui.stage.appendChild(ui.quickbar)

  # Zoom dock ----------------------------------------------------------------
  ui.zoomDock = div0("qg-zoomdock")
  let zoomOut = iconButton("minus", "Zoom out")
  zoomOut.on("click", proc(e: Event) = ui.run("zoomOut"))
  ui.zoomLabel = el("button", "qg-zoomlabel")
  ui.zoomLabel.typ = "button"
  ui.zoomLabel.setAttribute("title", "Zoom")
  var zoomEntries = entries(["fit", "actualSize", "-"])
  for (label, value) in [("50%", 0.5), ("75%", 0.75), ("100%", 1.0), ("125%", 1.25),
                         ("150%", 1.5), ("200%", 2.0), ("400%", 4.0)]:
    let z = value
    zoomEntries.add lit(label, proc() = gv.setZoom(z))
  discard ui.attachDropdown(ui.zoomLabel, zoomEntries, above = true)
  let zoomIn = iconButton("plus", "Zoom in")
  zoomIn.on("click", proc(e: Event) = ui.run("zoomIn"))
  let fit = iconButton("fit", "Fit to window")
  fit.on("click", proc(e: Event) = ui.run("fit"))
  for b in [zoomOut, ui.zoomLabel, zoomIn]: ui.zoomDock.appendChild(b)
  ui.zoomDock.appendChild(div0("qg-divider"))
  ui.zoomDock.appendChild(fit)
  ui.stage.appendChild(ui.zoomDock)

  gv.on("selectionchange", proc(d: Val) = ui.refreshToolbar())
  gv.on("zoomchange", proc(d: Val) = ui.refreshToolbar())
  ui.refreshToolbar()
