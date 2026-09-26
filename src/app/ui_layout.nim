# Included from editorui.nim: the responsive layout controller.
#
#   desktop  >= 1100px  rail + docked library and inspector, floating cards
#   tablet   700-1099   rail; library and inspector slide in as drawers
#   phone    <  700     app bar, bottom tab bar, panels in a bottom sheet
#
# Panels are built once; applyLayout() only moves them between hosts and
# flips data attributes that the stylesheet keys off.

const ThemeKey = "qgraph-theme"

proc initialTheme(ui: EditorUi): string =
  let (found, stored) = storageGet(ThemeKey)
  if found and stored in ["light", "dark"]: return stored
  let query = window.invoke("matchMedia", "(prefers-color-scheme: dark)").toNode
  if not query.isNil and query.getBool("matches"): "dark" else: "light"

proc setTheme(ui: EditorUi, theme: string) =
  ui.theme = theme
  documentElement.setData("theme", theme)
  discard storageSet(ThemeKey, theme)
  if not ui.themeButton.isNil:
    ui.themeButton.html = iconMarkup(if theme == "dark": "sun" else: "moon")
    ui.themeButton.setAttribute("title", if theme == "dark": "Light theme" else: "Dark theme")

proc modeFor(width: float64): LayoutMode =
  if width < 700: lmPhone elif width < 1100: lmTablet else: lmDesktop

proc modeName(m: LayoutMode): string =
  case m
  of lmDesktop: "desktop"
  of lmTablet: "tablet"
  of lmPhone: "phone"

proc syncDocks(ui: EditorUi) =
  ## The left dock holds either the shape library or the Script tab.
  ui.leftDock.toggleClass("is-open", ui.libraryOpen)
  ui.rightDock.toggleClass("is-open", ui.inspectorOpen)
  ui.container.toggleClass("has-library", ui.libraryOpen)
  ui.container.toggleClass("has-inspector", ui.inspectorOpen)
  if ui.layout != lmPhone:
    ui.libraryPanel.hidden = ui.leftPane != "library"
    if not ui.scriptPanel.isNil: ui.scriptPanel.hidden = ui.leftPane != "script"
  let shapes = ui.railButtons.getOrDefault("shapes", nilNode)
  if not shapes.isNil: shapes.toggleClass("is-active", ui.libraryOpen and ui.leftPane == "library")
  let script = ui.railButtons.getOrDefault("script", nilNode)
  if not script.isNil: script.toggleClass("is-active", ui.libraryOpen and ui.leftPane == "script")
  if not ui.inspectorToggle.isNil: ui.inspectorToggle.toggleClass("is-active", ui.inspectorOpen)

proc setActiveTab(ui: EditorUi, name: string) =
  for key, button in ui.tabButtons: button.toggleClass("is-active", key == name)

proc closeSheet(ui: EditorUi) =
  if not ui.sheetOpen: return
  ui.sheetOpen = false
  ui.sheet.removeClass("is-open")
  ui.sheetBackdrop.removeClass("is-open")
  ui.sheet.style("transform", "")
  ui.setActiveTab("")

proc showInSheet(ui: EditorUi, panelNode: Node, title, tabName: string) =
  if not ui.sheetPanel.isNil and not same(ui.sheetPanel, panelNode): ui.sheetPanel.remove()
  ui.sheetPanel = panelNode
  panelNode.hidden = false
  ui.sheetTitle.text = title
  ui.sheetBody.appendChild(panelNode)
  ui.sheetOpen = true
  ui.sheet.addClass("is-open")
  ui.sheetBackdrop.addClass("is-open")
  ui.setActiveTab(tabName)

proc applyLayout*(ui: EditorUi) =
  let mode = modeFor(window.getNum("innerWidth"))
  let changed = not ui.layoutKnown or mode != ui.layout
  ui.layout = mode
  ui.layoutKnown = true
  ui.container.setData("layout", modeName(mode))
  if changed:
    ui.closeSheet()
    ui.closeMenus()
    case mode
    of lmDesktop:
      ui.libraryOpen = true
      ui.inspectorOpen = true
    of lmTablet:
      ui.libraryOpen = false
      ui.inspectorOpen = false
    of lmPhone:
      ui.libraryOpen = false
      ui.inspectorOpen = false
    if mode == lmPhone:
      # Panels live in the sheet on phones; they are mounted on demand.
      for p in [ui.libraryPanel, ui.inspectorPanel, ui.scriptPanel]:
        if not p.isNil: p.remove()
      if not ui.layersCard.isNil: ui.layersCard.hidden = true
      if not ui.outlineCard.isNil: ui.outlineCard.hidden = true
    else:
      ui.leftDock.appendChild(ui.libraryPanel)
      if not ui.scriptPanel.isNil: ui.leftDock.appendChild(ui.scriptPanel)
      ui.rightDock.appendChild(ui.inspectorPanel)
      if not ui.layersCard.isNil and not same(ui.layersPanel.getNode("parentNode"), ui.layersCard):
        ui.layersCard.appendChild(ui.layersPanel)
      if not ui.outlineCard.isNil and not same(ui.outlinePanel.getNode("parentNode"), ui.outlineCard):
        ui.outlineCard.appendChild(ui.outlinePanel)
  ui.syncDocks()
  if ui.editor != nil: ui.graph.render()

proc refresh*(ui: EditorUi, sizeDidChange = true) =
  ui.applyLayout()

proc showFloatingCard(ui: EditorUi, cardNode, panelNode: Node) =
  if not same(panelNode.getNode("parentNode"), cardNode): cardNode.appendChild(panelNode)
  cardNode.hidden = false

proc openPanel*(ui: EditorUi, name: string, tab = "") =
  ## Brings a panel into view wherever the current layout keeps it.
  if ui.layout == lmPhone:
    case name
    of "library": ui.showInSheet(ui.libraryPanel, "Shapes", "shapes")
    of "script":
      ui.ensureWorker()
      ui.showInSheet(ui.scriptPanel, "Script", "script")
    of "inspector":
      let hasSelection = ui.graph.getSelection().len > 0
      ui.updateFormatTabs(hasSelection)
      if tab.len > 0: ui.selectFormatTab(tab)
      let title = case ui.activeFormatTab
        of "text": "Text"
        of "arrange": "Arrange"
        of "diagram": "Diagram"
        of "block": "Block"
        else: "Style"
      ui.showInSheet(ui.inspectorPanel, title, if tab.len > 0: tab else: "style")
    of "layers": ui.showInSheet(ui.layersPanel, "Layers", "more")
    of "outline": ui.showInSheet(ui.outlinePanel, "Outline", "more")
    of "menu":
      for syncs in ui.popupSyncs.values:
        for sync in syncs: sync()
      ui.showInSheet(ui.menuPanel, "Menu", "more")
    of "context": ui.showInSheet(ui.contextMenu, "Actions", "")
    else: discard
    return
  case name
  of "library":
    ui.libraryOpen = true
    ui.leftPane = "library"
  of "script":
    ui.libraryOpen = true
    ui.leftPane = "script"
    ui.ensureWorker()
  of "inspector":
    ui.inspectorOpen = true
    if tab.len > 0: ui.selectFormatTab(tab)
  of "layers":
    if not ui.layersCard.isNil: ui.showFloatingCard(ui.layersCard, ui.layersPanel)
  of "outline":
    if not ui.outlineCard.isNil: ui.showFloatingCard(ui.outlineCard, ui.outlinePanel)
  else: discard
  ui.syncDocks()
  ui.graph.render()

proc togglePane*(ui: EditorUi, name: string) =
  if ui.layout == lmPhone:
    if ui.sheetOpen: ui.closeSheet()
    else: ui.openPanel(if name == "sidebar": "library" elif name == "script": "script" else: "inspector")
    return
  case name
  of "sidebar", "script":
    let pane = if name == "script": "script" else: "library"
    if ui.libraryOpen and ui.leftPane == pane: ui.libraryOpen = false
    else:
      ui.libraryOpen = true
      ui.leftPane = pane
      if pane == "script": ui.ensureWorker()
  else: ui.inspectorOpen = not ui.inspectorOpen
  ui.syncDocks()
  ui.graph.render()

proc installSheetGestures(ui: EditorUi, grabber: Node) =
  ## Drag the sheet's header down to dismiss it.
  var dragging = false
  var startY, dy: float64
  grabber.on("pointerdown", proc(e: Event) =
    dragging = true
    startY = e.clientY
    dy = 0
    grabber.call("setPointerCapture", e.pointerId)
    ui.sheet.addClass("is-dragging"))
  grabber.on("pointermove", proc(e: Event) =
    if not dragging: return
    dy = max(0.0, e.clientY - startY)
    ui.sheet.style("transform", "translateY(" & jsStr(dy) & "px)"))
  proc finish(e: Event) =
    if not dragging: return
    dragging = false
    ui.sheet.removeClass("is-dragging")
    ui.sheet.style("transform", "")
    if dy > 90: ui.closeSheet()
  grabber.on("pointerup", finish)
  grabber.on("pointercancel", finish)
