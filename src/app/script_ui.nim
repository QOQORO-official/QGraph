# Included from editorui.nim: the Script tab (the Luau blocks, Run and Stop,
# the console) and the inspector's Block page for a selected script block.

proc insertScriptBlock(ui: EditorUi, d: ScriptBlockDef) =
  discard ui.editor.addTemplateAtCenter(scriptTemplate(d))
  if ui.layout == lmPhone: ui.closeSheet()

proc scriptBlockTile(ui: EditorUi, d: ScriptBlockDef): Node =
  let tile = el("button", "qg-script-block")
  tile.typ = "button"
  tile.setProp("draggable", true)
  tile.setData("block", d.vsType)
  tile.setAttribute("style", "--block-color: " & d.color)
  tile.setAttribute("title", d.description & " — click to add, or drag onto the canvas")
  let badge = div0("qg-script-block-icon")
  badge.appendChild(icon(d.iconName, 18))
  tile.appendChild(badge)
  let text = div0("qg-script-block-text")
  let name = el("strong", "qg-script-block-name")
  name.text = d.label
  let desc = el("span", "qg-script-block-desc")
  desc.text = d.description
  text.appendChild(name)
  text.appendChild(desc)
  tile.appendChild(text)
  let payload = toJson(scriptTemplate(d))
  tile.on("dragstart", proc(e: Event) =
    let dt = e.dataTransfer
    dt.call("setData", "application/x-pixel-shape-data", payload)
    dt.setProp("effectAllowed", "copy"))
  tile.on("click", proc(e: Event) = ui.insertScriptBlock(d))
  tile

proc buildScriptPanel(ui: EditorUi) =
  let rt = ui.script
  let (root, content) = panel("Script", "script", proc() =
    if ui.layout == lmPhone: ui.closeSheet() else: ui.togglePane("script"))
  ui.scriptPanel = root

  # Run bar.
  let bar = div0("qg-script-runbar")
  rt.runButton = textButton("Run", "qg-btn qg-btn-primary qg-btn-run", "play")
  rt.runButton.setAttribute("title", "Run the script (Ctrl+Enter)")
  rt.runButton.on("click", proc(e: Event) = ui.runScript())
  rt.stopButton = textButton("Stop", "qg-btn qg-btn-soft qg-btn-stop", "stop")
  rt.stopButton.setAttribute("title", "Stop the running script (Ctrl+.)")
  rt.stopButton.disabled = true
  rt.stopButton.on("click", proc(e: Event) = ui.stopScript())
  rt.status = el("span", "qg-script-status")
  rt.status.setData("state", "idle")
  rt.status.text = "Luau"
  bar.appendChild(rt.runButton)
  bar.appendChild(rt.stopButton)
  bar.appendChild(rt.status)
  content.appendChild(bar)

  # Blocks.
  let head = div0("qg-script-head")
  let title = el("h3", "qg-script-heading")
  title.text = "Blocks"
  head.appendChild(title)
  let example = textButton("Example", "qg-btn qg-btn-ghost qg-btn-sm", "wand")
  example.setAttribute("title", "Insert a small example program")
  example.on("click", proc(e: Event) =
    ui.insertScriptExample()
    if ui.layout == lmPhone: ui.closeSheet())
  head.appendChild(example)
  content.appendChild(head)
  let grid = div0("qg-script-blocks")
  for d in scriptBlockDefs: grid.appendChild(ui.scriptBlockTile(d))
  content.appendChild(grid)
  let hint = el("p", "qg-script-hint")
  hint.html = "Connect blocks with arrows and press <b>Run</b>. Double-click a block to edit it. " &
    "Variables are shared by every block; <code>doc</code> reads and changes the diagram."
  content.appendChild(hint)

  # Console.
  let consoleCard = div0("qg-console-card")
  let consoleHead = div0("qg-script-head")
  let consoleTitle = el("h3", "qg-script-heading")
  consoleTitle.appendChild(icon("terminal", 16))
  let consoleName = createElement("span")
  consoleName.text = "Console"
  consoleTitle.appendChild(consoleName)
  consoleHead.appendChild(consoleTitle)
  let clear = iconButton("trash", "Clear the console")
  clear.on("click", proc(e: Event) = ui.clearConsole())
  consoleHead.appendChild(clear)
  consoleCard.appendChild(consoleHead)
  rt.consoleEmpty = div0("qg-console-empty")
  rt.consoleEmpty.text = "print(), warn() and Output blocks set to Console write here."
  consoleCard.appendChild(rt.consoleEmpty)
  rt.consoleBody = div0("qg-console")
  rt.consoleBody.setAttribute("role", "log")
  rt.consoleBody.setAttribute("aria-live", "polite")
  consoleCard.appendChild(rt.consoleBody)
  content.appendChild(consoleCard)

  root.hidden = true
  ui.leftDock.appendChild(root)

# --------------------------------------------------------- block inspector --

type BlockFieldSpec = tuple[key, label, kind, hint: string]

proc blockFieldSpecs(vsType: string): seq[BlockFieldSpec] =
  case vsType
  of "output": @[("value", "Value", "expr", "A Luau expression, e.g. \"Total: \" .. total"),
                 ("mode", "Show it", "mode", "")]
  of "luau", "process", "function":
    @[("code", "Luau code", "code",
       "print · warn · alert · prompt · wait · output · doc.find · doc.set · doc.add · doc.connect")]
  of "set": @[("name", "Variable", "name", ""), ("value", "Value", "expr", "A Luau expression")]
  of "condition": @[("test", "Condition", "expr",
                     "Connectors labelled true and false choose the path")]
  of "for": @[("iterator", "Variable", "name", ""), ("from", "From", "expr", ""),
              ("to", "To", "expr", ""),
              ("step", "Step", "expr", "Connectors labelled loop and done choose the path")]
  of "while": @[("condition", "Condition", "expr", "Checked before every round"),
                ("max", "Max rounds", "number", "0 means no limit")]
  of "ask": @[("name", "Store in", "name", ""), ("message", "Question", "expr", ""),
              ("default", "Default", "expr", "")]
  of "delay": @[("seconds", "Seconds", "expr", "")]
  of "shape": @[("target", "Shape", "text", "The label or id of the shape to change"),
                ("property", "Property", "property", ""), ("value", "Value", "expr", "A Luau expression")]
  else: @[]

proc commitBlockField(ui: EditorUi, id, key, value: string) =
  let item = ui.graph.g.getItem(id)
  if not isScriptBlock(item) or blockField(item, key) == value: return
  let vs = if item["visualScript"].isObj: clone(item["visualScript"]) else: newObj()
  vs.put(key, jstr(value))
  discard ui.graph.updateItem(id, o1("visualScript", vs), "Edit Block", record = true)

proc blockOutputText(item: Val): (string, string) =
  let error = blockField(item, "lastError")
  if error.len > 0: return ("error", error)
  let output = blockField(item, "lastResult")
  if output.len > 0: return ("ok", output)
  ("idle", "No output yet")

proc syncScriptInspector(ui: EditorUi, item: Val) =
  ## Refreshes values in place, leaving the control being edited alone.
  let page = ui.script.inspectorBody
  if page.isNil: return
  let active = activeElement()
  for control in page.queryAll("[data-field]"):
    if same(control, active): continue
    let key = control.get2("dataset", "field").toStr
    let value = if key == "__title": valStr(item["text"]) else: blockField(item, key)
    if control.value != value: control.value = value
  let output = page.query(".qg-block-output")
  if not output.isNil:
    let (state, text) = blockOutputText(item)
    output.setData("state", state)
    output.text = text

proc buildScriptInspector(ui: EditorUi, item: Val) =
  let rt = ui.script
  let page = rt.inspectorBody
  page.dropChildren()
  let id = idOf(item)
  let vsType = valStr(item["vsType"])
  let (known, d) = findBlockDef(vsType)
  let body = card(page, if known: d.label & " block" else: "Script block",
                  if known: d.iconName else: "script")
  if known:
    let about = el("p", "qg-block-about")
    about.text = d.description
    body.appendChild(about)

  let titleInput = el("input", "qg-input")
  titleInput.typ = "text"
  titleInput.setData("field", "__title")
  titleInput.value = valStr(item["text"])
  titleInput.on("change", proc(e: Event) =
    if ui.graph.g.getItem(id) != nil:
      discard ui.graph.updateItem(id, o1("text", jstr(titleInput.value)), "Rename Block", record = true))
  field(body, "Title", titleInput)

  for spec in blockFieldSpecs(vsType):
    let key = spec.key
    var control: Node
    case spec.kind
    of "code":
      control = el("textarea", "qg-input qg-code")
      control.setAttribute("rows", "10")
      control.setAttribute("spellcheck", "false")
      control.setAttribute("autocapitalize", "off")
      control.setAttribute("autocomplete", "off")
      control.on("keydown", proc(e: Event) =
        if e.key == "Tab" and not e.shiftKey and not e.ctrlKey and not e.metaKey:
          e.preventDefault()
          discard execCommand("insertText", "\t", true))
      let area = control
      control.on("input", proc(e: Event) =
        clearTimeout(rt.codeTimer)
        rt.codeTimer = setTimeout(600, proc() = ui.commitBlockField(id, key, area.value)))
    of "mode":
      control = el("select", "qg-select")
      control.fillOptions([("block", "On this block"), ("console", "In the console"),
                           ("alert", "As a browser alert")])
    of "property":
      control = el("select", "qg-select")
      control.fillOptions([("fill", "Fill color"), ("stroke", "Line color"), ("text", "Text"),
        ("textColor", "Text color"), ("fontSize", "Font size"), ("opacity", "Opacity"),
        ("strokeWidth", "Line width"), ("x", "X"), ("y", "Y"), ("width", "Width"),
        ("height", "Height"), ("rotation", "Rotation"), ("visible", "Visible")])
    else:
      control = el("input", "qg-input" & (if spec.kind in ["expr", "name"]: " qg-mono" else: ""))
      control.typ = if spec.kind == "number": "number" else: "text"
      control.setAttribute("spellcheck", "false")
      control.setAttribute("autocapitalize", "off")
    control.setData("field", key)
    control.value = blockField(item, key)
    let input = control
    control.on("change", proc(e: Event) =
      clearTimeout(rt.codeTimer)
      ui.commitBlockField(id, key, input.value))
    let row = field(body, spec.label, control, if spec.kind == "code": "qg-field-stack" else: "")
    if spec.hint.len > 0:
      let hint = el("small", "qg-field-hint")
      hint.text = spec.hint
      row.appendChild(hint)

  if vsType == "start":
    let note = el("p", "qg-block-about")
    note.text = "Run starts here. With several Start blocks, they run top to bottom."
    body.appendChild(note)
  elif not known and vsType notin ["process", "function", "input"]:
    let note = el("p", "qg-block-about")
    note.text = "This block comes from an older document and is skipped when the script runs."
    body.appendChild(note)

  let actions = div0("qg-button-row")
  rt.inspectorRun = textButton("Run from here", "qg-btn qg-btn-primary", "play")
  rt.inspectorRun.disabled = rt.running
  rt.inspectorRun.on("click", proc(e: Event) = ui.runScript(@[id]))
  let all = textButton("Run all", "qg-btn qg-btn-soft", "flag")
  all.on("click", proc(e: Event) = ui.runScript())
  actions.appendChild(rt.inspectorRun)
  actions.appendChild(all)
  body.appendChild(actions)

  let outputCard = card(page, "Last run", "terminal")
  let output = el("pre", "qg-block-output")
  let (state, text) = blockOutputText(item)
  output.setData("state", state)
  output.text = text
  outputCard.appendChild(output)

proc refreshScriptInspector(ui: EditorUi) =
  let rt = ui.script
  if rt.inspectorBody.isNil: return
  let item = ui.selectedScriptBlock()
  if item == nil:
    if rt.inspectedId.len > 0:
      rt.inspectedId = ""
      rt.inspectorBody.dropChildren()
    return
  if idOf(item) != rt.inspectedId:
    rt.inspectedId = idOf(item)
    ui.buildScriptInspector(item)
  else:
    ui.syncScriptInspector(item)

# ------------------------------------------------------------------ wiring --

proc installScript(ui: EditorUi) =
  let g = ui.graph
  g.on("scriptblockopen", proc(d: Val) =
    ui.openPanel("inspector", "block"))
  g.on("change", proc(d: Val) =
    ui.labelScriptEdges()
    ui.refreshScriptInspector())
