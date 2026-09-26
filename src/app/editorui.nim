## QGraph Studio -- the editor shell around the canvas view: top bar, tool
## rail, shape library, inspector, floating quick-style bar and zoom dock on
## wide screens; an app bar, bottom tab bar and bottom sheets on phones.
##
## Every panel (library, inspector, layers, outline, menu) is built once and
## re-hosted by the layout controller (ui_layout) as the viewport changes:
## docked, drawer, floating card or bottom sheet. All of it is DOM built
## through qweb's command buffer.

import std/[tables, sets, strutils, math]
import ../jsval, ../host, ../geometry, ../graph, ../canvas, ../painter, ../richtext
import ../web/qweb
import jsutil, media, view, overlay, data, legacy, mxformat, svgconvert, stencilxml, shapesvg,
  richhtml, icons, renderer

type
  Predicate = proc(item: Val): bool

  Action* = ref object
    name*, label*, shortcut*: string
    handler*: proc()
    checked*: proc(): bool

  EntryKind = enum ekAction, ekSeparator, ekLiteral, ekNumber
  MenuEntry = object
    kind: EntryKind
    name, label, shortcut: string
    handler: proc()
    numHandler: proc(value: float64)
    value: proc(): float64
    min, max, step: float64

  Editor* = ref object
    graph*: View
    overlay*: MediaOverlay
    filename*: string

  Palette = object
    id, name: string
    expanded: bool
    classic, stencilLibrary: string

  Section = ref object
    title, outer, body: Node
    items: seq[Node]
    palette: Palette

  Sidebar = ref object
    thumbWidth, thumbHeight, thumbPadding, thumbBorder: float64
    scratchpadBodies: seq[Node]
    sections: seq[Section]
    stencilHosts: Table[string, Section]
    loadedStencils: Table[string, HashSet[string]]
    classicCache: Table[string, Val]
    originalPalettes: seq[Palette]
    container, originalPanel: Node
    blocksSection: Section
    setCategory: proc(key: string)

  Toolbar = ref object
    controls: Table[string, Node]

  LayoutMode = enum lmDesktop, lmTablet, lmPhone

  EditorUi* = ref object
    container*: Node
    topbar, menubar, rail, workspace, leftDock, rightDock, stage, diagram: Node
    quickbar, zoomDock, zoomLabel, statusChip, statusLeft, statusRight, selPill: Node
    tabbar, sheetBackdrop, sheet, sheetTitle, sheetBody, floatLayer: Node
    docName, themeButton, inspectorToggle: Node
    fileInput, toastElement, imageInput: Node
    libraryPanel, inspectorPanel, layersPanel, outlinePanel, menuPanel: Node
    layersCard, outlineCard: Node
    contextMenu: Node
    contextMenuBaseEntries: seq[string]
    contextPoint*: Val
    menuPopups: seq[Node]
    menuTriggers: Table[int32, Node]
    popupSyncs: Table[int32, seq[proc()]]
    editor*: Editor
    actions*: OrderedTable[string, Action]
    menuDefinitions: seq[(string, seq[string])]
    toolbar: Toolbar
    sidebar: Sidebar
    layout: LayoutMode
    layoutKnown: bool
    libraryOpen, inspectorOpen: bool
    sheetPanel: Node
    sheetOpen: bool
    tabButtons: OrderedTable[string, Node]
    railButtons: Table[string, Node]
    theme: string
    formatTabs: Node
    formatPanels: OrderedTable[string, Node]
    formatTabButtons: OrderedTable[string, Node]
    formatDisabled: HashSet[string]
    activeFormatTab: string
    formatFields: Table[string, Node]
    styleControls: seq[Node]
    rangeSyncs: seq[proc()]
    liveEdit: HashSet[int32]
    paperFormats: seq[(string, string)]
    toastTimer: int32
    layersBody: Node
    outlineBody, outlineCanvas, outlineContext: Node
    outlineMapping: (float64, float64, float64)
    hasOutlineMapping: bool
    outlinePainter: ScenePainter
    autosaveEnabled, autosaveInstalled: bool
    autosaveTimer: int32
    ready*: bool
    onReady*: seq[proc()]

const stencilLibraries = ["stencils/basic.xml", "stencils/arrows.xml", "stencils/flowchart.xml"]

# ------------------------------------------------------------ small helpers --

proc div0(cls: string): Node = el("div", cls)

proc valStr(v: Val): string =
  ## String(value) as a form control receives it.
  if nullish(v): "" else: str(v)

proc px(x: float64): string = jsStr(x) & "px"

proc jsonClone(v: Val): Val = (if v == nil: nil else: clone(v))

proc isHexColor(s: string): bool =
  if s.len != 7 or s[0] != '#': return false
  for c in s[1 .. ^1]:
    if c notin {'0'..'9', 'a'..'f', 'A'..'F'}: return false
  true

proc numberOr(s: string, d: float64): float64 =
  ## Number(value) || d
  let n = jsNumber(s)
  if n != n or n == 0: d else: n

proc nodesOnly(item: Val): bool = not item.eqs("type", "edge")
proc edgesOnly(item: Val): bool = item.eqs("type", "edge")

proc o1(k: string, v: Val): Val =
  result = newObj()
  result.put(k, v)

proc graph(ui: EditorUi): View {.inline.} = ui.editor.graph

proc nilToNull(v: Val): Val = (if v == nil: jnull else: v)

# Menu entries --------------------------------------------------------------

converter toEntry(s: string): MenuEntry =
  if s == "-": MenuEntry(kind: ekSeparator) else: MenuEntry(kind: ekAction, name: s)

proc lit(label: string, handler: proc()): MenuEntry =
  MenuEntry(kind: ekLiteral, label: label, handler: handler)

proc entries(names: openArray[string]): seq[MenuEntry] =
  for n in names: result.add toEntry(n)

# Forward declarations -------------------------------------------------------

proc run*(ui: EditorUi, name: string)
proc toast*(ui: EditorUi, message: string)
proc refresh*(ui: EditorUi, sizeDidChange = true)
proc openPanel*(ui: EditorUi, name: string, tab = "")
proc closeSheet(ui: EditorUi)
proc updateFormat*(ui: EditorUi)
proc updateStatus*(ui: EditorUi, stats: Val = nil)
proc updateFormatTabs*(ui: EditorUi, hasSelection: bool)
proc selectFormatTab*(ui: EditorUi, name: string)
proc closeMenus(ui: EditorUi)
proc hideContextMenu(ui: EditorUi)
proc editData*(ui: EditorUi)
proc editStyle*(ui: EditorUi)
proc editMedia*(ui: EditorUi, target: Val = nil)
proc insertMedia*(ui: EditorUi)
proc editHtml*(ui: EditorUi, target: Val = nil)
proc editDiagram*(ui: EditorUi)
proc showSvgToMxGraphDialog*(ui: EditorUi)
proc showLayers*(ui: EditorUi)
proc toggleOutline*(ui: EditorUi)
proc toggleAutosave*(ui: EditorUi)
proc showDialog*(ui: EditorUi, title, message: string)
proc togglePane*(ui: EditorUi, name: string)
proc addToScratchpad(ui: EditorUi, node: Val = nil)
proc insertBlockJson(ui: EditorUi, json: string, point: Val = nil)
proc addStencilPalettes(ui: EditorUi)

include editor_doc
include ui_components
include ui_layout
include ui_shell
include ui_format
include ui_windows
include ui_dialogs
include actions
include toolbar
include sidebar

# ------------------------------------------------------------------ startup --

proc newEditorUi*(host: Node = body): EditorUi =
  let ui = EditorUi(container: host, libraryOpen: true, inspectorOpen: true)
  ui.container.className = "qg-app"
  ui.container.html = ""
  ui.theme = ui.initialTheme()
  documentElement.setData("theme", ui.theme)
  ui.createShell()

  ui.editor = newEditor(ui.diagram)
  # Touch drags on empty canvas pan instead of starting a marquee.
  ui.graph.g.mobileMode = true
  ui.installActions()
  ui.installMenus()
  ui.toolbar = Toolbar()
  ui.sidebar = newSidebar()

  ui.createUi()
  ui.bindEvents()
  ui.applyLayout()

  # Start on a blank canvas. A host that wants a document supplies one.
  ui.editor.newDocument()
  ui.updateFormat()
  ui.updateStatus()

  # Stencil libraries arrive asynchronously and fill in their palettes.
  ui.graph.on("stencilsloaded", proc(d: Val) = ui.addStencilPalettes())
  ui.graph.loadStencils(stencilLibraries, proc() =
    # Settles once the shell is laid out, the first frame has been painted
    # and the stencil libraries are in.
    requestAnimationFrame(proc(now: float64) =
      ui.refresh()
      ui.graph.render()
      ui.ready = true
      for f in ui.onReady: f()
      ui.onReady.setLen(0)))
  ui
