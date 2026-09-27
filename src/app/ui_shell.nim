# Included from editorui.nim: the shell (top bar, rail, docks, stage, tab
# bar, sheet), popups and the status line.

proc createShell(ui: EditorUi) =
  let root = ui.container
  ui.topbar = el("header", "qg-topbar")
  ui.workspace = div0("qg-workspace")
  ui.rail = el("nav", "qg-rail")
  ui.rail.setAttribute("aria-label", "Tools")
  ui.leftDock = el("aside", "qg-dock qg-dock-left")
  ui.stage = el("main", "qg-stage")
  ui.rightDock = el("aside", "qg-dock qg-dock-right")
  # The canvas view owns everything inside this element.
  ui.diagram = div0("qg-canvas")
  ui.stage.appendChild(ui.diagram)
  ui.floatLayer = div0("qg-floatlayer")
  ui.stage.appendChild(ui.floatLayer)
  for c in [ui.rail, ui.leftDock, ui.stage, ui.rightDock]: ui.workspace.appendChild(c)
  root.appendChild(ui.topbar)
  root.appendChild(ui.workspace)

  ui.tabbar = el("nav", "qg-tabbar")
  ui.tabbar.setAttribute("aria-label", "Editor sections")
  root.appendChild(ui.tabbar)

  ui.sheetBackdrop = div0("qg-sheet-backdrop")
  ui.sheet = el("section", "qg-sheet")
  ui.sheet.setAttribute("role", "dialog")
  let sheetHead = el("header", "qg-sheet-head")
  sheetHead.appendChild(div0("qg-sheet-grabber"))
  ui.sheetTitle = el("h2", "qg-sheet-title")
  sheetHead.appendChild(ui.sheetTitle)
  let sheetClose = iconButton("close", "Close", "qg-sheet-close")
  sheetClose.on("click", proc(e: Event) = ui.closeSheet())
  sheetHead.appendChild(sheetClose)
  ui.sheetBody = div0("qg-sheet-body")
  ui.sheet.appendChild(sheetHead)
  ui.sheet.appendChild(ui.sheetBody)
  root.appendChild(ui.sheetBackdrop)
  root.appendChild(ui.sheet)
  ui.sheetBackdrop.on("click", proc(e: Event) = ui.closeSheet())
  ui.installSheetGestures(sheetHead)

  ui.fileInput = createElement("input")
  ui.fileInput.typ = "file"
  ui.fileInput.setProp("accept", ".json,.qochart,.xml,application/json,application/xml,text/xml")
  ui.fileInput.hidden = true
  root.appendChild(ui.fileInput)

  ui.toastElement = div0("qg-toast")
  ui.toastElement.setAttribute("role", "status")
  ui.toastElement.hidden = true
  root.appendChild(ui.toastElement)

# ------------------------------------------------------------------ popups --

proc bindMenuAction(ui: EditorUi, item: Node, name: string, handler: proc()) =
  ## Capture one action per button; loop locals are reused by Nim closures.
  item.on("click", proc(e: Event) =
    e.stopPropagation()
    ui.closeMenus()
    ui.hideContextMenu()
    if ui.layout == lmPhone: ui.closeSheet()
    if name.len > 0: ui.run(name)
    elif handler != nil: handler())

proc addMenuItems(ui: EditorUi, popup: Node, list: openArray[MenuEntry]): Node {.discardable.} =
  ## Fills a menu with action names, separators or literal entries.
  var syncs = ui.popupSyncs.getOrDefault(popup.id, @[])
  for entry in list:
    case entry.kind
    of ekSeparator:
      popup.appendChild(el("hr", "qg-menu-sep"))
    of ekNumber:
      let numberRow = el("label", "qg-menu-input")
      let numberLabel = createElement("span")
      numberLabel.text = entry.label
      let numberInput = el("input", "qg-input qg-input-sm")
      numberInput.typ = "number"
      numberInput.setProp("min", entry.min)
      numberInput.setProp("max", entry.max)
      numberInput.setProp("step", entry.step)
      let valueFn = entry.value
      let sync = proc() =
        if not same(activeElement(), numberInput): numberInput.value = jsStr(valueFn())
      sync()
      syncs.add sync
      numberInput.on("pointerdown", proc(e: Event) = e.stopPropagation())
      numberInput.on("click", proc(e: Event) = e.stopPropagation())
      numberInput.on("keydown", proc(e: Event) = e.stopPropagation())
      let h = entry.numHandler
      numberInput.on("change", proc(e: Event) =
        e.stopPropagation()
        h(jsNumber(numberInput.value)))
      numberRow.appendChild(numberLabel)
      numberRow.appendChild(numberInput)
      popup.appendChild(numberRow)
    of ekAction, ekLiteral:
      let action = if entry.kind == ekAction: ui.actions.getOrDefault(entry.name, nil) else: nil
      if entry.kind == ekAction and action == nil: continue
      let label = if action != nil: action.label else: entry.label
      let shortcut = if action != nil: action.shortcut else: entry.shortcut
      let item = el("button", "qg-menu-item")
      item.typ = "button"
      let text = el("span", "qg-menu-label")
      if action != nil and action.checked != nil:
        let check = el("span", "qg-menu-check")
        check.html = iconMarkup("check", 16)
        item.appendChild(check)
        let checked = action.checked
        let sync = proc() = item.toggleClass("is-checked", checked())
        sync()
        syncs.add sync
      text.text = label
      item.appendChild(text)
      if shortcut.len > 0:
        let keys = el("kbd", "qg-kbd")
        keys.text = shortcut
        item.appendChild(keys)
      let name = if action != nil: action.name else: ""
      let handler = entry.handler
      ui.bindMenuAction(item, name, handler)
      popup.appendChild(item)
  ui.popupSyncs[popup.id] = syncs
  popup

proc placePopover(popup, anchor: Node, above = false) =
  let r = rect(anchor)
  popup.style("left", px(max(8.0, r.left)))
  popup.style("top", px(r.bottom + 6))
  popup.hidden = false
  let p = rect(popup)
  let innerWidth = window.getNum("innerWidth")
  let innerHeight = window.getNum("innerHeight")
  if p.right > innerWidth - 8: popup.style("left", px(max(8.0, innerWidth - p.width - 8)))
  if above or (p.bottom > innerHeight - 8 and r.top > p.height + 14):
    popup.style("top", px(max(8.0, r.top - p.height - 6)))

proc attachDropdown(ui: EditorUi, trigger: Node, list: openArray[MenuEntry], above = false): Node =
  let popup = div0("qg-popover qg-menu")
  popup.setAttribute("role", "menu")
  popup.hidden = true
  ui.menuPopups.add popup
  ui.menuTriggers[popup.id] = trigger
  ui.addMenuItems(popup, list)
  body.appendChild(popup)
  trigger.setAttribute("aria-haspopup", "menu")
  trigger.on("click", proc(e: Event) =
    e.stopPropagation()
    let wasOpen = not popup.hidden
    ui.closeMenus()
    if not wasOpen:
      for sync in ui.popupSyncs.getOrDefault(popup.id, @[]): sync()
      trigger.addClass("is-active")
      placePopover(popup, trigger, above))
  popup

proc closeMenus(ui: EditorUi) =
  for popup in ui.menuPopups:
    popup.hidden = true
    let trigger = ui.menuTriggers.getOrDefault(popup.id, nilNode)
    if not trigger.isNil: trigger.removeClass("is-active")

# ------------------------------------------------------------ context menu --

proc buildContextMenu(ui: EditorUi) =
  ui.contextMenu = div0("qg-popover qg-menu qg-context")
  ui.contextMenu.setAttribute("role", "menu")
  ui.contextMenu.hidden = true
  body.appendChild(ui.contextMenu)
  ui.contextMenuBaseEntries = @["delete", "-", "cut", "copy", "-", "duplicate", "addToScratchpad", "setBookmark", "-",
    "setDefaultStyle", "-", "toFront", "toBack", "-",
    "editStyle", "editData", "editLink", "editImage"]

proc fillContextMenu(ui: EditorUi) =
  let tableCell = ui.graph.call("getSelectedTableCell")
  ui.contextMenu.dropChildren()
  ui.popupSyncs.del(ui.contextMenu.id)
  let list = if truthy(tableCell): @["editCell", "-",
      "tableInsertRowAbove", "tableInsertRowBelow", "tableDeleteRow", "-",
      "tableInsertColumnLeft", "tableInsertColumnRight", "tableDeleteColumn", "-",
      "tableMergeCells", "tableSplitCell", "-",
      "delete", "cut", "copy", "-", "editStyle", "editLink"]
    elif ui.selectedScriptBlock() != nil: @["runScriptFrom", "-"] & ui.contextMenuBaseEntries
    else: ui.contextMenuBaseEntries
  ui.addMenuItems(ui.contextMenu, entries(list))

proc showContextMenu(ui: EditorUi, data: Val) =
  let point = data["point"]
  ui.contextPoint = if point.isObj and truthy(point["world"]): point["world"] else: nil
  ui.fillContextMenu()
  if ui.layout == lmPhone:
    # An action sheet on phones.
    ui.contextMenu.hidden = false
    ui.openPanel("context")
    return
  if not same(ui.contextMenu.getNode("parentNode"), body): body.appendChild(ui.contextMenu)
  ui.contextMenu.hidden = false
  let width = ui.contextMenu.getNum("offsetWidth")
  let height = ui.contextMenu.getNum("offsetHeight")
  let innerWidth = window.getNum("innerWidth")
  let innerHeight = window.getNum("innerHeight")
  ui.contextMenu.style("left", px(max(4.0, min(num(data["clientX"]), innerWidth - width - 4))))
  ui.contextMenu.style("top", px(max(4.0, min(num(data["clientY"]), innerHeight - height - 4))))

proc hideContextMenu(ui: EditorUi) =
  if not ui.contextMenu.isNil and ui.layout != lmPhone: ui.contextMenu.hidden = true

# ------------------------------------------------------------------ status --

proc setStatusText(ui: EditorUi, value: string) =
  if not ui.statusLeft.isNil and value.len > 0: ui.statusLeft.text = value

proc updateStatus*(ui: EditorUi, stats: Val = nil) =
  let s = if stats != nil: stats elif ui.editor != nil: ui.graph.stats else: nil
  if ui.statusRight.isNil or ui.editor == nil: return
  let zoom = jsStr(jsRound(ui.graph.zoom * 100)) & "%"
  if not ui.zoomLabel.isNil: ui.zoomLabel.text = zoom
  var text = ""
  if s != nil and s.isObj:
    let memory = num(s["pixelWidth"]) * num(s["pixelHeight"]) * 4 / (1024 * 1024)
    text.add (if truthy(s["backend"]): str(s["backend"]) else: "canvas").toUpperAscii()
    if s["realtime"].isTrue: text.add " · realtime"
    elif s["worker"].isTrue:
      let bands = if truthy(s["bands"]): int(num(s["bands"])) else: 1
      text.add " · " & $bands & (if bands == 1: " worker" else: " workers")
    else: text.add " · main thread"
    text.add " · " & valStr(s["visible"]) & "/" & valStr(s["total"]) & " visible"
    text.add " · " & toFixed(memory, 1) & " MB"
    text.add " · " & valStr(s["renderMs"]) & " ms"
  ui.statusRight.text = text

proc toast*(ui: EditorUi, message: string) =
  clearTimeout(ui.toastTimer)
  ui.toastElement.text = message
  ui.toastElement.hidden = false
  ui.toastElement.addClass("is-visible")
  ui.toastTimer = setTimeout(2200, proc() =
    ui.toastTimer = 0
    ui.toastElement.removeClass("is-visible")
    ui.toastElement.hidden = true)

proc dialogShell(ui: EditorUi, width: string, cls = "qg-dialog"): (Node, Node) =
  let backdrop = div0("qg-dialog-backdrop")
  let dialog = div0(cls)
  dialog.setAttribute("role", "dialog")
  if width.len > 0: dialog.style("width", width)
  backdrop.appendChild(dialog)
  (backdrop, dialog)

proc showDialog*(ui: EditorUi, title, message: string) =
  let (backdrop, dialog) = ui.dialogShell("")
  let heading = el("h2", "qg-dialog-title")
  heading.text = title
  let text = el("p", "qg-dialog-text")
  text.text = message
  let footer = div0("qg-dialog-actions")
  let close = textButton("Close", "qg-btn qg-btn-primary")
  close.on("click", proc(e: Event) = backdrop.dropTree())
  footer.appendChild(close)
  dialog.appendChild(heading)
  dialog.appendChild(text)
  dialog.appendChild(footer)
  body.appendChild(backdrop)

# ------------------------------------------------------------------- build --

proc buildMenus(ui: EditorUi, container: Node)
proc buildMenuPanel(ui: EditorUi)
proc buildToolbar(ui: EditorUi)
proc buildSidebar(ui: EditorUi)
proc buildFormat(ui: EditorUi)
proc buildWindows(ui: EditorUi)

proc buildTopbar(ui: EditorUi) =
  let left = div0("qg-topbar-start")
  let menuButton = iconButton("menu", "Menu", "qg-only-phone")
  menuButton.on("click", proc(e: Event) = ui.openPanel("menu"))
  left.appendChild(menuButton)
  let brand = div0("qg-brand")
  let mark = div0("qg-brand-mark")
  mark.html = iconMarkup("logo", 18)
  brand.appendChild(mark)
  let word = el("span", "qg-brand-name")
  word.text = "QGraph"
  brand.appendChild(word)
  left.appendChild(brand)
  ui.docName = el("input", "qg-docname")
  ui.docName.typ = "text"
  ui.docName.setAttribute("aria-label", "Document name")
  ui.docName.setProp("spellcheck", false)
  ui.docName.value = "Untitled diagram"
  ui.docName.on("change", proc(e: Event) =
    var name = jsTrim(ui.docName.value)
    if name.len == 0: name = "Untitled diagram"
    ui.docName.value = name
    ui.editor.filename = name & ".json")
  ui.docName.on("keydown", proc(e: Event) =
    if e.key == "Enter": ui.docName.blur()
    e.stopPropagation())
  left.appendChild(ui.docName)
  ui.topbar.appendChild(left)

  ui.menubar = el("nav", "qg-menubar")
  ui.menubar.setAttribute("aria-label", "Menus")
  ui.buildMenus(ui.menubar)
  ui.topbar.appendChild(ui.menubar)

  let right = div0("qg-topbar-end")
  let undo = iconButton("undo", "Undo (Ctrl+Z)")
  undo.on("click", proc(e: Event) = ui.run("undo"))
  let redo = iconButton("redo", "Redo (Ctrl+Y)")
  redo.on("click", proc(e: Event) = ui.run("redo"))
  right.appendChild(undo)
  right.appendChild(redo)
  right.appendChild(div0("qg-divider qg-hide-phone"))
  ui.themeButton = iconButton("moon", "Dark theme")
  ui.themeButton.on("click", proc(e: Event) = ui.setTheme(if ui.theme == "dark": "light" else: "dark"))
  right.appendChild(ui.themeButton)
  ui.canvasLockButton = iconButton("unlock", "Lock canvas for panning")
  ui.canvasLockButton.on("click", proc(e: Event) = ui.setCanvasLocked(not ui.canvasLocked))
  right.appendChild(ui.canvasLockButton)
  ui.inspectorToggle = iconButton("panelRight", "Inspector", "qg-hide-phone")
  ui.inspectorToggle.on("click", proc(e: Event) = ui.togglePane("inspector"))
  right.appendChild(ui.inspectorToggle)
  ui.script.topRun = textButton("Run", "qg-btn qg-btn-run qg-hide-phone", "play")
  ui.script.topRun.setAttribute("title", "Run the script blocks (Ctrl+Enter)")
  ui.script.topRun.on("click", proc(e: Event) = ui.runScript())
  right.appendChild(ui.script.topRun)
  let exportButton = textButton("Export", "qg-btn qg-btn-primary qg-hide-phone", "export")
  discard ui.attachDropdown(exportButton, entries(["exportPng", "download", "-", "save", "saveAs", "-", "print"]))
  right.appendChild(exportButton)
  let more = iconButton("more", "More", "qg-only-phone")
  more.on("click", proc(e: Event) = ui.openPanel("menu"))
  right.appendChild(more)
  ui.topbar.appendChild(right)
  ui.setTheme(ui.theme)

proc railButton(ui: EditorUi, key, iconName, title: string, handler: proc()): Node {.discardable.} =
  result = iconButton(iconName, title, "qg-rail-btn")
  result.setData("tool", key)
  result.on("click", proc(e: Event) = handler())
  ui.railButtons[key] = result
  ui.rail.appendChild(result)

proc buildRail(ui: EditorUi) =
  ui.railButton("shapes", "shapes", "Shapes", proc() = ui.togglePane("sidebar"))
  ui.railButton("blocks", "star", "My Blocks", proc() =
    ui.openPanel("library")
    if ui.sidebar.setCategory != nil: ui.sidebar.setCategory("saved"))
  ui.railButton("script", "script", "Script: Luau blocks", proc() = ui.togglePane("script"))
  ui.rail.appendChild(div0("qg-rail-sep"))
  ui.railButton("text", "text", "Text", proc() = discard ui.editor.addAtCenter("text"))
  ui.railButton("note", "note", "Sticky note", proc() = discard ui.editor.addAtCenter("note"))
  ui.railButton("table", "table", "Table", proc() = ui.run("insertTable"))
  ui.railButton("media", "image", "Image or video", proc() = ui.run("image"))
  ui.railButton("html", "code", "HTML block", proc() = ui.run("insertHtml"))
  ui.rail.appendChild(div0("qg-rail-spacer"))
  ui.railButton("layers", "layers", "Layers", proc() = ui.run("layers"))
  ui.railButton("outline", "map", "Outline", proc() = ui.run("outline"))
  ui.railButton("page", "page", "Page setup", proc() = ui.run("pageSetup"))
  ui.railButton("help", "help", "About", proc() = ui.run("about"))

proc tabButton(ui: EditorUi, key, iconName, label: string, handler: proc()) =
  let b = el("button", "qg-tab")
  b.typ = "button"
  b.setData("tab", key)
  b.appendChild(icon(iconName, 22))
  let t = el("span", "qg-tab-label")
  t.text = label
  b.appendChild(t)
  b.on("click", proc(e: Event) = handler())
  ui.tabButtons[key] = b
  ui.tabbar.appendChild(b)

proc buildTabbar(ui: EditorUi) =
  proc toggle(key: string, open: proc()): proc() =
    result = proc() =
      let active = ui.tabButtons[key].matches(".is-active")
      if ui.sheetOpen and active: ui.closeSheet() else: open()
  ui.tabButton("shapes", "shapes", "Shapes", toggle("shapes", proc() = ui.openPanel("library")))
  ui.tabButton("script", "script", "Script", toggle("script", proc() = ui.openPanel("script")))
  ui.tabButton("style", "palette", "Style", toggle("style", proc() = ui.openPanel("inspector", "style")))
  ui.tabButton("text", "text", "Text", toggle("text", proc() = ui.openPanel("inspector", "text")))
  ui.tabButton("arrange", "arrange", "Arrange", toggle("arrange", proc() = ui.openPanel("inspector", "arrange")))
  ui.tabButton("more", "more", "More", toggle("more", proc() = ui.openPanel("menu")))

proc buildStatus(ui: EditorUi) =
  ui.statusChip = div0("qg-status")
  ui.statusLeft = el("span", "qg-status-main")
  ui.statusLeft.text = "Ready"
  ui.statusRight = el("span", "qg-status-perf")
  ui.statusChip.appendChild(ui.statusLeft)
  ui.statusChip.appendChild(ui.statusRight)
  ui.stage.appendChild(ui.statusChip)

proc buildSelectionPill(ui: EditorUi) =
  ## Phones: quick actions for the selection, above the tab bar.
  ui.selPill = div0("qg-selpill")
  proc add(iconName, title: string, handler: proc()) =
    let b = iconButton(iconName, title)
    b.on("click", proc(e: Event) = handler())
    ui.selPill.appendChild(b)
  add("edit", "Edit text", proc() = ui.run("edit"))
  add("palette", "Style", proc() = ui.openPanel("inspector", "style"))
  add("duplicate", "Duplicate", proc() = ui.run("duplicate"))
  add("play", "Run script (from this block when it is one)", proc() =
    ui.run(if ui.selectedScriptBlock() != nil: "runScriptFrom" else: "runScript"))
  add("star", "Save as block", proc() = ui.run("addToScratchpad"))
  add("trash", "Delete", proc() = ui.run("delete"))
  add("more", "More actions", proc() =
    ui.fillContextMenu()
    ui.contextMenu.hidden = false
    ui.openPanel("context"))
  ui.stage.appendChild(ui.selPill)

proc createUi(ui: EditorUi) =
  ui.buildTopbar()
  ui.buildRail()
  ui.buildMenuPanel()
  ui.buildToolbar()
  ui.buildSidebar()
  ui.buildScriptPanel()
  ui.buildFormat()
  ui.buildWindows()
  ui.buildStatus()
  ui.buildSelectionPill()
  ui.buildTabbar()
  ui.buildContextMenu()
  ui.buildTableAxisUi()

proc bindEvents(ui: EditorUi) =
  let g = ui.graph
  g.on("stats", proc(stats: Val) = ui.updateStatus(stats))
  g.on("zoomchange", proc(d: Val) =
    ui.updateStatus()
    ui.updateTableAxisGrips(-1, -1))
  g.on("selectionchange", proc(selection: Val) =
    let n = if selection == nil: 0 else: selection.len
    ui.statusLeft.text = if n > 0: $n & " selected" else: "Ready"
    ui.container.toggleClass("has-selection", n > 0)
    ui.updateTableAxisGrips(-1, -1)
    ui.updateFormat())
  g.on("diagramchange", proc(d: Val) =
    ui.updateFormat()
    ui.updateTableAxisGrips(-1, -1))
  g.on("toast", proc(d: Val) = ui.toast(valStr(d)))
  g.on("contextmenu", proc(d: Val) = ui.showContextMenu(d))
  ui.installScript()
  g.on("dropblock", proc(d: Val) =
    let point = newObj()
    point["x"] = d["x"]
    point["y"] = d["y"]
    ui.insertBlockJson(str(d["json"]), point))

  ui.fileInput.on("change", proc(e: Event) =
    let files = ui.fileInput.getNode("files")
    if not files.isNil and files.getNum("length") > 0:
      let file = files.invoke("item", 0).toNode
      var name = file.getStr("name")
      let dot = name.rfind('.')
      if dot > 0: name = name[0 ..< dot]
      ui.docName.value = name
      ui.editor.openFile(file)
    ui.fileInput.value = "")

  document.on("pointerdown", proc(e: Event) =
    let target = e.target
    if ui.layout != lmPhone and not ui.contextMenu.isNil and not ui.contextMenu.hidden and
        target.closest(".qg-context").isNil and not target.closest(".qg-stage").isNil:
      # Dismissing the menu must not also start a canvas gesture underneath it.
      ui.hideContextMenu()
      e.preventDefault()
      e.stopPropagation()
      return
    if target.closest(".qg-table-axis-menu").isNil and target.closest(".qg-table-axis-grip").isNil:
      ui.closeTableAxisMenu()
    if target.closest(".qg-menu").isNil and target.closest("[aria-haspopup]").isNil: ui.closeMenus()
    if target.closest(".qg-context").isNil: ui.hideContextMenu(), capture = true)

  document.on("keydown", proc(e: Event) =
    if e.key == "Escape": ui.closeTableAxisMenu()
    if e.key == "Escape" and ui.sheetOpen:
      ui.closeSheet()
      return
    let modifier = e.ctrlKey or e.metaKey
    if modifier and e.key == "Enter" and not e.target.matches("[contenteditable]"):
      e.preventDefault()
      ui.run("runScript")
      return
    if modifier and e.key == "." and ui.script.running:
      e.preventDefault()
      ui.run("stopScript")
      return
    if not modifier or e.target.matches("input,textarea,select,[contenteditable]"): return
    let key = e.key.toLowerAscii()
    if key == "s":
      ui.run("save")
      e.preventDefault()
    if key == "o":
      ui.run("open")
      e.preventDefault()
    if key == "n":
      ui.run("new")
      e.preventDefault()
    if key == "g":
      ui.run(if e.shiftKey: "ungroup" else: "group")
      e.preventDefault()
    if key == "l":
      ui.run("lock")
      e.preventDefault()
    if e.shiftKey and key == "c":
      ui.run("copyStyle")
      e.preventDefault()
    if e.shiftKey and key == "v":
      ui.run("pasteStyle")
      e.preventDefault()
    if e.shiftKey and key == "b":
      ui.run("addToScratchpad")
      e.preventDefault())

  window.on("resize", proc(e: Event) = ui.applyLayout())
