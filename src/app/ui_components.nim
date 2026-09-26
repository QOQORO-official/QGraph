# Included from editorui.nim: the component kit every panel is built from.
# Styling lives in styles/qgraph.css under the same class names.

proc iconButton(iconName, title: string, cls = ""): Node =
  result = el("button", "qg-iconbtn" & (if cls.len > 0: " " & cls else: ""))
  result.typ = "button"
  result.setAttribute("title", title)
  result.setAttribute("aria-label", title)
  result.appendChild(icon(iconName))

proc textButton(label: string, cls = "qg-btn", iconName = ""): Node =
  result = el("button", cls)
  result.typ = "button"
  if iconName.len > 0: result.appendChild(icon(iconName, 18))
  let span = createElement("span")
  span.text = label
  result.appendChild(span)

proc panel(title, key: string, onClose: proc() = nil): (Node, Node) =
  ## A panel: header (title + close) and a scrolling body. Returns both.
  let root = el("section", "qg-panel qg-panel-" & key)
  root.setData("panel", key)
  let head = el("header", "qg-panel-head")
  let h = el("h2", "qg-panel-title")
  h.text = title
  head.appendChild(h)
  if onClose != nil:
    let close = iconButton("close", "Close", "qg-panel-close")
    close.on("click", proc(e: Event) = onClose())
    head.appendChild(close)
  let content = el("div", "qg-panel-body")
  root.appendChild(head)
  root.appendChild(content)
  (root, content)

proc card(parent: Node, title: string, iconName = ""): Node =
  ## A titled group of fields inside a panel. Returns its body.
  let section = el("section", "qg-card")
  if title.len > 0:
    let head = el("h3", "qg-card-title")
    if iconName.len > 0: head.appendChild(icon(iconName, 16))
    let t = createElement("span")
    t.text = title
    head.appendChild(t)
    section.appendChild(head)
  let content = el("div", "qg-card-body")
  section.appendChild(content)
  parent.appendChild(section)
  content

proc field(parent: Node, label: string, control: Node, cls = ""): Node {.discardable.} =
  result = el("label", "qg-field" & (if cls.len > 0: " " & cls else: ""))
  let caption = el("span", "qg-field-label")
  caption.text = label
  result.appendChild(caption)
  let slot = el("span", "qg-field-control")
  slot.appendChild(control)
  result.appendChild(slot)
  parent.appendChild(result)

proc fieldRow(parent: Node): Node =
  ## Two or three compact fields side by side.
  result = el("div", "qg-field-row")
  parent.appendChild(result)

proc switchInput(): Node =
  result = el("input", "qg-switch")
  result.typ = "checkbox"
  result.setAttribute("role", "switch")

const SwatchPresets = ["#ffffff", "#1b1f27", "#e5484d", "#f76b15", "#ffc53d", "#30a46c",
                       "#0ea5e9", "#5b5cf0", "#8e4ec6", "#d6409f"]

proc swatchRow(parent: Node, onPick: proc(color: string)): Node {.discardable.} =
  ## One-tap colour presets beside a colour field.
  result = el("div", "qg-swatches")
  for color in SwatchPresets:
    let chip = el("button", "qg-swatch-chip")
    chip.typ = "button"
    chip.setAttribute("title", color)
    chip.style("background", color)
    let c = color
    chip.on("click", proc(e: Event) = onPick(c))
    result.appendChild(chip)
  parent.appendChild(result)

proc iconRow(parent: Node, cls = "qg-iconrow"): Node =
  result = el("div", cls)
  parent.appendChild(result)

proc chip(label: string, active = false): Node =
  result = el("button", "qg-chip" & (if active: " is-active" else: ""))
  result.typ = "button"
  result.text = label
