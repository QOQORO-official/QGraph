# Included from editorui.nim: containers, layout, popups, status.

proc createDivs(ui: EditorUi) =
  ui.menubarContainer = div0("geMenubarContainer")
  ui.toolbarContainer = div0("geToolbarContainer")
  ui.sidebarContainer = div0("geSidebarContainer")
  ui.formatContainer = div0("geSidebarContainer geFormatContainer")
  ui.diagramContainer = div0("geDiagramContainer")
  ui.footerContainer = div0("geFooterContainer")
  ui.hsplit = div0("geHsplit")
  ui.hsplit.setAttribute("title", "Collapse/Expand")

  # Static styles, matching the classic container geometry.
  ui.menubarContainer.style("top", "0px")
  ui.menubarContainer.style("left", "0px")
  ui.menubarContainer.style("right", "0px")
  ui.toolbarContainer.style("left", "0px")
  ui.toolbarContainer.style("right", "0px")
  ui.sidebarContainer.style("left", "0px")
  ui.formatContainer.style("right", "0px")
  ui.formatContainer.style("zIndex", "1")
  ui.diagramContainer.style("right", px(ui.formatWidth))
  ui.footerContainer.style("left", "0px")
  ui.footerContainer.style("right", "0px")
  ui.footerContainer.style("bottom", "0px")
  ui.hsplit.style("width", px(ui.splitSize))
  ui.hsplit.style("touchAction", "none")

  # The canvas view owns everything inside the diagram container.
  ui.diagram = createElement("div")
  ui.diagramContainer.appendChild(ui.diagram)

  for c in [ui.menubarContainer, ui.sidebarContainer, ui.formatContainer, ui.footerContainer,
            ui.diagramContainer, ui.toolbarContainer, ui.hsplit]:
    ui.container.appendChild(c)

  ui.fileInput = createElement("input")
  ui.fileInput.typ = "file"
  ui.fileInput.setProp("accept", ".json,.qochart,.xml,application/json,application/xml,text/xml")
  ui.fileInput.hidden = true
  ui.container.appendChild(ui.fileInput)

  ui.toastElement = div0("geToast")
  ui.toastElement.hidden = true
  ui.container.appendChild(ui.toastElement)

proc refresh*(ui: EditorUi, sizeDidChange = true) =
  var w = ui.container.getNum("clientWidth")
  if same(ui.container, body):
    w = body.getNum("clientWidth")
    if w == 0: w = documentElement.getNum("clientWidth")
  let effHsplitPosition = max(0.0, min(ui.hsplitPosition, w - ui.splitSize - 20))
  let tmp = ui.menubarHeight + ui.toolbarHeight + 1
  let fw = ui.formatWidth

  ui.menubarContainer.style("height", px(ui.menubarHeight))
  ui.toolbarContainer.style("top", px(ui.menubarHeight))
  ui.toolbarContainer.style("height", px(ui.toolbarHeight))
  ui.sidebarContainer.style("top", px(tmp))
  ui.sidebarContainer.style("width", px(effHsplitPosition))
  ui.formatContainer.style("top", px(tmp))
  ui.formatContainer.style("width", px(fw))
  ui.formatContainer.style("display", if fw == 0: "none" else: "")
  ui.diagramContainer.style("left", px(effHsplitPosition + ui.splitSize))
  ui.diagramContainer.style("top", px(tmp))
  ui.footerContainer.style("height", px(ui.footerHeight))
  ui.hsplit.style("top", px(tmp))
  ui.hsplit.style("bottom", px(ui.footerHeight))
  ui.hsplit.style("left", px(effHsplitPosition))
  ui.footerContainer.style("display", if ui.footerHeight == 0: "none" else: "")
  ui.diagramContainer.style("right", px(fw))
  ui.sidebarContainer.style("bottom", px(ui.footerHeight))
  ui.formatContainer.style("bottom", px(ui.footerHeight))
  ui.diagramContainer.style("bottom", px(ui.footerHeight))
  if sizeDidChange and ui.editor != nil: ui.graph.render()

proc addSplitHandler(ui: EditorUi, elt: Node, onChange: proc(value: float64)) =
  ## Drag to resize, click to collapse/expand -- as in the classic shell.
  var start = NaN
  var initial = NaN
  var ignoreClick = true
  var last = NaN
  proc getValue(): float64 =
    let v = jsParseFloat(elt.get2("style", "left").toStr)
    if v != v: 0.0 else: trunc(v)
  proc moveHandler(e: Event) =
    if start == start:
      onChange(max(0.0, initial + (e.clientX - start)))
      e.preventDefault()
      if initial != getValue():
        ignoreClick = true
        last = NaN
  elt.on("pointerdown", proc(e: Event) =
    start = e.clientX
    initial = getValue()
    ignoreClick = false
    e.preventDefault())
  elt.on("click", proc(e: Event) =
    if not ignoreClick and ui.hsplitClickEnabled:
      let next = if last == last: last else: 0.0
      last = getValue()
      onChange(next)
      e.preventDefault())
  document.on("pointermove", moveHandler)
  document.on("pointerup", proc(e: Event) =
    moveHandler(e)
    initial = NaN
    start = NaN)

proc togglePane*(ui: EditorUi, name: string) =
  if name == "sidebar":
    if ui.hsplitPosition > 0:
      ui.lastHsplitPosition = ui.hsplitPosition
      ui.hsplitPosition = 0
    else:
      ui.hsplitPosition = if ui.lastHsplitPosition != 0: ui.lastHsplitPosition else: 212
  else:
    ui.formatWidth = if ui.formatWidth > 0: 0 else: 240
  ui.refresh()

# ------------------------------------------------------------------ popups --

proc addMenuItems(ui: EditorUi, popup: Node, list: openArray[MenuEntry]): Node {.discardable.} =
  ## Fills a popup with action names, separators or literal entries.
  var syncs = ui.popupSyncs.getOrDefault(popup.id, @[])
  for entry in list:
    case entry.kind
    of ekSeparator:
      popup.appendChild(createElement("hr"))
    of ekNumber:
      let numberRow = el("label", "geMenuInputRow")
      numberRow.cssText = "display:flex;align-items:center;gap:12px;padding:7px 12px;white-space:nowrap;"
      let numberLabel = createElement("span")
      numberLabel.text = entry.label
      numberLabel.style("flex", "1")
      let numberInput = createElement("input")
      numberInput.typ = "number"
      numberInput.setProp("min", entry.min)
      numberInput.setProp("max", entry.max)
      numberInput.setProp("step", entry.step)
      numberInput.style("width", "72px")
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
      let item = el("button", "geMenuItem")
      let text = createElement("span")
      if action != nil and action.checked != nil:
        let check = el("input", "geMenuCheckbox")
        check.typ = "checkbox"
        check.setProp("tabIndex", -1)
        check.setAttribute("aria-hidden", "true")
        check.on("click", proc(e: Event) = e.preventDefault())
        text.appendChild(check)
        text.appendChild(createTextNode(label))
        let checked = action.checked
        let sync = proc() = check.checked = checked()
        sync()
        syncs.add sync
      else:
        text.text = label
      let keys = createElement("kbd")
      keys.text = shortcut
      item.appendChild(text)
      item.appendChild(keys)
      let name = if action != nil: action.name else: ""
      let handler = entry.handler
      item.on("click", proc(e: Event) =
        e.stopPropagation()
        ui.closeMenus()
        ui.hideContextMenu()
        if name.len > 0: ui.run(name)
        elif handler != nil: handler())
      popup.appendChild(item)
  ui.popupSyncs[popup.id] = syncs
  popup

proc attachDropdown(ui: EditorUi, trigger: Node, list: openArray[MenuEntry]): Node =
  let popup = div0("geMenuDropdown")
  popup.hidden = true
  ui.menuPopups.add popup
  ui.menuTriggers[popup.id] = trigger
  ui.addMenuItems(popup, list)
  trigger.on("click", proc(e: Event) =
    e.stopPropagation()
    let wasOpen = not popup.hidden
    ui.closeMenus()
    if not wasOpen:
      # Portal the popup to the body: toolbar containers use overflow:hidden,
      # which clips an absolutely positioned descendant whatever its z-index.
      body.appendChild(popup)
      for sync in ui.popupSyncs.getOrDefault(popup.id, @[]): sync()
      let triggerRect = rect(trigger)
      popup.style("left", px(max(4.0, triggerRect.left)))
      popup.style("top", px(triggerRect.bottom))
      popup.hidden = false
      trigger.addClass("geMenuActive")
      # Keep the menu inside the viewport; open it above a trigger near the
      # bottom edge when there is more room there.
      let r = rect(popup)
      let innerWidth = window.getNum("innerWidth")
      let innerHeight = window.getNum("innerHeight")
      if r.right > innerWidth - 4:
        popup.style("left", px(max(4.0, innerWidth - r.width - 4)))
      if r.bottom > innerHeight - 4 and triggerRect.top > r.height + 4:
        popup.style("top", px(max(4.0, triggerRect.top - r.height))))
  popup

proc closeMenus(ui: EditorUi) =
  for popup in ui.menuPopups:
    popup.hidden = true
    let trigger = ui.menuTriggers.getOrDefault(popup.id, nilNode)
    if not trigger.isNil: trigger.removeClass("geMenuActive")

proc buildContextMenu(ui: EditorUi) =
  ui.contextMenu = div0("geContextMenu")
  ui.contextMenu.hidden = true
  body.appendChild(ui.contextMenu)
  ui.contextMenuBaseEntries = @["delete", "-", "cut", "copy", "-", "duplicate", "setBookmark", "-",
    "setDefaultStyle", "-", "toFront", "toBack", "-",
    "editStyle", "editData", "editLink", "editImage"]

proc showContextMenu(ui: EditorUi, data: Val) =
  let point = data["point"]
  ui.contextPoint = if point.isObj and truthy(point["world"]): point["world"] else: nil
  let tableCell = ui.graph.call("getSelectedTableCell")
  ui.contextMenu.dropChildren()
  ui.popupSyncs.del(ui.contextMenu.id)
  let list = if truthy(tableCell): @["editCell", "-",
      "tableInsertRowAbove", "tableInsertRowBelow", "tableDeleteRow", "-",
      "tableInsertColumnLeft", "tableInsertColumnRight", "tableDeleteColumn", "-",
      "tableMergeCells", "tableSplitCell", "-",
      "delete", "cut", "copy", "-", "editStyle", "editLink"]
    else: ui.contextMenuBaseEntries
  ui.addMenuItems(ui.contextMenu, entries(list))
  ui.contextMenu.hidden = false
  let width = ui.contextMenu.getNum("offsetWidth")
  let height = ui.contextMenu.getNum("offsetHeight")
  let innerWidth = window.getNum("innerWidth")
  let innerHeight = window.getNum("innerHeight")
  ui.contextMenu.style("left", px(max(4.0, min(num(data["clientX"]), innerWidth - width - 4))))
  ui.contextMenu.style("top", px(max(4.0, min(num(data["clientY"]), innerHeight - height - 4))))

proc hideContextMenu(ui: EditorUi) =
  if not ui.contextMenu.isNil: ui.contextMenu.hidden = true

# ------------------------------------------------------------------ status --

proc setStatusText(ui: EditorUi, value: string) =
  if not ui.statusContainer.isNil: ui.statusContainer.text = value

proc updateStatus*(ui: EditorUi, stats: Val = nil) =
  let s = if stats != nil: stats elif ui.editor != nil: ui.graph.stats else: nil
  if ui.statusRight.isNil or ui.editor == nil: return
  var text = jsStr(jsRound(ui.graph.zoom * 100)) & "%  •  SVG objects: 0"
  if s != nil and s.isObj:
    let memory = num(s["pixelWidth"]) * num(s["pixelHeight"]) * 4 / (1024 * 1024)
    text.add "  •  " & (if truthy(s["backend"]): str(s["backend"]) else: "canvas").toUpperAscii()
    text.add(if s["realtime"].isTrue: " realtime rAF" elif s["worker"].isTrue: " + Worker" else: " main thread")
    text.add "  •  " & valStr(s["visible"]) & "/" & valStr(s["total"]) & " visible"
    text.add "  •  " & toFixed(memory, 1) & " MB framebuffer"
    text.add "  •  " & valStr(s["renderMs"]) & " ms"
  ui.statusRight.text = text

proc toast*(ui: EditorUi, message: string) =
  clearTimeout(ui.toastTimer)
  ui.toastElement.text = message
  ui.toastElement.hidden = false
  ui.toastTimer = setTimeout(2200, proc() =
    ui.toastTimer = 0
    ui.toastElement.hidden = true)

proc showDialog*(ui: EditorUi, title, message: string) =
  let backdrop = div0("geDialogBackdrop")
  let dialog = div0("geDialog")
  let heading = createElement("h2")
  heading.text = title
  let text = createElement("p")
  text.text = message
  let close = el("button", "geBtn gePrimaryBtn")
  close.style("float", "right")
  close.text = "Close"
  close.on("click", proc(e: Event) = backdrop.dropTree())
  dialog.appendChild(heading)
  dialog.appendChild(text)
  dialog.appendChild(close)
  backdrop.appendChild(dialog)
  body.appendChild(backdrop)

# ------------------------------------------------------------------- build --

proc buildFooter(ui: EditorUi) =
  ui.statusLeft = createElement("span")
  ui.statusLeft.text = "Ready"
  ui.footerContainer.appendChild(ui.statusLeft)
  ui.statusRight = el("span", "geFooterRight")
  ui.footerContainer.appendChild(ui.statusRight)

proc buildMenus(ui: EditorUi, container: Node)
proc buildToolbar(ui: EditorUi, container: Node)
proc buildSidebar(ui: EditorUi, container: Node)
proc buildFormat(ui: EditorUi)

proc createUi(ui: EditorUi) =
  # Menubar with the application mark, menus and status label.
  ui.menubar = div0("geMenubar")
  ui.appMark = div0("geAppMark")
  ui.appMark.text = "P"
  ui.appMark.title = "Pixel Graph Editor"
  ui.menubar.appendChild(ui.appMark)
  ui.buildMenus(ui.menubar)
  ui.statusContainer = el("a", "geItem geStatus")
  ui.menubar.appendChild(ui.statusContainer)
  ui.documentTitle = div0("geDocumentTitle")
  ui.documentTitle.text = "Visual Script Editor — Canvas Native"
  ui.menubar.appendChild(ui.documentTitle)
  ui.menubarContainer.appendChild(ui.menubar)

  ui.toolbarElement = div0("geToolbar")
  ui.buildToolbar(ui.toolbarElement)
  ui.toolbarContainer.appendChild(ui.toolbarElement)

  ui.buildSidebar(ui.sidebarContainer)
  ui.buildFormat()
  ui.buildFooter()
  ui.buildContextMenu()
  ui.addSplitHandler(ui.hsplit, proc(value: float64) =
    ui.hsplitPosition = value
    ui.refresh())

proc bindEvents(ui: EditorUi) =
  let g = ui.graph
  g.on("stats", proc(stats: Val) = ui.updateStatus(stats))
  g.on("zoomchange", proc(d: Val) = ui.updateStatus())
  g.on("selectionchange", proc(selection: Val) =
    let n = if selection == nil: 0 else: selection.len
    ui.statusLeft.text = if n > 0: $n & " object" & (if n == 1: "" else: "s") & " selected" else: "Ready"
    ui.setStatusText(if n > 0: $n & " selected" else: "")
    ui.updateFormat())
  g.on("diagramchange", proc(d: Val) = ui.updateFormat())
  g.on("toast", proc(d: Val) = ui.toast(valStr(d)))
  g.on("contextmenu", proc(d: Val) = ui.showContextMenu(d))

  ui.fileInput.on("change", proc(e: Event) =
    let files = ui.fileInput.getNode("files")
    if not files.isNil and files.getNum("length") > 0:
      ui.editor.openFile(files.invoke("item", 0).toNode)
    ui.fileInput.value = "")

  document.on("pointerdown", proc(e: Event) =
    let target = e.target
    if target.closest(".geMenuWrapper").isNil and target.closest(".geMenuDropdown").isNil:
      ui.closeMenus()
    if target.closest(".geContextMenu").isNil: ui.hideContextMenu())

  document.on("keydown", proc(e: Event) =
    let modifier = e.ctrlKey or e.metaKey
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
      e.preventDefault())

  window.on("resize", proc(e: Event) = ui.refresh(true))
