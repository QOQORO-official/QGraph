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

var paletteTiles: seq[(Node, ScriptBlockDef)]
var paletteSearchBound = false

proc filterPalette(needle: string) =
  for (tile, d) in paletteTiles:
    tile.hidden = needle.len > 0 and not (d.label.toLowerAscii.contains(needle) or
                                          d.description.toLowerAscii.contains(needle))

proc refreshScriptBlockPalette(ui: EditorUi) =
  ## Rebuilds the Script tab's block grid from the current scriptBlockDefs --
  ## called once when buildScriptPanel first lays out the tab, and again
  ## (script.nim's loadPlugins) whenever plugin blocks arrive asynchronously
  ## after that, so they show up without needing a page reload.
  let rt = ui.script
  if rt.blockGrid.isNil: return
  rt.blockGrid.dropChildren()
  paletteTiles.setLen(0)
  for d in scriptBlockDefs:
    let tile = ui.scriptBlockTile(d)
    paletteTiles.add (tile, d)
    rt.blockGrid.appendChild(tile)
  if rt.blockSearch.isNil: return
  filterPalette(jsTrim(rt.blockSearch.value).toLowerAscii())
  if paletteSearchBound: return
  # One listener for the tab's lifetime; it reads the current tiles, so a
  # plugin refresh doesn't stack another handler on every reload.
  paletteSearchBound = true
  let search = rt.blockSearch
  search.on("input", proc(e: Event) = filterPalette(jsTrim(search.value).toLowerAscii()))

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
  let headActions = el("span", "")
  headActions.style("display", "flex")
  headActions.style("align-items", "center")
  headActions.style("gap", "6px")
  let example = textButton("Example", "qg-btn qg-btn-ghost qg-btn-sm", "wand")
  example.setAttribute("title", "Insert a small example program")
  example.on("click", proc(e: Event) =
    ui.insertScriptExample()
    if ui.layout == lmPhone: ui.closeSheet())
  headActions.appendChild(example)
  let qnoteExample = textButton("QNote", "qg-btn qg-btn-ghost qg-btn-sm", "note")
  qnoteExample.setAttribute("title",
    "Insert a small example that adds a heading and a paragraph to the open QNote document")
  qnoteExample.on("click", proc(e: Event) =
    ui.insertQNoteExample()
    if ui.layout == lmPhone: ui.closeSheet())
  headActions.appendChild(qnoteExample)
  head.appendChild(headActions)
  content.appendChild(head)

  let searchWrap = div0("qg-search")
  searchWrap.appendChild(icon("search", 18))
  let search = el("input", "qg-search-input")
  search.typ = "search"
  search.setProp("placeholder", "Search blocks")
  search.setAttribute("aria-label", "Search blocks")
  searchWrap.appendChild(search)
  content.appendChild(searchWrap)

  let grid = div0("qg-script-blocks")
  content.appendChild(grid)
  rt.blockGrid = grid
  rt.blockSearch = search
  ui.refreshScriptBlockPalette()
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
  of "qnoteOpen": @[("path", "Path", "expr", "Leave blank for the QNote document open now")]
  of "qnoteType": @[("kind", "Insert as", "qnoteKind", ""),
                     ("text", "Text", "expr", "A Luau expression")]
  of "qnoteFind": @[("find", "Find", "expr", ""), ("replace", "Replace with", "expr", ""),
                     ("matchCase", "Match case", "expr", "true or false")]
  of "qnoteMessage": @[("text", "Message", "expr", "")]
  of "qnoteAnchor": @[("field", "Field", "expr", "The custom field's name, e.g. \"Logo\" (Misc → Custom fields in QNote)"),
                       ("mode", "Cursor goes", "qnoteAnchorMode", "")]
  of "qnoteImage": @[("src", "Picture", "expr",
                       "An http(s) URL or a data: URL (PNG, JPEG, WebP, GIF, AVIF; up to 50 MB)"),
                      ("width", "Width (px)", "expr", "Blank keeps the picture's own size"),
                      ("height", "Height (px)", "expr", "Blank keeps the aspect ratio"),
                      ("name", "Name it", "expr", "Optional, e.g. \"logo\", so Replace image can find it")]
  of "qnoteImageSource": @[("target", "Image", "expr", "Its name, e.g. \"logo\", or a number: 1 is the first image"),
                            ("src", "New picture", "expr", "An http(s) or data: URL; size and place stay")]
  of "qnoteTable": @[("rows", "Rows", "expr", ""), ("cols", "Columns", "expr", ""),
                      ("name", "Name it", "expr", "Optional, e.g. \"results\", so Fill table can find it"),
                      ("data", "Fill with", "expr", "Optional rows, e.g. {{\"A\", 1}, {\"B\", 2}}")]
  of "qnoteTableFill": @[("target", "Table", "expr", "Its name, e.g. \"results\", or a number: 1 is the first table"),
                          ("data", "Rows", "expr",
                           "A list of rows, e.g. {{\"Sample\", \"Value\"}, {\"A\", 1}} -- missing rows are added")]
  of "qnoteNameObject": @[("name", "Name", "expr", "Names the selected image or table, or the one just before the cursor")]
  of "qnoteXml": @[("xml", "QNote XML", "code",
                    "A <doc> fragment: <qotext>, <table>, <image src=\"…\">, <field>, <pagebreak/>")]
  of "qnoteTemplate": @[("template", "Template", "qnoteTemplate",
                          "QNote defaults, the server library, plugins, or a .qnote file"),
                         ("variables", "Variables", "expr",
                          "A Luau table for the template's {{placeholders}}, e.g. {title = \"Report\", author = name}")]
  of "qnoteRun": @[("save", "Save when done", "expr", "true or false"),
                    ("timeoutMs", "Timeout (ms)", "expr", "")]
  # qnoteFormat / qnoteParagraphFormat: property + value are built specially
  # in buildScriptInspector, since the value control's type (switch, select,
  # or plain text) depends on which property is currently chosen.
  else: @[]

proc commitBlockField(ui: EditorUi, id, key, value: string) =
  let item = ui.graph.g.getItem(id)
  if not isScriptBlock(item) or blockField(item, key) == value: return
  let vs = if item["visualScript"].isObj: clone(item["visualScript"]) else: newObj()
  vs.put(key, jstr(value))
  discard ui.graph.updateItem(id, o1("visualScript", vs), "Edit Block", record = true)

proc saveBlockInspector(ui: EditorUi, id: string) =
  ## Flush the current form, including a code textarea whose debounce has
  ## not fired yet, as one document edit.
  let rt = ui.script
  clearTimeout(rt.codeTimer)
  let item = ui.graph.g.getItem(id)
  if not isScriptBlock(item) or rt.inspectedId != id: return
  let vs = if item["visualScript"].isObj: clone(item["visualScript"]) else: newObj()
  let changes = newObj()
  var dirty = false
  for control in rt.inspectorBody.queryAll("[data-field]"):
    let key = control.get2("dataset", "field").toStr
    if key == "__title":
      if valStr(item["text"]) != control.value:
        changes["text"] = jstr(control.value)
        dirty = true
    elif blockField(item, key) != control.value:
      vs.put(key, jstr(control.value))
      dirty = true
  if not dirty: return
  changes["visualScript"] = vs
  discard ui.graph.updateItem(id, changes, "Save Block", record = true)

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

proc connectedBlockValues(ui: EditorUi, id: string): seq[(string, string)] =
  var upstream = initHashSet[string]()
  upstream.incl(id)
  var changed = true
  while changed:
    changed = false
    for edge in ui.graph.items:
      if edge.eqs("type", "edge") and edge.so("targetId", "") in upstream:
        let source = edge.so("sourceId", "")
        if source.len > 0 and source notin upstream:
          upstream.incl(source)
          changed = true
  var seen = initHashSet[string]()
  var choices: seq[(string, string)]
  proc add(value, label: string) =
    if value.len > 0 and value notin seen:
      seen.incl(value)
      choices.add((value, label))
  for node in ui.graph.items:
    if idOf(node) == id or idOf(node) notin upstream: continue
    let kind = node.so("vsType", "")
    if kind in ["set", "ask", "for"]:
      let name = blockField(node, if kind == "for": "iterator" else: "name")
      if name.len > 0: add(name, plainText(node) & " · " & name)
    elif kind in ["luau", "process", "function"]:
      # Offer straightforward global assignments; custom expressions remain
      # available for dynamic values and arbitrary Luau programs.
      for line in blockField(node, "code").splitLines():
        let equals = line.find('=')
        if equals <= 0: continue
        let name = line[0 ..< equals].strip()
        if name.len == 0 or name[0] notin {'a'..'z', 'A'..'Z', '_'}: continue
        var valid = true
        for c in name:
          if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}: valid = false
        if valid: add(name, plainText(node) & " · " & name)
  for edge in ui.graph.items:
    if not edge.eqs("type", "edge") or edge.so("targetId", "") != id: continue
    let name = namedPort(ui.graph.g.getItem(id), edge["targetAnchor"])
    if name.len > 0: add("__input[" & luaQuote(name) & "]", "Connected input · " & name)
  result = choices

const qnoteInsertKinds = [("text", "Text"), ("h1", "Heading 1"), ("h2", "Heading 2"),
  ("h3", "Heading 3"), ("bullet", "Bulleted list"), ("number", "Numbered list"),
  ("alpha", "Lettered list"), ("newline", "Newline")]
  ## Per-part "Insert as" options -- only passed to blockValueBuilder for
  ## qnoteType's "text" field (see buildField below). Every other field's
  ## builder gets the default empty list and is completely unaffected.

proc blockValueBuilder(ui: EditorUi, item: Val, key: string, input, row: Node,
                       insertKinds: openArray[(string, string)] = [],
                       defaultInsert = "text", manualOnly = nilNode) =
  ## `insertKinds` gives every value its own "Insert as" (qnoteType's text);
  ## a value that never chose one inherits `defaultInsert`, the block's old
  ## single setting. `manualOnly` is that block-level row: it only applies
  ## in "Type manually" mode, so it hides while the builder owns the choice.
  # A seq, not the openArray parameter directly: nested closures below
  # (addPart, its handlers) outlive this call frame and cannot capture a
  # borrowed openArray view without violating memory safety.
  let insertKinds = @insertKinds
  let defaultInsert = if defaultInsert.len == 0: "text" else: defaultInsert
  let id = idOf(item)
  let metaKey = "__builder_" & key
  let meta = el("input", "")
  meta.typ = "hidden"
  meta.setData("field", metaKey)
  meta.value = blockField(item, metaKey)
  row.appendChild(meta)
  let mode = el("select", "qg-select qg-value-mode")
  mode.setAttribute("aria-label", "Value editing mode")
  mode.fillOptions([("builder", "Build from values"), ("manual", "Type manually")])
  mode.value = "builder"
  row.appendChild(mode)
  let panel = div0("qg-value-builder")
  row.appendChild(panel)
  var parts = newArr()
  var operation = if item.eqs("vsType", "output"): "text" else: "+"
  var lastExpression = input.value
  try:
    let saved = parseJson(meta.value)
    if saved["parts"].isArr and saved.so("expression", "") == input.value:
      parts = clone(saved["parts"])
      operation = saved.so("operation", operation)
      mode.value = saved.so("mode", "builder")
  except JsonError: discard
  # Inserted elements are joined in order, never added or compared.
  if insertKinds.len > 0: operation = "text"
  proc seed() =
    parts = newArr([obj(("kind", jstr("expr")), ("value", jstr(input.value)))])
  if parts.len == 0: seed()
  let options = ui.connectedBlockValues(id)
  proc persist() =
    let saved = obj(("mode", jstr(mode.value)), ("operation", jstr(operation)),
      ("parts", parts), ("expression", jstr(input.value)))
    meta.value = toJson(saved)
    let current = ui.graph.g.getItem(id)
    if current == nil: return
    let vs = clone(current["visualScript"])
    vs.put(key, jstr(input.value))
    vs.put(metaKey, jstr(meta.value))
    discard ui.graph.updateItem(id, o1("visualScript", vs), "Edit Block Values", record = true)
    lastExpression = input.value
  proc generate() =
    var expressions: seq[string]
    for part in parts:
      let insertAs = if insertKinds.len > 0: part.so("insertAs", defaultInsert) else: ""
      let expression = if insertAs == "newline":
          let n = part.so("count", "1").strip()
          "string.rep(\"\\n\", " & (if n.len == 0: "1" else: n) & ")"
        else:
          let value = part.so("value", "")
          if part.eqs("kind", "text"): luaQuote(value)
          elif value.strip().len == 0: "nil" else: value
      expressions.add(if operation == "text": "tostring(" & expression & ")" else: "(" & expression & ")")
    input.value = if expressions.len == 0: "nil"
      elif expressions.len == 1: expressions[0]
      else: "(" & expressions.join(if operation == "text": " .. " else: " " & operation & " ") & ")"
    persist()
  proc draw() {.closure.}
  var lines: seq[Node]
  var handles: seq[Node]
  var focusHandle = -1
  proc move(fromIndex, toIndex: int) =
    ## Reorders the values; the generated expression follows the new order.
    if fromIndex == toIndex or fromIndex < 0 or fromIndex >= parts.len: return
    var items: seq[Val]
    for i in 0 ..< parts.len: items.add parts[i]
    let moved = items[fromIndex]
    items.delete(fromIndex)
    items.insert(moved, clamp(toIndex, 0, items.len))
    parts = newArr(items)
    generate()
  proc draw() =
    panel.dropChildren()
    lines.setLen(0)
    handles.setLen(0)
    panel.hidden = mode.value != "builder"
    input.hidden = mode.value == "builder"
    if not manualOnly.isNil: manualOnly.hidden = mode.value == "builder"
    if panel.hidden: return
    if insertKinds.len == 0:
      let combine = el("select", "qg-select")
      combine.setAttribute("aria-label", "Combine values")
      combine.fillOptions([("text", "Join as text"), ("+", "Add"), ("-", "Subtract"),
        ("*", "Multiply"), ("/", "Divide"), ("==", "Equals"), ("~=", "Not equal"),
        (">", "Greater than"), ("<", "Less than"), ("and", "All true"), ("or", "Any true")])
      combine.value = operation
      combine.on("change", proc(e: Event) =
        operation = combine.value
        generate())
      panel.appendChild(combine)
    proc addPart(index: int, part: Val) =
      let line = div0("qg-value-part")
      let head = div0("qg-value-part-head")
      let handle = el("button", "qg-value-grip")
      handle.typ = "button"
      handle.setAttribute("aria-label", "Drag to reorder, or use the arrow keys")
      handle.setAttribute("title", "Drag to reorder")
      handle.html = "<svg width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" aria-hidden=\"true\">" &
        "<circle cx=\"9\" cy=\"6\" r=\"1.6\"/><circle cx=\"15\" cy=\"6\" r=\"1.6\"/>" &
        "<circle cx=\"9\" cy=\"12\" r=\"1.6\"/><circle cx=\"15\" cy=\"12\" r=\"1.6\"/>" &
        "<circle cx=\"9\" cy=\"18\" r=\"1.6\"/><circle cx=\"15\" cy=\"18\" r=\"1.6\"/></svg>"
      head.appendChild(handle)
      # Pointer events, not HTML drag and drop, so it works with touch too.
      var dragging = false
      var slot = index
      proc clearMarks() =
        for l in lines:
          l.removeClass("is-drop-before")
          l.removeClass("is-drop-after")
      handle.on("pointerdown", proc(e: Event) =
        if e.button != 0: return
        e.preventDefault()
        dragging = true
        slot = index
        handle.call("setPointerCapture", e.pointerId)
        line.addClass("is-dragging"))
      handle.on("pointermove", proc(e: Event) =
        if not dragging: return
        slot = 0
        for i, l in lines:
          let r = rect(l)
          if e.clientY > (r.top + r.bottom) / 2: slot = i + 1
        clearMarks()
        if slot < lines.len: lines[slot].addClass("is-drop-before")
        elif lines.len > 0: lines[^1].addClass("is-drop-after"))
      proc finish(e: Event) =
        if not dragging: return
        dragging = false
        line.removeClass("is-dragging")
        clearMarks()
        let target = if slot > index: slot - 1 else: slot
        if target != index:
          move(index, target)
          draw()
      handle.on("pointerup", finish)
      handle.on("pointercancel", finish)
      handle.on("keydown", proc(e: Event) =
        let target = if e.key == "ArrowUp": index - 1
                     elif e.key == "ArrowDown": index + 1
                     else: -1
        if target < 0 or target >= parts.len: return
        e.preventDefault()
        move(index, target)
        focusHandle = target
        draw())
      let insertAs = if insertKinds.len > 0: part.so("insertAs", defaultInsert) else: ""
      let kind = el("select", "qg-select")
      if insertKinds.len > 0:
        let insertSelect = el("select", "qg-select")
        insertSelect.setAttribute("aria-label", "Insert as")
        insertSelect.fillOptions(insertKinds)
        insertSelect.value = insertAs
        insertSelect.on("change", proc(e: Event) =
          part["insertAs"] = jstr(insertSelect.value)
          generate()
          draw())
        head.appendChild(insertSelect)
      else:
        head.appendChild(kind)
      let remove = el("button", "qg-value-remove")
      remove.typ = "button"
      remove.setAttribute("aria-label", "Remove this value")
      remove.setAttribute("title", "Remove")
      remove.appendChild(icon("trash", 16))
      remove.on("click", proc(e: Event) =
        let remaining = newArr()
        for i in 0 ..< parts.len:
          if i != index: remaining.push(parts[i])
        parts = remaining
        generate()
        draw())
      head.appendChild(remove)
      line.appendChild(head)
      let content = div0("qg-value-part-body")
      if insertAs == "newline":
        let label = el("span", "qg-value-count-label")
        label.text = "How many"
        content.appendChild(label)
        let count = el("input", "qg-input")
        count.typ = "number"
        count.setAttribute("aria-label", "How many newlines")
        count.setAttribute("min", "1")
        count.setAttribute("max", "50")
        count.setAttribute("step", "1")
        count.value = part.so("count", "1")
        count.on("change", proc(e: Event) =
          part["count"] = jstr(count.value)
          generate())
        content.appendChild(count)
      else:
        kind.setAttribute("aria-label", "Value source")
        kind.fillOptions([("text", "Text"), ("number", "Number"), ("variable", "Connected variable"), ("expr", "Expression")])
        kind.value = part.so("kind", "expr")
        if insertKinds.len > 0: content.appendChild(kind)
        let value = el(if kind.value == "variable": "select" else: "input", "qg-input")
        value.setAttribute("aria-label", "Value")
        if kind.value == "variable":
          var choices = @[("", "Choose a connected value…")]
          for option in options: choices.add(option)
          let selected = part.so("value", "")
          var found = selected.len == 0
          for option in options:
            if option[0] == selected: found = true
          if not found: choices.add((selected, selected & " (disconnected)"))
          value.fillOptions(choices)
        else:
          value.typ = if kind.value == "number": "number" else: "text"
          if kind.value == "number": value.setAttribute("step", "any")
        value.value = part.so("value", "")
        value.on("change", proc(e: Event) =
          part["value"] = jstr(value.value)
          generate())
        content.appendChild(value)
        kind.on("change", proc(e: Event) =
          part["kind"] = jstr(kind.value)
          part["value"] = jstr(if kind.value == "number": "0" else: "")
          generate()
          draw())
      line.appendChild(content)
      lines.add line
      handles.add handle
      panel.appendChild(line)
    for i in 0 ..< parts.len: addPart(i, parts[i])
    if focusHandle >= 0 and focusHandle < handles.len: handles[focusHandle].focus()
    focusHandle = -1
    let add = textButton("Add value", "qg-btn qg-btn-soft", "plus")
    add.on("click", proc(e: Event) =
      let fresh = obj(("kind", jstr("text")), ("value", jstr("")))
      if insertKinds.len > 0:
        # Keep a list going; anything else starts again as plain text.
        let previous = if parts.len > 0: parts[parts.len - 1].so("insertAs", defaultInsert) else: ""
        fresh["insertAs"] = jstr(if previous in ["bullet", "number", "alpha"]: previous else: "text")
      parts.push(fresh)
      generate()
      draw())
    panel.appendChild(add)
  mode.on("change", proc(e: Event) =
    if mode.value == "builder" and input.value != lastExpression: seed()
    # Switching modes preserves the expression until a value is edited.
    persist()
    draw())
  draw()

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

  if known and (d.inputPorts.len > 0 or d.outputPorts.len > 0):
    let portsToggle = switchInput()
    portsToggle.checked = item.tr("portsEnabled")
    portsToggle.on("change", proc(e: Event) =
      if ui.graph.g.getItem(id) != nil:
        discard ui.graph.updateItem(id, o1("portsEnabled", jbool(portsToggle.checked)),
                                    "Toggle Block Sockets", record = true))
    let portsRow = field(body, "Show input/output sockets", portsToggle, "qg-field-switch")
    let portsHint = el("small", "qg-field-hint")
    portsHint.text = "Expands the block to show its typed pins, so you can drag wires " &
      "straight into a field instead of typing a value."
    portsRow.appendChild(portsHint)

  var kindRow = nilNode
    ## qnoteType's block-level "Insert as" row, handed to the text field's
    ## builder so it can hide it while each value picks its own.
  proc buildField(spec: BlockFieldSpec) =
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
    of "qnoteKind":
      control = el("select", "qg-select")
      control.fillOptions([("text", "Regular text"), ("h1", "Heading 1"), ("h2", "Heading 2"),
        ("h3", "Heading 3"), ("bullet", "Bulleted list"), ("number", "Numbered list"),
        ("alpha", "Lettered list")])
    of "qnoteAnchorMode":
      control = el("select", "qg-select")
      control.fillOptions([("replace", "Replace the field"), ("before", "Before the field"),
                           ("after", "After the field")])
    of "qnoteTemplate":
      # Filled from the server: QNote's default templates, the library,
      # QNote plugins and, on request, the templates saved in one .qnote
      # file ("Select QNote file…"). Without a server there are none.
      control = el("select", "qg-select")
      let chosen = blockField(item, key)
      let chosenName = blockField(item, "templateName")
      control.fillOptions([(chosen, if chosen.len == 0: "Loading templates…"
                                    elif chosenName.len > 0: chosenName else: chosen)])
      let picker = control
      const pickFile = "__qnote_file__"
      var libraryOptions, fileOptions: seq[(string, string)]
      var serverOk = false
      let fileLabel = proc(entry: Val): string =
        valStr(entry["name"]) & " · " & valStr(entry["file"]).split('/')[^1]
      let render = proc(selected: string) =
        var options: seq[(string, string)]
        if selected.len == 0: options.add ("", "Choose a template…")
        options.add libraryOptions
        options.add fileOptions
        var found = selected.len == 0
        for (value, _) in options:
          if value == selected: found = true
        if not found:
          options.add (selected, (if chosenName.len > 0: chosenName else: selected) & " (missing)")
        if serverOk: options.add (pickFile, "Select QNote file…")
        elif options.len == 0: options.add ("", "Needs a QNote Vault server")
        picker.setProp("innerHTML", "")
        picker.fillOptions(options)
        picker.value = selected
        picker.disabled = not serverOk and selected.len == 0
      let commit = proc(value, label: string) =
        let current = ui.graph.g.getItem(id)
        if current == nil or not isScriptBlock(current): return
        let vs = if current["visualScript"].isObj: clone(current["visualScript"]) else: newObj()
        vs.put("template", jstr(value))
        # The display name rides along so the block reads well on the canvas.
        vs.put("templateName", jstr(label.replace(" (missing)", "")))
        discard ui.graph.updateItem(id, o1("visualScript", vs), "Choose QNote Template", record = true)
      let loadFile = proc(path: string, selectFirst: bool) =
        fetchBytes("/api/library/templates?file=" & encodeURIComponent(path), proc(ok: bool, data: string) =
          var list: Val
          try: list = parseJson(data)
          except JsonError: list = nil
          if not ok or list == nil or not list.isArr:
            let error = if list != nil and list.isObj: valStr(list["error"]) else: "could not read " & path
            if selectFirst: ui.toast("QNote file: " & error)
            render(blockField(ui.graph.g.getItem(id), key))
            return
          if list.len == 0:
            if selectFirst: ui.toast(path & " has no saved templates (QNote: Misc → Templates → Save in document)")
            render(blockField(ui.graph.g.getItem(id), key))
            return
          fileOptions.setLen 0
          for entry in list: fileOptions.add (valStr(entry["id"]), fileLabel(entry))
          if selectFirst:
            commit(fileOptions[0][0], fileOptions[0][1])
            render(fileOptions[0][0])
          else:
            render(blockField(ui.graph.g.getItem(id), key)))
      fetchBytes("/api/library/templates", proc(ok: bool, data: string) =
        serverOk = ok
        if ok:
          try:
            let list = parseJson(data)
            if list.isArr:
              for entry in list:
                let name = valStr(entry["name"])
                let origin = if entry.eqs("origin", "plugin"): " · " & valStr(entry["plugin"])
                             elif entry.eqs("origin", "default"): " · QNote"
                             else: ""
                libraryOptions.add (valStr(entry["id"]), name & origin)
          except JsonError: serverOk = false
        render(chosen)
        # A template from a .qnote file: list that file's other templates too.
        if serverOk and chosen.startsWith("file:") and chosen.count(':') >= 2:
          loadFile(chosen.split(':', 2)[2], false))
      picker.on("change", proc(e: Event) =
        let selectedValue = picker.value
        let previous = blockField(ui.graph.g.getItem(id), key)
        if selectedValue == pickFile:
          let (ok, path) = prompt("QNote file with saved templates (relative to the vault, e.g. Folder/Note.qnote)", "")
          if ok and path.strip.len > 0: loadFile(path.strip, true)
          else: render(previous)
          return
        let label = picker.getNode("selectedOptions").invoke("item", 0).toNode
        commit(selectedValue, if label.isNil: selectedValue else: label.getStr("textContent")))
    else:
      control = el("input", "qg-input" & (if spec.kind in ["expr", "name"]: " qg-mono" else: ""))
      control.typ = if spec.kind == "number": "number" else: "text"
      control.setAttribute("spellcheck", "false")
      control.setAttribute("autocapitalize", "off")
    control.setData("field", key)
    control.value = blockField(item, key)
    let input = control
    if spec.kind != "qnoteTemplate":  # commits template + its name together itself
      control.on("change", proc(e: Event) =
        clearTimeout(rt.codeTimer)
        ui.commitBlockField(id, key, input.value))
    let row = field(body, spec.label, control, if spec.kind == "code": "qg-field-stack" else: "")
    if spec.kind == "qnoteKind": kindRow = row
    if spec.hint.len > 0:
      let hint = el("small", "qg-field-hint")
      hint.text = spec.hint
      row.appendChild(hint)
    if spec.kind == "expr":
      if item.eqs("vsType", "qnoteType") and key == "text":
        ui.blockValueBuilder(item, key, input, row, qnoteInsertKinds,
                             jsTrim(blockField(item, "kind")), kindRow)
      else:
        ui.blockValueBuilder(item, key, input, row)

  # qnoteFormat / qnoteParagraphFormat: the property picker chooses which
  # QNote property to set, and the *shape* of the value control beside it
  # depends on that choice (a switch for a boolean property, a select for a
  # fixed-vocabulary one, a plain expression field for anything else) -- so
  # these two fields are built together here instead of through the generic
  # per-spec loop above, and picking a different property re-renders this
  # whole page to swap the value control's type in.
  if vsType in ["qnoteFormat", "qnoteParagraphFormat"]:
    let isFont = vsType == "qnoteFormat"
    let propOptions = if isFont:
        @[("Bold", "Bold"), ("Italic", "Italic"), ("Underline", "Underline"),
          ("StrikeThrough", "Strikethrough"), ("Superscript", "Superscript"),
          ("Subscript", "Subscript"), ("Name", "Font name"), ("Size", "Size"),
          ("Color", "Color"), ("Highlight", "Highlight")]
      else:
        @[("Alignment", "Alignment"), ("Style", "Style"), ("LineSpacing", "Line spacing"),
          ("SpaceBefore", "Space before"), ("SpaceAfter", "Space after"),
          ("FirstLineIndent", "First-line indent"), ("List", "List"), ("ListLevel", "List level")]
    let storedProp = jsTrim(blockField(item, "property"))
    let currentProp = if storedProp.len > 0: storedProp else: propOptions[0][0]
    let propSelect = el("select", "qg-select")
    propSelect.fillOptions(propOptions)
    propSelect.value = currentProp
    propSelect.on("change", proc(e: Event) =
      ui.commitBlockField(id, "property", propSelect.value)
      let fresh = ui.graph.g.getItem(id)
      if fresh != nil: ui.buildScriptInspector(fresh))
    discard field(body, "Property", propSelect)

    const boolProps = ["Bold", "Italic", "Underline", "StrikeThrough", "Superscript", "Subscript"]
    const enumProps = ["Alignment", "List"]
    if isFont and currentProp in boolProps:
      let valueSwitch = switchInput()
      valueSwitch.checked = blockField(item, "value") == "true"
      valueSwitch.on("change", proc(e: Event) =
        if ui.graph.g.getItem(id) != nil:
          ui.commitBlockField(id, "value", if valueSwitch.checked: "true" else: "false"))
      discard field(body, "Value", valueSwitch, "qg-field-switch")
    elif not isFont and currentProp in enumProps:
      let valueSelect = el("select", "qg-select")
      if currentProp == "Alignment":
        valueSelect.fillOptions([("\"left\"", "Left"), ("\"center\"", "Center"),
          ("\"right\"", "Right"), ("\"justify\"", "Justify")])
      else:
        valueSelect.fillOptions([("\"bullet\"", "Bullet"), ("\"number\"", "Number"),
          ("\"alpha\"", "Letter"), ("\"dash\"", "Dash"), ("\"none\"", "None")])
      valueSelect.value = blockField(item, "value")
      valueSelect.on("change", proc(e: Event) = ui.commitBlockField(id, "value", valueSelect.value))
      discard field(body, "Value", valueSelect)
    else:
      let valueInput = el("input", "qg-input qg-mono")
      valueInput.typ = "text"
      valueInput.setData("field", "value")
      valueInput.value = blockField(item, "value")
      valueInput.on("change", proc(e: Event) = ui.commitBlockField(id, "value", valueInput.value))
      let valueRow = field(body, "Value", valueInput)
      let valueHint = el("small", "qg-field-hint")
      valueHint.text = "A Luau expression, e.g. true, 14, or \"Arial\""
      valueRow.appendChild(valueHint)
  elif pluginFields.hasKey(vsType):
    # A plugin-registered block: no hardcoded field spec, so build its
    # fields from what its XML declared, through the exact same buildField
    # a built-in block's spec goes through above.
    for f in pluginFields[vsType]:
      buildField((f.key, f.label, (if f.kind == pfkExpr: "expr" else: "text"), ""))
  else:
    for spec in blockFieldSpecs(vsType): buildField(spec)

  if vsType == "start":
    let note = el("p", "qg-block-about")
    note.text = "Run starts here. With several Start blocks, they run top to bottom."
    body.appendChild(note)
  elif not known and vsType notin ["process", "function", "input"]:
    let note = el("p", "qg-block-about")
    note.text = "This block comes from an older document and is skipped when the script runs."
    body.appendChild(note)

  let actions = div0("qg-button-row")
  let save = textButton("Save", "qg-btn qg-btn-soft", "save")
  save.setAttribute("title", "Save this block's title and values")
  save.on("click", proc(e: Event) = ui.saveBlockInspector(id))
  rt.inspectorRun = textButton("Run from here", "qg-btn qg-btn-primary", "play")
  rt.inspectorRun.disabled = rt.running
  rt.inspectorRun.on("click", proc(e: Event) = ui.runScript(@[id]))
  let all = textButton("Run all", "qg-btn qg-btn-soft", "flag")
  all.on("click", proc(e: Event) = ui.runScript())
  actions.appendChild(save)
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
