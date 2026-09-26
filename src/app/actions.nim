# Included from editorui.nim: the action registry (Actions.js).

proc add(ui: EditorUi, name, label: string, handler: proc(), shortcut = "",
         checked: proc(): bool = nil) =
  ui.actions[name] = Action(name: name, label: label, handler: handler,
                            shortcut: shortcut, checked: checked)

proc run*(ui: EditorUi, name: string) =
  let action = ui.actions.getOrDefault(name, nil)
  if action != nil: action.handler()

proc selectedTable(gv: View): Val =
  for item in gv.getSelection():
    if item.eqs("shape", "table"): return item
  nil

proc selectedCell(gv: View): Val =
  let cell = gv.call("getSelectedTableCell")
  if truthy(cell): cell else: nil

proc cellBox(cell: Val): Val =
  result = newObj()
  for key in ["row", "column", "x", "y", "width", "height"]: result.put(key, cell.get(key))

proc installActions(ui: EditorUi) =
  let gv = ui.graph
  let g = gv.g
  let editor = ui.editor
  proc call0(name: string): proc() =
    result = proc() = discard gv.call(name)
  proc styled(json, undefKey, label: string): proc() =
    result = proc() =
      let changes = parseJson(json)
      if undefKey.len > 0: changes.put(undefKey, nil)
      gv.applyStyle(changes, label)
  proc undefs(keys: openArray[string]): Val =
    result = newObj()
    for k in keys: result.put(k, nil)

  ui.add("new", "New…", proc() = editor.newDocument(), "Ctrl+N")
  ui.add("open", "Open Diagram…", proc() = ui.fileInput.click(), "Ctrl+O")
  ui.add("openFile", "Open Local File…", proc() = ui.fileInput.click())
  ui.add("save", "Save", proc() = gv.saveLocal(), "Ctrl+S")
  ui.add("saveBrowser", "Save in Browser", proc() = gv.saveLocal())
  ui.add("load", "Load from Browser", proc() = gv.loadLocal())
  ui.add("download", "Download JSON", proc() = editor.download())
  ui.add("exportPng", "Export PNG", proc() = gv.exportPng())
  ui.add("export", "Export…", proc() = gv.exportPng())
  ui.add("undo", "Undo", proc() = g.undo(), "Ctrl+Z")
  ui.add("redo", "Redo", proc() = g.redo(), "Ctrl+Y")
  # Copy and cut also publish the selection to the system clipboard, so an
  # editor window served from another address can receive it.
  ui.add("cut", "Cut", proc() =
    g.copy()
    ui.writeSelectionToSystemClipboard()
    g.removeSelection(), "Ctrl+X")
  ui.add("copy", "Copy", proc() =
    g.copy()
    ui.writeSelectionToSystemClipboard(), "Ctrl+C")
  ui.add("paste", "Paste", proc() = discard gv.call("paste", jnull), "Ctrl+V")
  ui.add("duplicate", "Duplicate", call0("duplicate"), "Ctrl+D")
  ui.add("delete", "Delete", call0("removeSelection"), "Delete")
  ui.add("selectAll", "Select All", proc() = discard gv.call("selectByType", jnull), "Ctrl+A")
  ui.add("selectVertices", "Select Vertices", proc() = discard gv.call("selectByType", jstr("node")), "Ctrl+Shift+I")
  ui.add("selectEdges", "Select Edges", proc() = discard gv.call("selectByType", jstr("edge")), "Ctrl+Shift+E")
  ui.add("toFront", "To Front", proc() = discard gv.call("changeZ", jtrue))
  ui.add("toBack", "To Back", proc() = discard gv.call("changeZ", jfalse))
  ui.add("group", "Group", call0("groupSelection"), "Ctrl+G")
  ui.add("ungroup", "Ungroup", call0("ungroupSelection"), "Ctrl+Shift+G")
  ui.add("lock", "Lock/Unlock", call0("toggleLock"), "Ctrl+L")
  ui.add("enterGroup", "Enter Group", call0("enterGroup"))
  ui.add("exitGroup", "Exit Group", call0("exitGroup"), "Escape")
  ui.add("removeFromGroup", "Remove from Group", call0("removeFromGroup"))
  ui.add("autosize", "Autosize", call0("autosizeSelection"))
  ui.add("copySize", "Copy Size", call0("copySize"))
  ui.add("pasteSize", "Paste Size", call0("pasteSize"))
  ui.add("clearLabels", "Clear Labels", call0("clearLabels"))
  ui.add("deleteAll", "Delete All", call0("deleteAll"))
  ui.add("selectNone", "Select None", proc() = discard gv.call("setSelection", newArr()), "Ctrl+Shift+A")
  ui.add("pasteHere", "Paste Here", proc() =
    discard gv.call("paste", if ui.contextPoint == nil: jnull else: ui.contextPoint))
  ui.add("resetView", "Reset View", call0("resetView"), "Ctrl+H")
  ui.add("fitPage", "Fit Page", proc() = discard gv.call("fitPage", jfalse))
  ui.add("fitPageWidth", "Fit Page Width", proc() = discard gv.call("fitPage", jtrue))
  ui.add("pageSetup", "Page Setup…", proc() =
    discard gv.call("setSelection", newArr())
    ui.updateFormatTabs(false)
    ui.openPanel("inspector", "diagram")
    let paper = ui.inspectorPanel.query("[data-card=paper]")
    if not paper.isNil: paper.call("scrollIntoView", jsJson("{\"block\":\"start\"}")))
  ui.add("print", "Print…", proc() = gv.print(), "Ctrl+P")
  ui.add("solid", "Solid", styled("{\"dashed\":false}", "dashPattern", "Solid"))
  ui.add("dashed", "Dashed", styled("{\"dashed\":true}", "dashPattern", "Dashed"))
  ui.add("dotted", "Dotted", styled("{\"dashed\":true,\"dashPattern\":[1,3]}", "", "Dotted"))
  ui.add("rounded", "Rounded", proc() =
    let radius = if num(gv.getCommonStyle("radius", jnum(0))) > 0: 0.0 else: 12.0
    gv.applyStyle(o1("radius", jnum(radius)), "Rounded", nodesOnly))
  ui.add("saveAs", "Save As…", proc() =
    let (ok, name) = prompt("File name", editor.filename)
    if not ok: return
    editor.filename = if name.toLowerAscii().endsWith(".json"): name else: name & ".json"
    editor.download(), "Ctrl+Shift+S")
  ui.add("openLink", "Open Link", proc() =
    let selection = gv.getSelection()
    let cell = selectedCell(gv)
    let link = if cell != nil: cell["cell"]["link"]
               elif selection.len > 0: selection[0]["link"] else: nil
    if truthy(link): discard gv.call("openLink", link)
    else: ui.toast("The selection has no link"))
  ui.add("editDiagram", "Edit Diagram…", proc() = ui.editDiagram())
  ui.add("svgToMxGraph", "SVG to mxGraph…", proc() = ui.showSvgToMxGraphDialog())
  # Keep the historic action ids so old menus and shortcuts still resolve.
  ui.add("editImage", "Edit Media…", proc() = ui.editMedia(), "Alt+Shift+I")
  ui.add("layers", "Layers…", proc() = ui.showLayers(), "Ctrl+Shift+L")
  ui.add("outline", "Outline", proc() = ui.toggleOutline())
  ui.add("image", "Insert Media…", proc() = ui.insertMedia())
  ui.add("collapseExpand", "Collapse / Expand", call0("toggleFold"))
  ui.add("tooltips", "Tooltips", proc() =
    g.tooltipsEnabled = not g.tooltipsEnabled
    if not g.tooltipsEnabled: gv.hideTooltip()
    ui.toast(if g.tooltipsEnabled: "Tooltips on" else: "Tooltips off"))
  ui.add("autosave", "Autosave", proc() = ui.toggleAutosave())
  ui.add("pageScale", "Page Scale…", proc() =
    let (ok, value) = prompt("Page scale (%)", jsStr(jsRound(g.pageScale * 100)))
    if not ok: return
    let scale = clamp(numVal(value, 100), 10, 400) / 100
    gv.setDiagramOptions(o1("pageScale", jnum(scale))))
  ui.add("addToScratchpad", "Save as Block…", proc() = ui.addToScratchpad(), "Ctrl+Shift+B")
  ui.add("runScript", "Run Script", proc() = ui.runScript(), "Ctrl+Enter")
  ui.add("stopScript", "Stop Script", proc() = ui.stopScript(), "Ctrl+.")
  ui.add("runScriptFrom", "Run from Here", proc() =
    let item = ui.selectedScriptBlock()
    if item != nil: ui.runScript(@[idOf(item)])
    else: ui.toast("Select a script block to run from"))
  ui.add("scriptPanel", "Script Blocks", proc() = ui.openPanel("script"))
  ui.add("scriptExample", "Insert Script Example", proc() = ui.insertScriptExample())
  ui.add("clearConsole", "Clear Console", proc() = ui.clearConsole())

  ui.add("insertTable", "Insert Table", proc() = discard editor.addAtCenter("table"))
  ui.add("insertHtml", "Insert HTML Block…", proc() = ui.editHtml())
  ui.add("editHtml", "Edit HTML…", proc() =
    let selection = gv.getSelection()
    ui.editHtml(if selection.len > 0: selection[0] else: nil))
  proc tableSize(rows, columns: float64): proc() =
    result = proc() = discard gv.call("changeTableSize", nilToNull(selectedTable(gv)), jnum(rows), jnum(columns))
  ui.add("tableAddRow", "Insert Row", tableSize(1, 0))
  ui.add("tableRemoveRow", "Delete Row", tableSize(-1, 0))
  ui.add("tableAddColumn", "Insert Column", tableSize(0, 1))
  ui.add("tableRemoveColumn", "Delete Column", tableSize(0, -1))
  ui.add("tableInsertRowAbove", "Insert Row Above", proc() =
    let cell = selectedCell(gv)
    let table = if cell != nil: cell["node"] else: selectedTable(gv)
    discard gv.call("insertTableRow", nilToNull(table), if cell != nil: cell["startRow"] else: jnum(0)))
  ui.add("tableInsertRowBelow", "Insert Row Below", proc() =
    let cell = selectedCell(gv)
    let table = if cell != nil: cell["node"] else: selectedTable(gv)
    let index = if cell != nil: jnum(num(cell["endRow"]) + 1)
                elif table != nil: table["rows"] else: jnum(0)
    discard gv.call("insertTableRow", nilToNull(table), index))
  ui.add("tableDeleteRow", "Delete Row", proc() =
    let cell = selectedCell(gv)
    discard gv.call("deleteTableRow", nilToNull(if cell != nil: cell["node"] else: selectedTable(gv)),
                    if cell != nil: cell["startRow"] else: jnull))
  ui.add("tableInsertColumnLeft", "Insert Column Left", proc() =
    let cell = selectedCell(gv)
    let table = if cell != nil: cell["node"] else: selectedTable(gv)
    discard gv.call("insertTableColumn", nilToNull(table), if cell != nil: cell["startColumn"] else: jnum(0)))
  ui.add("tableInsertColumnRight", "Insert Column Right", proc() =
    let cell = selectedCell(gv)
    let table = if cell != nil: cell["node"] else: selectedTable(gv)
    let index = if cell != nil: jnum(num(cell["endColumn"]) + 1)
                elif table != nil: table["columns"] else: jnum(0)
    discard gv.call("insertTableColumn", nilToNull(table), index))
  ui.add("tableDeleteColumn", "Delete Column", proc() =
    let cell = selectedCell(gv)
    discard gv.call("deleteTableColumn", nilToNull(if cell != nil: cell["node"] else: selectedTable(gv)),
                    if cell != nil: cell["startColumn"] else: jnull))
  ui.add("tableMergeCells", "Merge Cells", proc() =
    let cell = selectedCell(gv)
    if cell == nil:
      ui.toast("Select a table cell first")
      return
    if not truthy(gv.call("mergeTableCells", cell["node"], cell["startRow"], cell["startColumn"],
                          cell["endRow"], cell["endColumn"])):
      ui.toast("No adjacent cell is available to merge"))
  for (name, label) in [("tableUnmergeCell", "Unmerge Cell"), ("tableSplitCell", "Split Cell")]:
    let actionName = if name == "tableUnmergeCell": "unmergeTableCell" else: "splitTableCell"
    ui.add(name, label, proc() =
      let cell = selectedCell(gv)
      if cell == nil or not truthy(gv.call(actionName, cell["node"], cell["row"], cell["column"])):
        ui.toast("The selected cell is not merged"))
  ui.add("tableHeaderRow", "Toggle Header Row", proc() =
    let table = selectedTable(gv)
    if table == nil:
      ui.toast("Select a table first")
      return
    let changes = newObj()
    changes["headerRow"] = jbool(not truthy(table["headerRow"]))
    changes["headerFill"] = if truthy(table["headerFill"]): table["headerFill"] else: jstr("#eef1f6")
    gv.applyStyle(changes, "Header Row", proc(item: Val): bool = item.eqs("shape", "table")))
  ui.add("editCell", "Edit Cell…", proc() =
    let table = selectedTable(gv)
    if table == nil:
      ui.toast("Select a table first")
      return
    let corner = newObj()
    corner["x"] = jnum(num(table["x"]) + 1)
    corner["y"] = jnum(num(table["y"]) + 1)
    let point = if ui.contextPoint != nil: ui.contextPoint else: corner
    var cell = gv.call("tableCellAt", table, point)
    if not truthy(cell): cell = gv.call("tableCellAt", table, corner)
    if truthy(cell): discard gv.call("startTextEdit", table, cell))
  for (name, label, arg) in [("alignLeft", "Align Left", "left"), ("alignCenter", "Align Center", "center"),
      ("alignRight", "Align Right", "right"), ("alignTop", "Align Top", "top"),
      ("alignMiddle", "Align Middle", "middle"), ("alignBottom", "Align Bottom", "bottom")]:
    let side = arg
    ui.add(name, label, proc() = discard gv.call("alignSelection", jstr(side)))
  ui.add("distributeHorizontal", "Distribute Horizontally", proc() =
    discard gv.call("distributeSelection", jstr("horizontal")))
  ui.add("distributeVertical", "Distribute Vertically", proc() =
    discard gv.call("distributeSelection", jstr("vertical")))
  ui.add("rotate90", "Rotate 90°", proc() = discard gv.call("rotateSelection", jnum(90)))
  ui.add("flipHorizontal", "Flip Horizontal", proc() = discard gv.call("flipSelection", jstr("horizontal")))
  ui.add("flipVertical", "Flip Vertical", proc() = discard gv.call("flipSelection", jstr("vertical")))
  ui.add("resetWaypoints", "Reset Waypoints", call0("resetWaypoints"))
  ui.add("addWaypoint", "Add Waypoint", proc() =
    discard gv.call("addWaypointToSelection", if ui.contextPoint == nil: jnull else: ui.contextPoint))
  ui.add("reverseConnector", "Reverse Connector", call0("reverseEdges"))
  ui.add("copyStyle", "Copy Style", call0("copyStyle"), "Ctrl+Shift+C")
  ui.add("pasteStyle", "Paste Style", call0("pasteStyle"), "Ctrl+Shift+V")
  ui.add("setBookmark", "Set Bookmark", proc() =
    let selection = gv.getSelection()
    if selection.len == 0: return
    let selected = selection[0]
    gv.applyStyle(o1("bookmark", jtrue), "Set Bookmark")
    ui.toast("Bookmark set on " & (if truthy(selected["text"]): str(selected["text"]) else: idOf(selected))),
    "Ctrl+Shift+R")
  ui.add("setDefaultStyle", "Set as Default Style", call0("setDefaultStyle"), "Ctrl+Shift+D")
  ui.add("clearDefaultStyle", "Clear Default Style", call0("clearDefaultStyle"))
  ui.add("zoomIn", "Zoom In", call0("zoomIn"), "Ctrl++")
  ui.add("zoomOut", "Zoom Out", call0("zoomOut"), "Ctrl+-")
  ui.add("actualSize", "Actual Size", call0("zoomActual"))
  ui.add("fit", "Fit Window", call0("fit"))
  ui.add("grid", "Toggle Grid", proc() =
    gv.setDiagramOptions(o1("gridEnabled", jbool(not g.gridEnabled)))
    ui.toast(if g.gridEnabled: "Grid enabled" else: "Grid disabled"))
  ui.add("pageView", "Page View", proc() =
    gv.setDiagramOptions(o1("pageView", jbool(not g.pageView))), "", proc(): bool = g.pageView)
  ui.add("connectionArrows", "Connection Arrows", proc() =
    gv.setDiagramOptions(o1("connectionArrows", jbool(not g.connectionArrows)))
    gv.drawOverlay())
  ui.add("connectionPoints", "Connection Points", proc() =
    gv.setDiagramOptions(o1("connectionPoints", jbool(not g.connectionPoints)))
    gv.drawOverlay())
  ui.add("guides", "Guides", proc() =
    gv.setDiagramOptions(o1("guidesEnabled", jbool(not g.guidesEnabled))))
  ui.add("sidebar", "Shapes Panel", proc() = ui.togglePane("sidebar"))
  ui.add("formatPanel", "Format Panel", proc() = ui.togglePane("inspector"))
  ui.add("portMode", "Switch Port Mode (Unity)", proc() =
    g.portMode = if g.portMode == "unity": "outline" else: "unity"
    gv.drawOverlay()
    ui.toast("Port mode: " & g.portMode))
  proc editSelection() =
    let cell = selectedCell(gv)
    if cell != nil:
      discard gv.call("startTextEdit", cell["node"], cellBox(cell))
      return
    let selection = gv.getSelection()
    if selection.len > 0: discard gv.call("startTextEdit", selection[0])
  ui.add("editText", "Edit Text", editSelection)
  ui.add("edit", "Edit", editSelection, "F2 / Enter")
  ui.add("editStyle", "Edit Style…", proc() = ui.editStyle(), "Ctrl+E")
  ui.add("editData", "Edit Data…", proc() = ui.editData(), "Ctrl+M")
  ui.add("editTooltip", "Edit Tooltip…", proc() =
    let selection = gv.getSelection()
    if selection.len == 0: return
    let (ok, value) = prompt("Tooltip", valStr(selection[0]["tooltip"]))
    if not ok: return
    let tip = jsTrim(value)
    let changes = newObj()
    changes.put("tooltip", if tip.len > 0: jstr(tip) else: nil)
    gv.applyStyle(changes, "Edit Tooltip"), "Alt+Shift+T")
  ui.add("editLink", "Edit Link…", proc() =
    if gv.isEditingText():
      let (ok, textLink) = prompt("Hyperlink for selected text (leave empty to remove)", "https://")
      if not ok: return
      let link = jsTrim(textLink)
      discard gv.execTextCommand(if link.len > 0: "createLink" else: "unlink", link, link.len > 0)
      return
    let selection = gv.getSelection()
    if selection.len == 0: return
    let cell = selectedCell(gv)
    let current = if cell != nil: cell["cell"]["link"] else: selection[0]["link"]
    let (ok, value) = prompt("Link URL (leave empty to remove)",
                             if truthy(current): str(current) else: "https://")
    if not ok: return
    let link = jsTrim(value)
    let changes = newObj()
    changes.put("link", if link.len > 0: jstr(link) else: nil)
    gv.applyStyle(changes, if link.len > 0: "Edit Link" else: "Remove Link"), "Alt+Shift+L")
  # While a label is open these act on the selected range inside it, as the
  # classic editor's text toolbar does.
  ui.add("bold", "Bold", proc() =
    if gv.execTextCommand("bold"): return
    let weight = if num(gv.getCommonStyle("fontWeight", jnum(400))) >= 700: 400.0 else: 700.0
    gv.applyStyle(o1("fontWeight", jnum(weight)), "Bold", nodesOnly), "Ctrl+B")
  ui.add("italic", "Italic", proc() =
    if gv.execTextCommand("italic"): return
    gv.applyStyle(o1("italic", jbool(not truthy(gv.getCommonStyle("italic", jfalse)))), "Italic", nodesOnly), "Ctrl+I")
  ui.add("underline", "Underline", proc() =
    if gv.execTextCommand("underline"): return
    gv.applyStyle(o1("underline", jbool(not truthy(gv.getCommonStyle("underline", jfalse)))), "Underline", nodesOnly), "Ctrl+U")
  ui.add("strikethrough", "Strikethrough", proc() =
    if gv.execTextCommand("strikeThrough"): return
    gv.applyStyle(o1("strikethrough", jbool(not truthy(gv.getCommonStyle("strikethrough", jfalse)))),
                  "Strikethrough", nodesOnly))
  for (name, label, command, message) in [
      ("subscript", "Subscript", "subscript", "Open a label to format part of it"),
      ("superscript", "Superscript", "superscript", "Open a label to format part of it"),
      ("unorderedlist", "Bulleted List", "insertUnorderedList", "Open a label to add a list"),
      ("orderedlist", "Numbered List", "insertOrderedList", "Open a label to add a list"),
      ("indent", "Increase Indent", "indent", "Open a label to indent it"),
      ("outdent", "Decrease Indent", "outdent", "Open a label to outdent it")]:
    let cmd = command
    let msg = message
    ui.add(name, label, proc() =
      if not gv.execTextCommand(cmd): ui.toast(msg))
  ui.add("removeFormat", "Clear Formatting", proc() =
    if gv.execTextCommand("removeFormat"): return
    gv.applyStyle(undefs(["richText", "bold", "italic", "underline", "strikethrough"]),
                  "Clear Formatting", nodesOnly))
  ui.add("textColor", "Text Colour…", proc() =
    let (ok, value) = prompt("Text colour", valStr(gv.getCommonStyle("textColor", jstr("#172033"))))
    if not ok: return
    if gv.execTextCommand("foreColor", value, true): return
    gv.applyStyle(o1("textColor", jstr(value)), "Text Color", nodesOnly))
  ui.add("shadow", "Shadow", proc() =
    gv.applyStyle(o1("shadow", jbool(not truthy(gv.getCommonStyle("shadow", jfalse)))), "Shadow", nodesOnly))
  for (name, label, align) in [("textLeft", "Align Text Left", "left"),
      ("textCenter", "Align Text Center", "center"), ("textRight", "Align Text Right", "right")]:
    let a = align
    ui.add(name, label, proc() = gv.applyStyle(o1("textAlign", jstr(a)), "Text Align", nodesOnly))
  ui.add("about", "About Pixel Graph", proc() =
    ui.showDialog("Pixel Graph",
      "A canvas-native diagram editor with worker culling, WebGPU/WebGL presentation, and Visio-like pixel controls. No SVG is used in the diagram viewport."))

# ------------------------------------------------------------------- menus --

proc installMenus(ui: EditorUi) =
  # The classic GraphEditor hierarchy.
  ui.menuDefinitions = @[
    ("File", @["new", "open", "-", "save", "saveAs", "-", "export", "-", "pageSetup", "print"]),
    ("Edit", @["undo", "redo", "-", "cut", "copy", "paste", "delete", "-",
      "duplicate", "addToScratchpad", "-", "editData", "editTooltip", "-", "editStyle", "-",
      "edit", "-", "editLink", "openLink", "-",
      "selectVertices", "selectEdges", "selectAll", "selectNone", "-", "lock"]),
    ("View", @["sidebar", "formatPanel", "outline", "layers", "-",
      "zoomIn", "zoomOut", "actualSize", "-",
      "fit", "fitPage", "fitPageWidth", "resetView", "-",
      "grid", "pageView", "pageScale", "connectionArrows", "connectionPoints",
      "guides", "tooltips"]),
    ("Arrange", @["toFront", "toBack", "-", "group", "ungroup", "removeFromGroup",
      "enterGroup", "exitGroup", "collapseExpand", "-", "lock", "autosize", "-",
      "alignLeft", "alignCenter", "alignRight", "alignTop", "alignMiddle", "alignBottom", "-",
      "distributeHorizontal", "distributeVertical", "-", "rotate90", "flipHorizontal", "flipVertical"]),
    ("Extras", @["svgToMxGraph", "-",
      "portMode", "addWaypoint", "resetWaypoints", "reverseConnector", "-",
      "solid", "dashed", "dotted", "rounded", "shadow", "-",
      "setDefaultStyle", "clearDefaultStyle"]),
    ("Script", @["runScript", "stopScript", "runScriptFrom", "-", "scriptPanel", "scriptExample",
      "clearConsole"]),
    ("Help", @["about"])]

proc buildMenus(ui: EditorUi, container: Node) =
  for (name, list) in ui.menuDefinitions:
    let trigger = el("button", "qg-menubtn")
    trigger.typ = "button"
    trigger.text = name
    discard ui.attachDropdown(trigger, entries(list))
    container.appendChild(trigger)

proc buildMenuPanel(ui: EditorUi) =
  ## Phones: every menu as an expandable group in a sheet.
  let (root, content) = panel("Menu", "menu")
  ui.menuPanel = root
  let quick = div0("qg-menu-quick")
  for (iconName, label, action) in [("folder", "Open", "open"), ("save", "Save", "save"),
                                    ("export", "Export", "exportPng"), ("layers", "Layers", "layers"),
                                    ("map", "Outline", "outline"), ("page", "Page", "pageSetup")]:
    let b = textButton(label, "qg-quick-tile", iconName)
    let a = action
    b.on("click", proc(e: Event) =
      ui.closeSheet()
      ui.run(a))
    quick.appendChild(b)
  content.appendChild(quick)
  for index, (name, list) in ui.menuDefinitions:
    let group = el("details", "qg-menu-group")
    if index == 0: group.setAttribute("open", "")
    let summary = el("summary", "qg-menu-group-title")
    summary.text = name
    group.appendChild(summary)
    let items = div0("qg-menu qg-menu-inline")
    ui.addMenuItems(items, entries(list))
    group.appendChild(items)
    content.appendChild(group)
