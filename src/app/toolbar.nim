# Included from editorui.nim: the classic geToolbar (Toolbar.js).

proc toolButton(ui: EditorUi, container: Node, sprite, title, action: string): Node {.discardable.} =
  let button = el("a", "geButton geSprite geSprite-" & sprite)
  button.setAttribute("title", title)
  button.setAttribute("aria-label", title)
  button.setData("action", action)
  # Do not steal focus from an open label, so text commands can apply to
  # the selected range.
  button.on("mousedown", proc(e: Event) = e.preventDefault())
  button.on("click", proc(e: Event) = ui.run(action))
  container.appendChild(button)
  button

proc separator(container: Node) = container.appendChild(div0("geSeparator"))

proc toolMenu(ui: EditorUi, container, element: Node, list: openArray[MenuEntry]): Node {.discardable.} =
  ## A menu button (sprite or text label) with a classic dropdown.
  let wrapper = div0("geMenuWrapper")
  wrapper.appendChild(element)
  wrapper.appendChild(ui.attachDropdown(element, list))
  container.appendChild(wrapper)
  element

proc toolSelect(ui: EditorUi, container: Node, key, title: string, values: openArray[(string, string)],
                handler: proc(value: string)) =
  let select = el("select", "geToolbarSelect")
  select.setAttribute("title", title)
  select.fillOptions(values)
  select.on("change", proc(e: Event) = handler(select.value))
  container.appendChild(select)
  ui.toolbar.controls[key] = select

proc toolColor(ui: EditorUi, container: Node, key, sprite, title, property, fallback: string,
               predicate: Predicate = nil) =
  let wrapper = el("label", "geColorItem")
  wrapper.setAttribute("title", title)
  let glyph = el("span", "geSprite geSprite-" & sprite)
  let input = createElement("input")
  input.typ = "color"
  input.value = fallback
  # Live preview against the selection latched when the picker opened.
  ui.bindLiveStyle(input, proc(value: string): Val = o1(property, jstr(value)), title, predicate)
  wrapper.appendChild(glyph)
  wrapper.appendChild(input)
  container.appendChild(wrapper)
  ui.toolbar.controls[key] = input

proc refreshToolbar(ui: EditorUi) =
  let gv = ui.graph
  let controls = ui.toolbar.controls
  if controls.hasKey("zoom"): controls["zoom"].text = jsStr(jsRound(gv.zoom * 100)) & "%"
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
  let toggles = [("bold", num(gv.getCommonStyle("fontWeight", jnum(400))) >= 700),
                 ("italic", gv.getCommonStyle("italic", jfalse).isTrue),
                 ("underline", gv.getCommonStyle("underline", jfalse).isTrue),
                 ("shadow", gv.getCommonStyle("shadow", jfalse).isTrue)]
  for (key, on) in toggles:
    if controls.hasKey(key): controls[key].toggleClass("geChecked", on)

proc buildToolbar(ui: EditorUi, container: Node) =
  let gv = ui.graph
  let c = ui.toolbar.controls.addr

  let viewButton = el("a", "geButton geSprite geSprite-formatpanel")
  viewButton.setAttribute("title", "View")
  ui.toolMenu(container, viewButton, entries(["sidebar", "formatPanel", "-", "grid", "guides", "pageView"]))
  separator(container)

  let zoom = el("a", "geLabel")
  zoom.setAttribute("title", "Zoom")
  zoom.style("minWidth", "36px")
  zoom.style("textAlign", "center")
  c[]["zoom"] = zoom
  var zoomEntries = entries(["fit", "actualSize", "-"])
  for (label, value) in [("50%", 0.5), ("75%", 0.75), ("100%", 1.0), ("125%", 1.25),
                         ("150%", 1.5), ("200%", 2.0), ("400%", 4.0)]:
    let z = value
    zoomEntries.add lit(label, proc() = gv.setZoom(z))
  ui.toolMenu(container, zoom, zoomEntries)
  separator(container)
  ui.toolButton(container, "zoomin", "Zoom In", "zoomIn")
  ui.toolButton(container, "zoomout", "Zoom Out", "zoomOut")

  separator(container)
  ui.toolButton(container, "undo", "Undo (Ctrl+Z)", "undo")
  ui.toolButton(container, "redo", "Redo (Ctrl+Y)", "redo")

  separator(container)
  ui.toolButton(container, "delete", "Delete", "delete")
  ui.toolButton(container, "duplicate", "Duplicate (Ctrl+D)", "duplicate")

  separator(container)
  ui.toolButton(container, "tofront", "To Front", "toFront")
  ui.toolButton(container, "toback", "To Back", "toBack")

  separator(container)
  ui.toolColor(container, "fill", "fillcolor", "Fill Color", "fill", "#ffffff", nodesOnly)
  ui.toolColor(container, "stroke", "strokecolor", "Line Color", "stroke", "#4a5564")
  ui.toolColor(container, "textColor", "fontcolor", "Font Color", "textColor", "#172033", nodesOnly)
  c[]["shadow"] = ui.toolButton(container, "shadow", "Shadow", "shadow")

  separator(container)
  let connectionButton = el("a", "geButton geSprite geSprite-connection")
  connectionButton.setAttribute("title", "Connector Style")
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
  connectorEntries.add MenuEntry(kind: ekNumber, label: "Arc Degrees", min: 1, max: 360, step: 1,
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
  ui.toolMenu(container, connectionButton, connectorEntries)

  separator(container)
  c[]["bold"] = ui.toolButton(container, "bold", "Bold", "bold")
  c[]["italic"] = ui.toolButton(container, "italic", "Italic", "italic")
  c[]["underline"] = ui.toolButton(container, "underline", "Underline", "underline")

  separator(container)
  ui.toolButton(container, "left", "Align Text Left", "textLeft")
  ui.toolButton(container, "center", "Align Text Center", "textCenter")
  ui.toolButton(container, "right", "Align Text Right", "textRight")

  separator(container)
  ui.toolSelect(container, "fontFamily", "Font Family", [
    ("Arial, sans-serif", "Arial"), ("Helvetica, sans-serif", "Helvetica"),
    ("Verdana, sans-serif", "Verdana"), ("Georgia, serif", "Georgia"),
    ("Courier New, monospace", "Courier New")],
    proc(value: string) = gv.applyStyle(o1("fontFamily", jstr(value)), "Font", nodesOnly))
  ui.toolSelect(container, "fontSize", "Font Size", [
    ("10", "10"), ("12", "12"), ("14", "14"), ("16", "16"),
    ("18", "18"), ("24", "24"), ("32", "32"), ("48", "48")],
    proc(value: string) = gv.applyStyle(o1("fontSize", jnum(jsNumber(value))), "Font Size", nodesOnly))
  ui.toolSelect(container, "strokeWidth", "Line Width", [
    ("1", "1 pt"), ("1.5", "1.5 pt"), ("2", "2 pt"), ("3", "3 pt"), ("4", "4 pt"), ("6", "6 pt")],
    proc(value: string) = gv.applyStyle(o1("strokeWidth", jnum(jsNumber(value))), "Line Width"))

  gv.on("selectionchange", proc(d: Val) = ui.refreshToolbar())
  gv.on("zoomchange", proc(d: Val) = ui.refreshToolbar())
  ui.refreshToolbar()
