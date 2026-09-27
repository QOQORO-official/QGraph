## QNote-style table axis grips and menu, while the graph owns table mutations.

proc selectedAxisTable(ui: EditorUi): Val =
  for item in ui.graph.getSelection():
    if item.eqs("shape", "table") and not item.tr("locked"): return item
  nil

proc closeTableAxisMenu(ui: EditorUi) =
  if not ui.tableAxisMenu.isNil: ui.tableAxisMenu.hidden = true
  ui.tableAxisId = ""

proc axisCell(node: Val, column: bool, index: int): Val =
  let key = if column: "0," & $index else: $index & ",0"
  let cells = node["cells"]
  if cells.isObj: cells.get(key) else: nil

proc runTableAxis(ui: EditorUi, action: string, value = "") =
  let node = ui.graph.g.getItem(ui.tableAxisId)
  let index = ui.tableAxisIndex
  let column = ui.tableAxisColumn
  ui.closeTableAxisMenu()
  if node != nil and node.eqs("shape", "table"):
    discard ui.graph.g.tableAxisAction(node, column, index, action, value)
  ui.updateTableAxisGrips(-1, -1)

proc bindAxisButton(ui: EditorUi, button: Node, action: string, value = "") =
  button.on("click", proc(e: Event) =
    e.stopPropagation()
    ui.runTableAxis(action, value))

proc addAxisRow(ui: EditorUi, label, icon, action: string, value = "",
                danger = false): Node =
  result = el("button", "qg-table-axis-item" & (if danger: " is-danger" else: ""))
  result.typ = "button"
  let glyph = el("span", "qg-table-axis-icon")
  glyph.text = icon
  result.appendChild(glyph)
  let caption = el("span", "qg-table-axis-label")
  caption.text = label
  result.appendChild(caption)
  if action.len > 0: ui.bindAxisButton(result, action, value)
  ui.tableAxisMenu.appendChild(result)

proc openTableAxisMenu(ui: EditorUi, column: bool, index: int, grip: Node) =
  let node = ui.selectedAxisTable()
  if node == nil: return
  ui.tableAxisId = str(node["id"])
  ui.tableAxisColumn = column
  ui.tableAxisIndex = index
  let cell = axisCell(node, column, index)
  let header = if cell.isObj and not cell.nul("header"): cell.tr("header")
               else: (if column: node.tr("headerColumn") and index == 0
                      else: node.tr("headerRow") and index == 0)
  let menu = ui.tableAxisMenu
  menu.dropChildren()
  let toggle = ui.addAxisRow(if column: "Header column" else: "Header row", "▤", "header",
                             if header: "false" else: "true")
  let switch = el("span", "qg-table-axis-switch" & (if header: " is-on" else: ""))
  toggle.appendChild(switch)

  let colorRow = ui.addAxisRow("Color", "◩", "")
  let arrow = el("span", "qg-table-axis-chevron")
  arrow.text = "›"
  colorRow.appendChild(arrow)
  let palette = div0("qg-table-axis-palette")
  palette.hidden = true
  for (color, title) in [("", "No fill"), ("#fef2f2", "Pink"), ("#fff7ed", "Peach"),
                         ("#fefce8", "Lemon"), ("#f0fdf4", "Mint"), ("#eff6ff", "Ice"),
                         ("#f5f3ff", "Lavender"), ("#f8fafc", "Gray"),
                         ("#fecaca", "Red"), ("#fed7aa", "Orange"), ("#fde68a", "Yellow"),
                         ("#bbf7d0", "Green"), ("#bfdbfe", "Blue"), ("#ddd6fe", "Purple"),
                         ("#e2e8f0", "Slate"), ("#0f172a", "Ink")]:
    let swatch = el("button", "qg-table-axis-swatch")
    swatch.typ = "button"
    swatch.setAttribute("title", title)
    swatch.setAttribute("aria-label", title)
    if color.len > 0: swatch.style("background", color)
    else: swatch.text = "×"
    ui.bindAxisButton(swatch, "color", color)
    palette.appendChild(swatch)
  menu.appendChild(palette)
  colorRow.on("click", proc(e: Event) =
    e.stopPropagation()
    palette.hidden = not palette.hidden)

  menu.appendChild(el("hr", "qg-menu-sep"))
  discard ui.addAxisRow(if column: "Insert left" else: "Insert above", "←", "insert-before")
  discard ui.addAxisRow(if column: "Insert right" else: "Insert below", "→", "insert-after")
  discard ui.addAxisRow("Duplicate", "▣", "duplicate")
  discard ui.addAxisRow("Clear contents", "⊘", "clear")
  menu.appendChild(el("hr", "qg-menu-sep"))
  let remove = ui.addAxisRow("Delete", "♲", "delete", danger = true)
  if (if column: node.nm("columns") else: node.nm("rows")) <= 1:
    remove.setProp("disabled", true)
  menu.hidden = false
  let anchor = rect(grip)
  let width = menu.getNum("offsetWidth")
  let height = menu.getNum("offsetHeight")
  let x = if column: anchor.left + anchor.width / 2 - width / 2 else: anchor.right + 8
  let y = if column: anchor.bottom + 6 else: anchor.top
  menu.style("left", px(max(8.0, min(x, window.getNum("innerWidth") - width - 8))))
  menu.style("top", px(max(8.0, min(y, window.getNum("innerHeight") - height - 8))))

proc updateTableAxisGrips(ui: EditorUi, clientX, clientY: float64) =
  if ui.tableRowGrip.isNil or ui.tableColumnGrip.isNil: return
  if ui.tableAxisId.len > 0: return
  let node = ui.selectedAxisTable()
  ui.tableRowGrip.hidden = true
  ui.tableColumnGrip.hidden = true
  if node == nil or rot(node) != 0 or clientX < 0 or clientY < 0: return
  let canvas = rect(ui.graph.container)
  let stage = rect(ui.stage)
  let zoom = ui.graph.zoom
  let scrollX = ui.graph.container.getNum("scrollLeft")
  let scrollY = ui.graph.container.getNum("scrollTop")
  let worldX = (clientX - canvas.left + scrollX) / zoom - ui.graph.g.worldOriginX
  let worldY = (clientY - canvas.top + scrollY) / zoom - ui.graph.g.worldOriginY
  let grid = tableGrid(node)
  let near = 28.0 / zoom
  if worldX < nodeX(node) - near or worldX > nodeX(node) + nodeW(node) + near or
      worldY < grid.contentY - near or worldY > grid.contentBottom + near: return
  template sx(x: float64): float64 = canvas.left - stage.left + (x + ui.graph.g.worldOriginX) * zoom - scrollX
  template sy(y: float64): float64 = canvas.top - stage.top + (y + ui.graph.g.worldOriginY) * zoom - scrollY
  if worldY >= grid.contentY - near and worldY <= grid.contentBottom:
    for i, row in grid.rows:
      if worldY >= row.pos and worldY <= row.pos + row.size:
        ui.tableGripRowIndex = i
        ui.tableRowGrip.style("left", px(sx(nodeX(node)) - 15))
        ui.tableRowGrip.style("top", px(sy(row.pos + row.size / 2) - 9))
        ui.tableRowGrip.hidden = false
        break
  if worldX >= nodeX(node) and worldX <= nodeX(node) + nodeW(node):
    for i, col in grid.columns:
      if worldX >= col.pos and worldX <= col.pos + col.size:
        ui.tableGripColumnIndex = i
        ui.tableColumnGrip.style("left", px(sx(col.pos + col.size / 2) - 14))
        ui.tableColumnGrip.style("top", px(sy(grid.contentY) - 18))
        ui.tableColumnGrip.hidden = false
        break

proc buildTableAxisUi(ui: EditorUi) =
  ui.tableRowGrip = el("button", "qg-table-axis-grip is-row")
  ui.tableColumnGrip = el("button", "qg-table-axis-grip is-column")
  for grip in [ui.tableRowGrip, ui.tableColumnGrip]:
    grip.typ = "button"
    grip.text = "•••"
    grip.hidden = true
    ui.floatLayer.appendChild(grip)
    grip.on("pointerdown", proc(e: Event) = e.stopPropagation())
  ui.tableRowGrip.setAttribute("aria-label", "Row options")
  ui.tableColumnGrip.setAttribute("aria-label", "Column options")
  ui.tableRowGrip.on("click", proc(e: Event) =
    e.stopPropagation()
    ui.openTableAxisMenu(false, ui.tableGripRowIndex, ui.tableRowGrip))
  ui.tableColumnGrip.on("click", proc(e: Event) =
    e.stopPropagation()
    ui.openTableAxisMenu(true, ui.tableGripColumnIndex, ui.tableColumnGrip))
  ui.tableAxisMenu = div0("qg-table-axis-menu")
  ui.tableAxisMenu.setAttribute("role", "menu")
  ui.tableAxisMenu.hidden = true
  body.appendChild(ui.tableAxisMenu)
  ui.stage.on("pointermove", proc(e: Event) =
    ui.updateTableAxisGrips(e.clientX, e.clientY))
  ui.stage.on("pointerleave", proc(e: Event) = ui.updateTableAxisGrips(-1, -1))
  ui.graph.container.on("scroll", proc(e: Event) = ui.updateTableAxisGrips(-1, -1))
