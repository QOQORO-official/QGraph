# Included from editorui.nim: visual scripting with Luau.
#
# Script blocks are ordinary diagram nodes (kind "visualScript") joined by
# connectors. Run compiles the flow into one Luau program and hands it to the
# Luau VM -- luau-web, Luau compiled to WebAssembly -- running in a Web
# Worker (web/js/luau-worker.js). The program reaches the diagram only through
# requests that come back here: every document operation it asks for (find,
# set, add, connect, remove, select, output...) is carried out in Nim, and the
# whole run lands as one undo step.

const scriptPrelude = staticRead("data/prelude.luau")
const blockFailed = "__qgraph_block_failed__"
const scriptStepLimit = 100000
const consoleLimit = 500

type
  ScriptBlockDef = object
    vsType, label, description, color, iconName: string
    width, height: float64
    fields: seq[(string, string)]
    inputPorts, outputPorts: seq[(string, string)]
      ## Named, typed data sockets (name, type). These read and write the
      ## same `__input`/`__ports` slots the compiler already threads through
      ## `expr()` and `finishWith()` below -- declaring them here only gives
      ## the existing named-socket engine (geometry.nim's `variablePorts`)
      ## something to draw and connect. Purely additive: a block with none
      ## behaves exactly as before.

proc blockDef(vsType, label, description, color, iconName: string, width, height: float64,
              fields: openArray[(string, string)] = [],
              inputPorts: openArray[(string, string)] = [],
              outputPorts: openArray[(string, string)] = []): ScriptBlockDef =
  ScriptBlockDef(vsType: vsType, label: label, description: description, color: color,
                 iconName: iconName, width: width, height: height, fields: @fields,
                 inputPorts: @inputPorts, outputPorts: @outputPorts)

var scriptBlockDefs = @[
  blockDef("start", "Start", "Where the program begins", "#10b981", "flag", 180, 64,
    outputPorts = [("next", "flow")]),
  blockDef("output", "Output", "Show a value on the block, in the console or as an alert",
    "#22c55e", "message", 220, 118, [("value", "\"Hello, world!\""), ("mode", "block")],
    inputPorts = [("value", "any")], outputPorts = [("value", "any")]),
  blockDef("luau", "Luau code", "Any Luau: variables, loops, functions, doc.*", "#6366f1",
    "script", 260, 150, [("code", "-- Globals are shared by every block\n" &
      "count = (count or 0) + 1\nprint(\"count is\", count)")],
    inputPorts = [("in", "any")], outputPorts = [("result", "any")]),
  blockDef("set", "Set variable", "Store a value for later blocks", "#0ea5e9", "variable", 210, 76,
    [("name", "count"), ("value", "0")],
    inputPorts = [("value", "any")], outputPorts = [("value", "any")]),
  blockDef("condition", "If", "Follow the true or the false connector", "#f59e0b", "branch",
    210, 92, [("test", "count > 3")], inputPorts = [("test", "bool")]),
  blockDef("for", "Repeat", "Count through a range of numbers", "#f97316", "loop", 210, 92,
    [("iterator", "i"), ("from", "1"), ("to", "3"), ("step", "1")],
    inputPorts = [("from", "number"), ("to", "number"), ("step", "number")]),
  blockDef("while", "While", "Loop while a condition holds", "#a855f7", "loop", 210, 92,
    [("condition", "count < 10"), ("max", "100")], inputPorts = [("condition", "bool")]),
  blockDef("ask", "Ask", "Ask the user to type a value", "#3b82f6", "ask", 230, 76,
    [("name", "answer"), ("message", "\"What is your name?\""), ("default", "\"\"")],
    inputPorts = [("message", "string"), ("default", "any")], outputPorts = [("value", "any")]),
  blockDef("delay", "Wait", "Pause for a number of seconds", "#eab308", "clock", 180, 76,
    [("seconds", "1")], inputPorts = [("seconds", "number")]),
  blockDef("shape", "Set shape", "Change a shape on the canvas", "#ec4899", "wand", 230, 92,
    [("target", "Process"), ("property", "fill"), ("value", "\"#fde68a\"")],
    inputPorts = [("target", "string"), ("value", "any")], outputPorts = [("value", "any")]),
  blockDef("qnoteOpen", "Open QNote", "Target a QNote document: leave the path blank for the one open now",
    "#2563eb", "note", 230, 76, [("path", "")], inputPorts = [("path", "string")], outputPorts = [("next", "flow")]),
  blockDef("qnoteType", "Insert text", "Type text, a heading, or a list item at the cursor",
    "#2563eb", "edit", 220, 92, [("text", "\"Hello, world!\""), ("kind", "text")],
    inputPorts = [("text", "string")], outputPorts = [("next", "flow")]),
  blockDef("qnoteParagraph", "New paragraph", "Start a new paragraph",
    "#2563eb", "page", 200, 64),
  blockDef("qnoteFind", "Find & Replace", "Replace every match in the document",
    "#2563eb", "search", 230, 108, [("find", "\"\""), ("replace", "\"\""), ("matchCase", "false")],
    inputPorts = [("find", "string"), ("replace", "string")]),
  blockDef("qnoteFormat", "Character format",
    "Set a character property (Bold, Italic, Underline, Size, …) on the current selection",
    "#2563eb", "bold", 220, 92, [("property", "Bold"), ("value", "true")],
    inputPorts = [("value", "any")]),
  blockDef("qnoteParagraphFormat", "Paragraph format",
    "Set a paragraph property (Alignment, …) on the current selection",
    "#2563eb", "indent", 220, 92, [("property", "Alignment"), ("value", "\"center\"")],
    inputPorts = [("value", "any")]),
  blockDef("qnoteMessage", "QNote message", "Show a message box in the QNote editor",
    "#2563eb", "message", 220, 76, [("text", "\"Done\"")], inputPorts = [("text", "string")]),
  blockDef("qnoteTemplate", "QNote template", "Insert a template from the server library at the cursor",
    "#2563eb", "page", 240, 92, [("template", ""), ("templateName", ""), ("variables", "{}")],
    inputPorts = [("variables", "any")], outputPorts = [("next", "flow")]),
  # Anchors: a named field marks where content goes; images and tables can be
  # named and found again. These compile to QNote's own Luau anchor API
  # (Fields(n):Select, Selection:InsertImage/InsertXml/NameObject,
  # Images(n):SetSource, Tables(n):Fill).
  blockDef("qnoteAnchor", "Go to field", "Move the cursor to a named field, or replace the field",
    "#2563eb", "link", 230, 92, [("field", "\"Logo\""), ("mode", "replace")],
    inputPorts = [("field", "string")], outputPorts = [("next", "flow")]),
  blockDef("qnoteImage", "Insert image", "Insert a picture at the cursor from an http(s) or data: URL",
    "#2563eb", "image", 240, 108,
    [("src", "\"https://example.com/logo.png\""), ("width", ""), ("height", ""), ("name", "")],
    inputPorts = [("src", "string"), ("width", "number")], outputPorts = [("next", "flow")]),
  blockDef("qnoteImageSource", "Replace image", "Swap the picture of a named image, keeping its size and place",
    "#2563eb", "image", 240, 92, [("target", "\"logo\""), ("src", "\"https://example.com/new.png\"")],
    inputPorts = [("target", "string"), ("src", "string")], outputPorts = [("next", "flow")]),
  blockDef("qnoteTable", "Insert table", "Insert a table at the cursor, optionally named and filled",
    "#2563eb", "table", 240, 108, [("rows", "2"), ("cols", "3"), ("name", ""), ("data", "")],
    inputPorts = [("data", "any")], outputPorts = [("next", "flow")]),
  blockDef("qnoteTableFill", "Fill table", "Fill a named table from a list of rows, adding rows it lacks",
    "#2563eb", "table", 240, 92,
    [("target", "\"results\""), ("data", "{{\"Sample\", \"Value\"}, {\"A\", 1}}")],
    inputPorts = [("target", "string"), ("data", "any")], outputPorts = [("next", "flow")]),
  blockDef("qnoteNameObject", "Name object", "Name the selected image or table (or the one just before the cursor)",
    "#2563eb", "edit", 220, 76, [("name", "\"results\"")],
    inputPorts = [("name", "string")], outputPorts = [("next", "flow")]),
  blockDef("qnoteXml", "Insert XML", "Insert a QNote XML fragment (text, tables, images) at the cursor",
    "#2563eb", "code", 250, 108,
    [("xml", "<doc><qotext>Inserted from QoChart</qotext></doc>")],
    inputPorts = [("xml", "string")], outputPorts = [("next", "flow")]),
  blockDef("qnoteRun", "Run & Save", "Send the QNote program and wait for the result",
    "#2563eb", "play", 220, 108, [("save", "true"), ("timeoutMs", "60000")],
    inputPorts = [("next", "flow")], outputPorts = [("result", "any")]),
]

type
  PluginParamKind = enum ppkLiteral, ppkField
  PluginParam = object
    name: string        ## the fixed operation's parameter name
    kind: PluginParamKind
    text: string        ## the literal string, or (kind == ppkField) a field key
  PluginOperation = object
    opRef: string        ## one of the five fixed operations, e.g. "qnote.insertText"
    params: seq[PluginParam]
  PluginFieldKind = enum pfkText, pfkExpr
  PluginFieldDef = object
    key, label, default: string
    kind: PluginFieldKind

var pluginOperations = initTable[string, PluginOperation]()
  ## vsType -> the one fixed operation a plugin-registered block runs.
  ## Declarative only, by design: a plugin can wire its own fields/ports
  ## around one of five already-implemented, safe operations -- never
  ## supply Luau of its own. See blockBody's generic dispatch below and
  ## loadPlugins/parsePluginXml further down for how this gets populated.
var pluginFields = initTable[string, seq[PluginFieldDef]]()
  ## vsType -> its declared fields, so buildScriptInspector (script_ui.nim)
  ## can render them the same generic way as a built-in block's fields.

proc refreshScriptBlockPalette(ui: EditorUi)
  ## Defined in script_ui.nim; forward-declared so loadPlugins (this file)
  ## can ask the Script tab to redraw its block palette once plugin blocks
  ## have arrived, the same forward-reference pattern handleWorkerMessage
  ## already uses below.

proc portsString(ports: seq[(string, string)]): string =
  var parts: seq[string]
  for (name, kind) in ports: parts.add name & ":" & kind
  parts.join(", ")

proc findBlockDef(vsType: string): (bool, ScriptBlockDef) =
  for d in scriptBlockDefs:
    if d.vsType == vsType: return (true, d)
  (false, ScriptBlockDef())

proc scriptTemplate(d: ScriptBlockDef): Val =
  result = newObj()
  result["kind"] = jstr("visualScript")
  result["vsType"] = jstr(d.vsType)
  result["shape"] = jstr("rect")
  result["width"] = jnum(d.width)
  result["height"] = jnum(d.height)
  result["text"] = jstr(d.label)
  result["fill"] = jstr("#ffffff")
  result["stroke"] = jstr(d.color)
  result["strokeWidth"] = jnum(1.5)
  result["radius"] = jnum(10)
  result["textColor"] = jstr("#1e293b")
  result["fontSize"] = jnum(12)
  result["editable"] = jfalse
  result["shadow"] = jtrue
  if d.inputPorts.len > 0 or d.outputPorts.len > 0:
    # Sockets exist and can already be wired even while collapsed (an edge
    # keeps the socket it was drawn to); this only controls whether they are
    # drawn on the block itself. Visible and connectable by default -- a pin
    # you can't see or click isn't a pin -- with a per-block inspector switch
    # to hide them again once a canvas gets crowded.
    result["portsEnabled"] = jtrue
    result["inputPorts"] = jstr(portsString(d.inputPorts))
    result["outputPorts"] = jstr(portsString(d.outputPorts))
  let vs = newObj()
  vs["label"] = jstr(d.label)
  vs["vsType"] = jstr(d.vsType)
  for (key, value) in d.fields: vs.put(key, jstr(value))
  vs["lastResult"] = jstr("")
  vs["lastError"] = jstr("")
  result["visualScript"] = vs

proc isScriptBlock(item: Val): bool = item != nil and item.eqs("kind", "visualScript")

proc blockField(item: Val, key: string): string =
  let vs = item["visualScript"]
  if vs != nil and vs.isObj and not nullish(vs.get(key)): str(vs.get(key)) else: ""

proc plainText(item: Val): string = jsTrim(stripTags(valStr(item["text"])))

proc selectedScriptBlock(ui: EditorUi): Val =
  let selection = ui.graph.getSelection()
  if selection.len == 1 and isScriptBlock(selection[0]): selection[0] else: nil

# ---------------------------------------------------------------- compiler --

proc luaQuote(s: string): string =
  result = "\""
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\0'..'\x08', '\x0B', '\x0C', '\x0E'..'\x1F', '\x7F':
      result.add "\\" & align($ord(c), 3, '0')
    else: result.add c
  result.add '"'

proc isLuauName(s: string, dotted = false): bool =
  ## A variable name (or, with `dotted`, a field path such as player.score).
  const reserved = ["and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until",
    "while", "continue"]
  let parts = if dotted: s.split('.') else: @[s]
  for part in parts:
    if part.len == 0 or part in reserved or part[0] notin {'a'..'z', 'A'..'Z', '_'}: return false
    for c in part:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}: return false
  true

proc edgeLabel(edge: Val): string = plainText(edge).toLowerAscii()

const falseLabels = ["false", "no", "else", "otherwise", "f", "n", "0"]
const doneLabels = ["done", "exit", "end", "after", "next", "finish", "finished", "break", "out"]

proc splitBranches(outs: seq[(string, string)], secondary: openArray[string]): (seq[string], seq[string]) =
  ## Connectors into (primary, secondary) by their labels; unlabeled ones
  ## fill the primary side first, then the secondary one.
  var primary, other, unlabeled: seq[string]
  for (label, target) in outs:
    if label in secondary: other.add target
    elif label.len == 0: unlabeled.add target
    else: primary.add target
  for target in unlabeled:
    if primary.len == 0: primary.add target
    elif other.len == 0: other.add target
    else: primary.add target
  (primary, other)

proc nextList(targets: seq[string]): string =
  if targets.len == 0: return "nil"
  var parts: seq[string]
  for t in targets: parts.add luaQuote(t)
  "{" & parts.join(", ") & "}"

proc expr(item: Val, key, fallback: string): string =
  let text = jsTrim(blockField(item, key))
  let authored = if text.len == 0: fallback else: "(" & text & ")"
  # A builder expression already joins its chosen variables and literals;
  # a data wire must not replace that entire expression with one raw value.
  try:
    let meta = parseJson(blockField(item, "__builder_" & key))
    if meta.eqs("mode", "builder"): return authored
  except: discard
  "(if __input[" & luaQuote(key) & "] ~= nil then __input[" & luaQuote(key) &
    "] else " & authored & ")"

proc namedPort(node, anchor: Val): string =
  if node == nil or anchor == nil: return ""
  let direction = anchor.so("portKind", "")
  if direction notin ["input", "output"]: return ""
  let labels = portLabels(node, direction)
  let index = int(num(anchor["portIndex"]))
  if anchor["portIndex"].isNum and index >= 0 and index < labels.len: labels[index][0]
  else: anchor.so("portName", "")

proc namedPortIsFlow(node, anchor: Val): bool =
  let name = namedPort(node, anchor)
  for (key, kind) in portLabels(node, anchor.so("portKind", "")):
    if key == name and kind == "flow": return true

proc emitQnoteInsert(body: var seq[string], kind, textExpr: string) =
  ## One Selection:* call inserting `textExpr` (a QGraph-Luau expression
  ## that evaluates to the text) as `kind` -- shared by the single-value
  ## "Insert text" path and each part of a multi-part one, so both stay in
  ## sync with QNote's actual automation API (verified against its runtime
  ## source, not guessed): InsertHeading wants "h1"/"h2"/"h3", not a number;
  ## a list item sets ParagraphFormat.List, types the text, then resets it
  ## so it never leaks into whatever comes next in the program.
  case kind
  of "h1", "h2", "h3":
    body.add "\t__qnoteProgram = __qnoteProgram .. \"Selection:InsertHeading(\" .. qquote(" &
      textExpr & ") .. \", \" .. qquote(" & luaQuote(kind) & ") .. \")\\n\""
  of "bullet", "number", "alpha":
    body.add "\t__qnoteProgram = __qnoteProgram .. \"Selection.ParagraphFormat.List = \" .. qquote(" &
      luaQuote(kind) & ") .. \"\\n\""
    body.add "\t__qnoteProgram = __qnoteProgram .. \"Selection:TypeText(\" .. qquote((" &
      textExpr & ") .. \"\\n\") .. \")\\n\""
    body.add "\t__qnoteProgram = __qnoteProgram .. \"Selection.ParagraphFormat.List = \" .. qquote(\"none\") .. \"\\n\""
  else:
    body.add "\t__qnoteProgram = __qnoteProgram .. \"Selection:TypeText(\" .. qquote(" &
      textExpr & ") .. \")\\n\""

proc emitQnoteFontSet(body: var seq[string], property, valueExpr: string) =
  ## Factored out of the "qnoteFormat" block body so a plugin-registered
  ## block built on the "qnote.setFontProperty" operation runs through the
  ## exact same, already-correct codegen -- see qval in prelude.luau for why
  ## this isn't tostring(): a string value must land re-quoted.
  body.add "\t__qnoteProgram = __qnoteProgram .. \"Selection.Font." & property & " = \" .. qval(" &
    valueExpr & ") .. \"\\n\""

proc emitQnoteParagraphSet(body: var seq[string], property, valueExpr: string) =
  ## The "qnoteParagraphFormat" block body, factored the same way as
  ## emitQnoteFontSet above, for the "qnote.setParagraphProperty" operation.
  body.add "\t__qnoteProgram = __qnoteProgram .. \"Selection.ParagraphFormat." & property &
    " = \" .. qval(" & valueExpr & ") .. \"\\n\""

proc emitShapeSet(body: var seq[string], target, prop, valueExpr: string): string =
  ## The "shape" block body, factored for the "doc.setShapeProperty"
  ## operation. Returns an error message ("" on success) -- and, matching
  ## today's built-in "shape" block exactly, `target`/`prop` are always
  ## resolved from plain field text upstream, never through expr(), so a
  ## wired input on either has no effect either way; only `valueExpr` is a
  ## real Luau expression.
  if target.len == 0: return "Name the shape to change (its label or id)"
  if not isLuauName(prop): return "“" & prop & "” is not a shape property"
  body.add "\tlocal target = doc.find(" & luaQuote(target) & ")"
  body.add "\tif target == nil then error(" & luaQuote("there is no shape labelled “" & target & "”") & ", 0) end"
  body.add "\tdoc.set(target.id, { " & prop & " = " & valueExpr & " })"
  ""

proc emitValueCompute(body: var seq[string], name, valueExpr: string): string =
  ## The "set" block body, factored for the "value.compute" operation.
  ## Returns an error message ("" on success).
  if not isLuauName(name, dotted = true):
    return "“" & name & "” is not a variable name (letters, digits and _, not starting with a digit)"
  body.add "\t" & name & " = " & valueExpr
  ""

proc qnotePartExpr(part: Val): string =
  ## Mirrors script_ui.nim's blockValueBuilder.generate(): a "text" part is
  ## quoted, everything else (number/expr/variable) is used as authored --
  ## already valid Luau -- so reconstructing one part here in isolation
  ## produces the same fragment the builder's own preview would for it.
  let value = part.so("value", "")
  if part.eqs("kind", "text"): luaQuote(value)
  elif value.strip().len == 0: "nil"
  else: value

proc qnoteMultiParts(item: Val): seq[Val] =
  ## The "text" field's builder values when the builder owns it: each value
  ## is inserted as its own element, with its own "Insert as". Empty in
  ## "Type manually" mode (or if the saved builder no longer matches the
  ## text), where the block-level "Insert as" applies to the whole text.
  try:
    let meta = parseJson(blockField(item, "__builder_text"))
    if not meta.eqs("mode", "builder") or not meta["parts"].isArr: return
    if meta.so("expression", "") != blockField(item, "text"): return
    for part in meta["parts"]: result.add part
  except JsonError: discard

proc blockBody(item: Val, outs: seq[(string, string)], body: var seq[string]): string =
  ## Appends the Luau for one block; returns an error message or "".
  let id = idOf(item)
  let label = plainText(item)
  var targets: seq[string]
  for (_, t) in outs:
    if t notin targets: targets.add t
  let next = "\treturn " & nextList(targets)
  let vsType = if item["vsType"].isStr: item["vsType"].s else: ""
  template finishWith(value: string) =
    if item.tr("portsEnabled"):
      body.add "\t__ports[" & luaQuote(id) & "] = __ports[" & luaQuote(id) & "] or {}"
      for port in variablePorts(item):
        if port.direction == "output":
          body.add "\t__ports[" & luaQuote(id) & "][" & luaQuote(port.name) & "] = " & value
    body.add next
  case vsType
  of "start":
    finishWith("nil")
  of "luau", "process", "function":
    let code = blockField(item, "code")
    if jsTrim(code).len > 0:
      body.add "\tlocal __result = (function()"
      for line in code.split('\n'): body.add line
      body.add "\tend)()"
      body.add "\tif __result ~= nil then result = __result end"
    let variable = scriptCodeVariable(item)
    finishWith(if variable.len > 0:
      "(if __result ~= nil then __result else " & variable & ")"
      else: "result")
  of "set":
    let name = jsTrim(blockField(item, "name"))
    let valueExpr = expr(item, "value", "nil")
    let err = emitValueCompute(body, name, valueExpr)
    if err.len > 0: return err
    finishWith(name)
  of "condition":
    let (yes, no) = splitBranches(outs, falseLabels)
    body.add "\tif " & expr(item, "test", "false") & " then return " & nextList(yes) & " end"
    body.add "\treturn " & nextList(no)
  of "for":
    let name = jsTrim(blockField(item, "iterator"))
    if not isLuauName(name, dotted = true):
      return "“" & name & "” is not a variable name"
    let (loop, done) = splitBranches(outs, doneLabels)
    body.add "\tlocal s = __loops[" & luaQuote(id) & "]"
    body.add "\tif s == nil then"
    body.add "\t\ts = { i = " & expr(item, "from", "1") & ", to = " & expr(item, "to", "1") &
      ", step = " & expr(item, "step", "1") & " }"
    body.add "\t\tif type(s.i) ~= \"number\" or type(s.to) ~= \"number\" or type(s.step) ~= \"number\" or s.step == 0 then"
    body.add "\t\t\terror(\"Repeat needs numbers for from, to and a non-zero step\", 0)"
    body.add "\t\tend"
    body.add "\t\t__loops[" & luaQuote(id) & "] = s"
    body.add "\telse"
    body.add "\t\ts.i += s.step"
    body.add "\tend"
    body.add "\tif (s.step > 0 and s.i <= s.to) or (s.step < 0 and s.i >= s.to) then"
    body.add "\t\t" & name & " = s.i"
    body.add "\t\treturn " & nextList(loop)
    body.add "\tend"
    body.add "\t__loops[" & luaQuote(id) & "] = nil"
    body.add "\treturn " & nextList(done)
  of "while":
    let (loop, done) = splitBranches(outs, doneLabels)
    let limit = jsNumber(jsTrim(blockField(item, "max")))
    let maxText = if limit != limit or limit <= 0: "0" else: jsStr(floor(limit))
    body.add "\tlocal n = (__loops[" & luaQuote(id) & "] or 0) + 1"
    body.add "\tif " & maxText & " > 0 and n > " & maxText & " then"
    body.add "\t\twarn(" & luaQuote(label & ": stopped after " & maxText & " rounds") & ")"
    body.add "\telseif " & expr(item, "condition", "false") & " then"
    body.add "\t\t__loops[" & luaQuote(id) & "] = n"
    body.add "\t\treturn " & nextList(loop)
    body.add "\tend"
    body.add "\t__loops[" & luaQuote(id) & "] = nil"
    body.add "\treturn " & nextList(done)
  of "output":
    let mode = blockField(item, "mode")
    body.add "\toutput(" & expr(item, "value", "nil") & ", " &
      luaQuote(if mode in ["console", "alert"]: mode else: "block") & ")"
    finishWith(expr(item, "value", "nil"))
  of "ask":
    let name = jsTrim(blockField(item, "name"))
    if not isLuauName(name, dotted = true):
      return "“" & name & "” is not a variable name"
    body.add "\t" & name & " = prompt(" & expr(item, "message", "\"\"") & ", " &
      expr(item, "default", "nil") & ")"
    finishWith(name)
  of "delay":
    body.add "\twait(" & expr(item, "seconds", "1") & ")"
    finishWith("nil")
  of "shape":
    let target = jsTrim(blockField(item, "target"))
    let prop = jsTrim(blockField(item, "property"))
    let valueExpr = expr(item, "value", "nil")
    let err = emitShapeSet(body, target, prop, valueExpr)
    if err.len > 0: return err
    finishWith(valueExpr)
  of "qnoteOpen":
    body.add "\t__qnoteProgram = \"\""
    body.add "\t__qnoteTarget = " & expr(item, "path", "\"\"")
    finishWith("nil")
  of "qnoteType":
    let kind = jsTrim(blockField(item, "kind"))
    let multiParts = qnoteMultiParts(item)
    if multiParts.len > 0:
      # A value that never chose its own "Insert as" keeps the block's.
      let inherited = if kind.len == 0: "text" else: kind
      for part in multiParts:
        let insertAs = part.so("insertAs", inherited)
        if insertAs == "newline":
          let countText = part.so("count", "1").strip()
          var count = 1
          try: count = parseInt(countText)
          except ValueError: count = 1
          count = max(1, min(50, count))
          emitQnoteInsert(body, "text", luaQuote(repeat('\n', count)))
        else:
          emitQnoteInsert(body, insertAs, qnotePartExpr(part))
    else:
      emitQnoteInsert(body, kind, expr(item, "text", "\"\""))
    finishWith("nil")
  of "qnoteParagraph":
    body.add "\t__qnoteProgram = __qnoteProgram .. \"Selection:TypeParagraph()\\n\""
    finishWith("nil")
  of "qnoteFind":
    body.add "\t__qnoteProgram = __qnoteProgram .. \"ActiveDocument.Content.Find:Execute({FindText=\" .. qquote(" &
      expr(item, "find", "\"\"") & ") .. \", ReplaceWith=\" .. qquote(" & expr(item, "replace", "\"\"") &
      ") .. \", MatchCase=\" .. tostring(" & expr(item, "matchCase", "false") & ") .. \"})\\n\""
    finishWith("nil")
  of "qnoteFormat":
    let prop = jsTrim(blockField(item, "property"))
    if not isLuauName(prop): return "“" & prop & "” is not a character-format property"
    emitQnoteFontSet(body, prop, expr(item, "value", "nil"))
    finishWith("nil")
  of "qnoteParagraphFormat":
    let prop = jsTrim(blockField(item, "property"))
    if not isLuauName(prop): return "“" & prop & "” is not a paragraph-format property"
    emitQnoteParagraphSet(body, prop, expr(item, "value", "nil"))
    finishWith("nil")
  of "qnoteMessage":
    body.add "\t__qnoteProgram = __qnoteProgram .. \"ActiveDocument:Message(\" .. qquote(" &
      expr(item, "text", "\"\"") & ") .. \")\\n\""
    finishWith("nil")
  of "qnoteTemplate":
    # Not Luau QNote can run: a directive line (a Luau comment, harmless if
    # nothing reads it) that QNote's bridge, vault-bridge.js, cuts the program
    # at -- Luau before it runs, then the template from the server library
    # goes in at the cursor, then the rest.
    let templateId = jsTrim(blockField(item, "template"))
    if templateId.len == 0:
      return "Choose a QNote template (the list comes from a QNote Vault server)"
    body.add "\t__qnoteProgram = __qnoteProgram .. \"--@qnote-template \" .. json.encode({ id = " &
      luaQuote(templateId) & ", variables = " & expr(item, "variables", "{}") & " }) .. \"\\n\""
    finishWith("nil")
  of "qnoteAnchor":
    let mode = jsTrim(blockField(item, "mode"))
    let safeMode = if mode in ["before", "after"]: mode else: "replace"
    body.add "\t__qnoteProgram = __qnoteProgram .. \"ActiveDocument.Fields(\" .. qquote(" &
      expr(item, "field", "\"\"") & ") .. \"):Select(\\\"" & safeMode & "\\\")\\n\""
    finishWith("nil")
  of "qnoteImage":
    body.add "\t__qnoteProgram = __qnoteProgram .. \"Selection:InsertImage(\" .. qquote(" &
      expr(item, "src", "\"\"") & ") .. \", \" .. qnum(" & expr(item, "width", "nil") &
      ") .. \", \" .. qnum(" & expr(item, "height", "nil") & ") .. \")\\n\""
    let name = jsTrim(blockField(item, "name"))
    if name.len > 0:
      # Right after an inline insert the picture sits just before the cursor,
      # which is what NameObject names when nothing is selected.
      body.add "\t__qnoteProgram = __qnoteProgram .. \"Selection:NameObject(\" .. qquote(" &
        expr(item, "name", "\"\"") & ") .. \")\\n\""
    finishWith("nil")
  of "qnoteImageSource":
    body.add "\t__qnoteProgram = __qnoteProgram .. \"ActiveDocument.Images(\" .. qval(" &
      expr(item, "target", "1") & ") .. \"):SetSource(\" .. qquote(" & expr(item, "src", "\"\"") &
      ") .. \")\\n\""
    finishWith("nil")
  of "qnoteTable":
    let name = jsTrim(blockField(item, "name"))
    let data = jsTrim(blockField(item, "data"))
    var line = "\t__qnoteProgram = __qnoteProgram .. \"do local t = ActiveDocument.Tables:Add(\" .. qnum(" &
      expr(item, "rows", "2") & ") .. \", \" .. qnum(" & expr(item, "cols", "3") & ") .. \")"
    if name.len > 0: line &= "; t.Name = \" .. qquote(" & expr(item, "name", "\"\"") & ") .. \""
    if data.len > 0 or item.tr("portsEnabled"):
      # A wired or authored list of rows fills it; nil leaves it empty.
      line &= "; local rows = \" .. qlit(" & expr(item, "data", "nil") & ") .. \"; if rows then t:Fill(rows) end"
    body.add line & " end\\n\""
    finishWith("nil")
  of "qnoteTableFill":
    body.add "\t__qnoteProgram = __qnoteProgram .. \"ActiveDocument.Tables(\" .. qval(" &
      expr(item, "target", "1") & ") .. \"):Fill(\" .. qlit(" & expr(item, "data", "{}") & ") .. \")\\n\""
    finishWith("nil")
  of "qnoteNameObject":
    body.add "\t__qnoteProgram = __qnoteProgram .. \"Selection:NameObject(\" .. qquote(" &
      expr(item, "name", "\"\"") & ") .. \")\\n\""
    finishWith("nil")
  of "qnoteXml":
    # Authored as literal XML (a code field, not a Luau expression); a wire
    # into the xml socket replaces it with a computed string.
    let authored = luaQuote(blockField(item, "xml"))
    body.add "\t__qnoteProgram = __qnoteProgram .. \"Selection:InsertXml(\" .. qquote(" &
      "if __input[\"xml\"] ~= nil then __input[\"xml\"] else " & authored & ") .. \")\\n\""
    finishWith("nil")
  of "qnoteRun":
    body.add "\tlocal __qnoteResult = qnote.run(__qnoteTarget, __qnoteProgram, { save = " &
      expr(item, "save", "true") & ", timeoutMs = tonumber(" & expr(item, "timeoutMs", "60000") & ") })"
    finishWith("__qnoteResult")
  of "input":
    # Documents from the earlier editor: an Input card exports variables.
    try:
      let vars = parseJson(blockField(item, "inputVars"))
      if vars.isArr:
        for v in vars:
          let name = valStr(v["name"])
          if not isLuauName(name): continue
          let value = valStr(v["value"])
          let number = jsNumber(value)
          body.add "\t" & name & " = " &
            (if v.eqs("type", "number") and number == number: jsStr(number) else: luaQuote(value))
    except JsonError: discard
    finishWith("nil")
  else:
    if pluginOperations.hasKey(vsType):
      let operation = pluginOperations[vsType]
      let fields = pluginFields.getOrDefault(vsType, @[])
      proc find(name: string): (bool, PluginParam) =
        for p in operation.params:
          if p.name == name: return (true, p)
      proc fieldKind(key: string): PluginFieldKind =
        for f in fields:
          if f.key == key: return f.kind
        pfkText
      proc text(name, fallback: string): string =
        ## A compile-time-known plain-text value -- a property name, an
        ## "insert as" tag -- never a runtime expression.
        let (found, p) = find(name)
        if not found: return fallback
        case p.kind
        of ppkLiteral: p.text
        of ppkField: jsTrim(blockField(item, p.text))
      proc lexpr(name, fallback: string): string =
        ## A Luau expression. A field declared kind="expr" goes through the
        ## normal expr() -- data-wire and value-builder support included, the
        ## same as any built-in block's expr field; a literal or a kind="text"
        ## field becomes a quoted string-literal expression.
        let (found, p) = find(name)
        if not found: return fallback
        case p.kind
        of ppkLiteral: luaQuote(p.text)
        of ppkField:
          if fieldKind(p.text) == pfkExpr: expr(item, p.text, fallback)
          else: luaQuote(jsTrim(blockField(item, p.text)))
      case operation.opRef
      of "qnote.insertText":
        emitQnoteInsert(body, text("kind", "text"), lexpr("text", "\"\""))
        finishWith("nil")
      of "qnote.setFontProperty":
        let prop = text("property", "")
        if not isLuauName(prop): return "“" & prop & "” is not a character-format property"
        emitQnoteFontSet(body, prop, lexpr("value", "nil"))
        finishWith("nil")
      of "qnote.setParagraphProperty":
        let prop = text("property", "")
        if not isLuauName(prop): return "“" & prop & "” is not a paragraph-format property"
        emitQnoteParagraphSet(body, prop, lexpr("value", "nil"))
        finishWith("nil")
      of "doc.setShapeProperty":
        let valueExpr = lexpr("value", "nil")
        let err = emitShapeSet(body, text("target", ""), text("property", ""), valueExpr)
        if err.len > 0: return err
        finishWith(valueExpr)
      of "value.compute":
        let name = text("name", "")
        let valueExpr = lexpr("value", "nil")
        let err = emitValueCompute(body, name, valueExpr)
        if err.len > 0: return err
        finishWith(name)
      else:
        body.add "\twarn(" & luaQuote(vsType & ": unknown plugin operation “" & operation.opRef & "”") & ")"
        finishWith("nil")
    else:
      body.add "\twarn(" & luaQuote((if label.len > 0: label else: vsType) &
        ": this kind of block does not run here, so it was skipped") & ")"
      finishWith("nil")
  ""

proc compileScript(ui: EditorUi, entryIds: seq[string] = @[]): ScriptProgram =
  let g = ui.graph.g
  let hidden = g.hiddenLayerIds()
  var blocks: seq[Val]
  var isBlock = initHashSet[string]()
  for item in g.items:
    if isScriptBlock(item) and not item["visible"].isFalse and
        (nullish(item["layer"]) or str(item["layer"]) notin hidden):
      blocks.add item
      isBlock.incl idOf(item)
  if blocks.len == 0:
    result.error = "There are no script blocks yet. Add a Start block from the Script tab."
    return
  var outs = initTable[string, seq[(string, string)]]()
  var dataInputs = initTable[string, seq[(string, string, string)]]()
  var incoming = initHashSet[string]()
  for item in g.items:
    if not item.eqs("type", "edge") or item["visible"].isFalse: continue
    let source = valStr(item["sourceId"])
    let target = valStr(item["targetId"])
    if source in isBlock and target in isBlock:
      let outputName = namedPort(g.byId.getOrDefault(source, nil), item["sourceAnchor"])
      let inputName = namedPort(g.byId.getOrDefault(target, nil), item["targetAnchor"])
      if outputName.len > 0 and inputName.len > 0:
        if not namedPortIsFlow(g.byId[source], item["sourceAnchor"]) and
            not namedPortIsFlow(g.byId[target], item["targetAnchor"]):
          dataInputs.mgetOrPut(target, @[]).add (inputName, source, outputName)
        # Visible socket connections also carry execution downstream.
        # Otherwise a Start -> code -> Output chain stops at the code block.
        var linked = false
        for (_, existing) in outs.getOrDefault(source, @[]):
          if existing == target: linked = true
        if not linked: outs.mgetOrPut(source, @[]).add (edgeLabel(item), target)
        incoming.incl target
      else:
        outs.mgetOrPut(source, @[]).add (edgeLabel(item), target)
        incoming.incl target

  proc byPosition(list: seq[Val]): seq[Val] =
    result = list
    result.sort(proc(a, b: Val): int =
      let dy = cmp(nodeY(a), nodeY(b))
      if dy != 0: dy else: cmp(nodeX(a), nodeX(b)))

  var entries: seq[string]
  for id in entryIds:
    if id in isBlock: entries.add id
  if entries.len == 0:
    var starts, roots: seq[Val]
    for item in blocks:
      if item.eqs("vsType", "start"): starts.add item
      elif idOf(item) notin incoming: roots.add item
    for item in byPosition(if starts.len > 0: starts else: roots): entries.add idOf(item)
  if entries.len == 0:
    result.error = "Every block has an incoming connector, so there is nowhere to begin. Add a Start block."
    return

  var lines = @["--!nonstrict",
    "-- Generated by QGraph from the diagram's script blocks.",
    "local __nodes = {}",
    "local __loops = {}",
    "local __ports = {}",
    "local __qnoteProgram = \"\"",
    "local __qnoteTarget = \"\""]
  for item in blocks:
    let first = lines.len + 1
    lines.add "__nodes[" & luaQuote(idOf(item)) & "] = function() -- " &
      plainText(item).replace("\n", " ")
    lines.add "\tlocal __input = {}"
    for (inputName, sourceId, outputName) in dataInputs.getOrDefault(idOf(item), @[]):
      lines.add "\t__input[" & luaQuote(inputName) & "] = __ports[" & luaQuote(sourceId) &
        "] and __ports[" & luaQuote(sourceId) & "][" & luaQuote(outputName) & "]"
    let error = blockBody(item, outs.getOrDefault(idOf(item), @[]), lines)
    if error.len > 0:
      result.error = error
      result.errorId = idOf(item)
      return
    lines.add "end"
    result.spans.add (first, lines.len, idOf(item))
  lines.add "local function __run(entry: string)"
  lines.add "\tlocal stack = { entry }"
  lines.add "\twhile #stack > 0 do"
  lines.add "\t\tlocal id = table.remove(stack)"
  lines.add "\t\t__steps += 1"
  lines.add "\t\tif __steps > " & $scriptStepLimit & " then"
  lines.add "\t\t\t__fail(id, \"stopped after " & $scriptStepLimit &
    " steps without a Wait: is a loop missing its way out?\")"
  lines.add "\t\tend"
  lines.add "\t\tblock = id"
  lines.add "\t\tlocal ok, nexts = pcall(__nodes[id])"
  lines.add "\t\tif not ok then __fail(id, nexts) end"
  lines.add "\t\tif type(nexts) == \"table\" then"
  lines.add "\t\t\tfor i = #nexts, 1, -1 do table.insert(stack, nexts[i]) end"
  lines.add "\t\tend"
  lines.add "\tend"
  lines.add "end"
  var quoted: seq[string]
  for id in entries: quoted.add luaQuote(id)
  lines.add "for _, entry in { " & quoted.join(", ") & " } do"
  lines.add "\t__run(entry)"
  lines.add "end"
  result.source = lines.join("\n") & "\n"

proc blockAtLine(p: ScriptProgram, line: int): string =
  for (first, last, id) in p.spans:
    if line >= first and line <= last: return id
  ""

proc stripChunkPrefix(message: string): (string, int) =
  ## `[string "script"]:12: boom` -> ("boom", 12); line 0 when absent.
  if not message.startsWith("[string \""): return (message, 0)
  let close = message.find("\"]:")
  if close < 0: return (message, 0)
  var i = close + 3
  var line = 0
  while i < message.len and message[i] in {'0'..'9'}:
    line = line * 10 + (ord(message[i]) - ord('0'))
    inc i
  if i < message.len and message[i] == ':': inc i
  while i < message.len and message[i] == ' ': inc i
  (message[i .. ^1], line)

# ----------------------------------------------------------------- console --

proc nowMs(): float64 = window.getNode("performance").invoke("now").toNum

proc clockText(): string =
  let date = construct("Date")
  result = date.invoke("toLocaleTimeString").toStr
  release(date)

proc log(ui: EditorUi, level, text: string) =
  let rt = ui.script
  if rt.consoleBody.isNil: return
  let line = div0("qg-log qg-log-" & level)
  let time = el("span", "qg-log-time")
  time.text = clockText()
  let message = el("span", "qg-log-text")
  message.text = text
  line.appendChild(time)
  line.appendChild(message)
  rt.consoleBody.appendChild(line)
  inc rt.lineCount
  if rt.lineCount > consoleLimit:
    let first = rt.consoleBody.getNode("firstElementChild")
    if not first.isNil: first.remove()
    dec rt.lineCount
  rt.consoleBody.setProp("scrollTop", 1e9)
  rt.consoleEmpty.hidden = true
  # Mirror into the browser's developer console.
  let consoleMethod = case level
    of "warn": "warn"
    of "error": "error"
    of "info", "system": "info"
    else: "log"
  window.getNode("console").call(consoleMethod, "[Luau] " & text)

proc clearConsole(ui: EditorUi) =
  let rt = ui.script
  if rt.consoleBody.isNil: return
  rt.consoleBody.dropChildren()
  rt.lineCount = 0
  rt.consoleEmpty.hidden = false

proc setScriptStatus(ui: EditorUi, text: string, state: string) =
  let rt = ui.script
  for node in [rt.status, rt.topStatus]:
    if node.isNil: continue
    node.text = text
    node.setData("state", state)
  for button in [rt.runButton, rt.topRun, rt.inspectorRun]:
    if not button.isNil: button.disabled = rt.running
  for button in [rt.stopButton]:
    if not button.isNil: button.disabled = not rt.running
  ui.container.toggleClass("is-script-running", rt.running)

# ------------------------------------------------------------------ worker --

proc handleWorkerMessage(ui: EditorUi, data: string)

proc workerUrl(): string =
  ## The worker carries the page's build stamp, like every other script.
  result = "js/luau-worker.js"
  let script = document.query("script[src*=\"qweb.js\"]")
  if script.isNil: return
  let src = script.getStr("src")
  let q = src.find('?')
  if q >= 0: result &= src[q .. ^1]

proc ensureWorker(ui: EditorUi) =
  let rt = ui.script
  if not rt.worker.isNil: return
  rt.workerReady = false
  let worker = construct("Worker", workerUrl(), jsJson("{\"type\":\"module\"}"))
  if worker.isNil:
    ui.log("error", "Could not start the Luau worker: " & lastError())
    return
  rt.worker = worker
  worker.on("message", proc(e: Event) =
    if same(worker, rt.worker): ui.handleWorkerMessage(e.data))
  worker.on("error", proc(e: Event) =
    if not same(worker, rt.worker): return
    e.preventDefault()
    ui.log("error", "The Luau runtime failed to load (js/luau-worker.js).")
    rt.worker.call("terminate")
    rt.worker = nilNode
    if rt.running:
      rt.running = false
      ui.setScriptStatus("Failed", "error"))

proc dropWorker(ui: EditorUi) =
  let rt = ui.script
  if rt.worker.isNil: return
  rt.worker.call("terminate")
  release(rt.worker)
  rt.worker = nilNode
  rt.workerReady = false

proc sendRun(ui: EditorUi) =
  let rt = ui.script
  let message = newObj()
  message["t"] = jstr("run")
  message["run"] = jnum(float64(rt.runId))
  let chunks = newArr()
  chunks.push obj(("name", jstr("prelude")), ("source", jstr(scriptPrelude)))
  chunks.push obj(("name", jstr("script")), ("source", jstr(rt.program.source)))
  message["chunks"] = chunks
  rt.worker.call("postMessage", toJson(message))
  rt.pendingRun = false

proc setBlockState(ui: EditorUi, id: string, output, error: string, onlyOutput = false) =
  let item = ui.graph.g.getItem(id)
  if not isScriptBlock(item): return
  let vs = if item["visualScript"].isObj: clone(item["visualScript"]) else: newObj()
  vs["lastResult"] = jstr(output)
  if not onlyOutput: vs["lastError"] = jstr(error)
  discard ui.graph.updateItem(id, o1("visualScript", vs))

proc clearBlockStates(ui: EditorUi) =
  for item in ui.graph.g.items:
    if isScriptBlock(item) and (blockField(item, "lastResult").len > 0 or
                                blockField(item, "lastError").len > 0):
      ui.setBlockState(idOf(item), "", "")

proc finishRun(ui: EditorUi, ok: bool, message: string) =
  let rt = ui.script
  if not rt.running: return
  rt.running = false
  let g = ui.graph.g
  let elapsed = jsRound(nowMs() - rt.startedAt)
  if not ok and not rt.stopped and message != blockFailed and rt.failedBlock.len == 0:
    let (text, line) = stripChunkPrefix(message)
    let id = if line > 0: rt.program.blockAtLine(line) else: ""
    if id.len > 0:
      rt.failedBlock = id
      ui.setBlockState(id, "", text)
      let item = g.getItem(id)
      ui.log("error", (if item != nil: plainText(item) & ": " else: "") & text)
    else:
      ui.log("error", text)
  g.commit(rt.before, "Run Script")
  if rt.failedBlock.len > 0 and g.getItem(rt.failedBlock) != nil:
    g.setSelection(@[rt.failedBlock])
  if rt.stopped:
    ui.setScriptStatus("Stopped", "idle")
  elif ok:
    ui.log("system", "Finished in " & jsStr(elapsed) & " ms")
    ui.setScriptStatus("Finished in " & jsStr(elapsed) & " ms", "ok")
  else:
    ui.setScriptStatus("Failed", "error")
  ui.refreshScriptInspector()
  # One program per worker; keep the next one warm.
  ui.dropWorker()
  ui.ensureWorker()

proc runScript*(ui: EditorUi, entryIds: seq[string] = @[]) =
  let rt = ui.script
  if rt.running: return
  ui.graph.finishTextEdit()
  let program = ui.compileScript(entryIds)
  if program.error.len > 0:
    if program.errorId.len > 0:
      let before = ui.graph.snapshot()
      ui.setBlockState(program.errorId, "", program.error)
      ui.graph.commit(before, "Run Script")
      ui.graph.g.setSelection(@[program.errorId])
      let item = ui.graph.g.getItem(program.errorId)
      ui.log("error", (if item != nil: plainText(item) & ": " else: "") & program.error)
    else:
      ui.log("error", program.error)
    ui.setScriptStatus("Can't run", "error")
    ui.openPanel("script")
    return
  inc rt.runId
  rt.program = program
  rt.running = true
  rt.stopped = false
  rt.failedBlock = ""
  rt.addCount = 0
  rt.startedAt = nowMs()
  rt.before = ui.graph.snapshot()
  ui.clearBlockStates()
  ui.log("system", "Run started")
  ui.setScriptStatus("Running…", "running")
  ui.ensureWorker()
  if rt.worker.isNil:
    ui.finishRun(false, "The Luau runtime is not available")
    return
  if rt.workerReady: ui.sendRun()
  else:
    rt.pendingRun = true
    ui.setScriptStatus("Starting Luau…", "running")

proc stopScript*(ui: EditorUi) =
  let rt = ui.script
  if not rt.running: return
  rt.stopped = true
  ui.dropWorker()
  ui.log("warn", "Stopped")
  ui.finishRun(false, "Stopped")

# --------------------------------------------------------- document ops --

proc summary(item: Val): Val =
  ## What a Luau program sees of an item: a plain table.
  result = newObj()
  result["id"] = jstr(idOf(item))
  result["type"] = jstr(valStr(item["type"]))
  if item.eqs("type", "edge"):
    result["source"] = item["sourceId"].nilToNull
    result["target"] = item["targetId"].nilToNull
    result["text"] = jstr(plainText(item))
    for key in ["stroke", "strokeWidth", "lineStyle"]:
      if not nullish(item.get(key)): result.put(key, item.get(key))
    return
  result["text"] = jstr(plainText(item))
  for key in ["x", "y", "width", "height", "rotation"]: result.put(key, jnum(num(item.get(key))))
  for key in ["shape", "fill", "stroke", "strokeWidth", "textColor", "fontSize", "opacity",
              "kind", "vsType"]:
    if not nullish(item.get(key)): result.put(key, item.get(key))

proc findNodes(ui: EditorUi, text: string, all: bool): seq[Val] =
  let g = ui.graph.g
  let direct = g.getItem(text)
  if direct != nil and not isScriptBlock(direct):
    result.add direct
    if not all: return
  let needle = jsTrim(text).toLowerAscii()
  var partial: seq[Val]
  for item in g.items:
    if item.eqs("type", "edge") or isScriptBlock(item) or item["visible"].isFalse: continue
    if direct != nil and item == direct: continue
    let label = plainText(item).toLowerAscii()
    if label == needle:
      result.add item
      if not all: return
    elif needle.len > 0 and label.contains(needle): partial.add item
  if all or result.len == 0:
    for item in partial:
      result.add item
      if not all: return

proc opArgs(args: Val, key: string): string = (if args.isObj: valStr(args.get(key)) else: "")

proc cleanProps(props: Val): Val =
  result = newObj()
  if not props.isObj: return
  for (key, value) in props.pairs:
    if key in ["id", "type", "kind", "visualScript", "vsType"]: continue
    result.put(key, value)
  if result.hasKey("text"):
    result["text"] = jstr(valStr(result["text"]))
    if not result.hasKey("richText"): result["richText"] = jnull

proc scriptOp(ui: EditorUi, op: string, args: Val): Val =
  ## Carries out one document operation for the running program. Returns the
  ## value to hand back; raises ValueError for a message the program sees.
  let gv = ui.graph
  let g = gv.g
  proc need(id: string): Val =
    result = g.getItem(id)
    if result == nil: raise newException(ValueError, "there is no item with id “" & id & "”")
  case op
  of "nodes":
    result = newArr()
    for item in g.items:
      if not item.eqs("type", "edge") and not isScriptBlock(item) and not item["visible"].isFalse:
        result.push summary(item)
  of "edges":
    result = newArr()
    for item in g.items:
      if item.eqs("type", "edge") and not item["visible"].isFalse:
        let source = g.getItem(valStr(item["sourceId"]))
        if isScriptBlock(source): continue
        result.push summary(item)
  of "get":
    result = summary(need(opArgs(args, "id")))
  of "find":
    let found = ui.findNodes(opArgs(args, "text"), false)
    result = if found.len > 0: summary(found[0]) else: jnull
  of "findAll":
    result = newArr()
    for item in ui.findNodes(opArgs(args, "text"), true): result.push summary(item)
  of "selection":
    result = newArr()
    for item in g.getSelection(): result.push summary(item)
  of "neighbors":
    let id = idOf(need(opArgs(args, "id")))
    let direction = opArgs(args, "direction")
    result = newArr()
    for item in g.items:
      if not item.eqs("type", "edge"): continue
      let source = valStr(item["sourceId"])
      let target = valStr(item["targetId"])
      var other = ""
      if source == id and direction in ["out", "both"]: other = target
      elif target == id and direction in ["in", "both"]: other = source
      let node = if other.len > 0: g.getItem(other) else: nil
      if node != nil and not isScriptBlock(node): result.push summary(node)
  of "set":
    let item = need(opArgs(args, "id"))
    if isScriptBlock(item): raise newException(ValueError, "script blocks can't be changed by a script")
    discard gv.updateItem(idOf(item), cleanProps(args["props"]))
    result = summary(item)
  of "add":
    let props = cleanProps(args["props"])
    if not props.hasKey("text"): props["text"] = jstr("")
    if not props.hasKey("x") or not props.hasKey("y"):
      let view = g.getViewState()
      let width = if props.hasKey("width"): num(props["width"]) else: 160.0
      let height = if props.hasKey("height"): num(props["height"]) else: 80.0
      let offset = float64(ui.script.addCount mod 12) * 24
      inc ui.script.addCount
      if not props.hasKey("x"):
        props["x"] = jnum(jsRound((num(view["scrollX"]) + num(view["width"]) / 2) / g.zoom - width / 2 + offset))
      if not props.hasKey("y"):
        props["y"] = jnum(jsRound((num(view["scrollY"]) + num(view["height"]) / 2) / g.zoom - height / 2 + offset))
    result = summary(g.addNode(props, select = false))
  of "connect":
    let source = idOf(need(opArgs(args, "source")))
    let target = idOf(need(opArgs(args, "target")))
    let props = cleanProps(args["props"])
    props["sourceId"] = jstr(source)
    props["targetId"] = jstr(target)
    result = summary(g.addEdge(props, select = false))
  of "remove":
    var ids: seq[string]
    if args.isObj and args["ids"].isArr:
      for v in args["ids"]:
        let id = valStr(v)
        if not isScriptBlock(g.getItem(id)): ids.add id
    result = jnum(float64(g.removeItems(ids).len))
  of "select":
    var ids: seq[string]
    if args.isObj and args["ids"].isArr:
      for v in args["ids"]: ids.add valStr(v)
    g.setSelection(ids)
    result = jnum(float64(g.getSelection().len))
  of "fit":
    g.fit()
    result = jnull
  of "output":
    let id = opArgs(args, "id")
    let text = opArgs(args, "text")
    if isScriptBlock(g.getItem(id)): ui.setBlockState(id, text, "", onlyOutput = true)
    else: ui.log("print", text)
    result = jnull
  of "fail":
    let id = opArgs(args, "id")
    let (text, _) = stripChunkPrefix(opArgs(args, "error"))
    ui.script.failedBlock = id
    ui.setBlockState(id, "", text)
    let item = g.getItem(id)
    ui.log("error", (if item != nil: plainText(item) & ": " else: "") & text)
    result = jnull
  of "alert":
    discard window.invoke("alert", opArgs(args, "text"))
    result = jnull
  of "confirm":
    result = jbool(window.invoke("confirm", opArgs(args, "text")).toBool)
  of "prompt":
    let (ok, value) = prompt(opArgs(args, "text"), opArgs(args, "default"))
    result = if ok: jstr(value) else: jnull
  of "toast":
    ui.toast(opArgs(args, "text"))
    result = jnull
  else:
    raise newException(ValueError, "unknown editor operation “" & op & "”")

proc handleWorkerMessage(ui: EditorUi, data: string) =
  let rt = ui.script
  var message: Val
  try: message = parseJson(data)
  except JsonError: return
  let kind = valStr(message["t"])
  case kind
  of "ready":
    rt.workerReady = true
    rt.engine = valStr(message["engine"])
    if rt.pendingRun and rt.running:
      ui.setScriptStatus("Running…", "running")
      ui.sendRun()
  of "fail":
    ui.log("error", "The Luau runtime could not start: " & valStr(message["error"]))
    ui.dropWorker()
    if rt.running:
      rt.running = false
      ui.setScriptStatus("Failed", "error")
  of "log":
    if int(num(message["run"])) != rt.runId: return
    ui.log(valStr(message["level"]), valStr(message["text"]))
  of "req":
    if int(num(message["run"])) != rt.runId or not rt.running: return
    let runId = int(num(message["run"]))
    let reqId = message["id"]
    let op = valStr(message["op"])
    var args: Val = jnull
    try: args = parseJson(valStr(message["args"]))
    except JsonError: discard
    proc post(reply: Val) =
      if rt.runId == runId and not rt.worker.isNil:
        let answer = newObj()
        answer["t"] = jstr("reply")
        answer["id"] = reqId
        answer["json"] = jstr(toJson(reply))
        rt.worker.call("postMessage", toJson(answer))
    if op == "qnote.run":
      if window.getStr("QOQORO_WORKSPACE_BRIDGE") == "true":
        let parent = window.getNode("parent")
        let requestKey = "qnote-" & $runId & "-" & str(reqId)
        var listener, timer: int32
        var completed = false
        proc complete(result: Val, error = "") =
          if completed: return
          completed = true
          off(listener)
          clearTimeout(timer)
          release(parent)
          let reply = newObj()
          if error.len > 0 or not result["ok"].isTrue:
            reply["ok"] = jfalse
            reply["error"] = jstr(if error.len > 0: error else: result.so("error", "QNote did not apply the program"))
          else:
            reply["ok"] = jtrue
            reply["value"] = result
          post(reply)
        listener = window.on("message", proc(e: Event) =
          if not same(e.source, parent): return
          var response: Val
          try: response = parseJson(e.data)
          except JsonError: return
          if response.eqs("type", "QOCHART_QNOTE_RESULT") and response.eqs("id", requestKey):
            complete(response["result"], response.so("error", "")))
        timer = setTimeout(120000, proc() = complete(nil, "The open QNote editor did not respond"))
        let request = clone(args)
        request["type"] = jstr("QOCHART_RUN_QNOTE")
        request["id"] = jstr(requestKey)
        parent.call("postMessage", toJson(request), "*")
        return
      # Reaches outside this app's own sandbox for the first time: a same-
      # origin POST to the vault's automation queue, which blocks server-side
      # until some signed-in QOQORO window (this tab's own poll loop, another
      # tab, or the desktop app) claims and runs it, then returns the result
      # directly -- one HTTP round trip, no separate polling here.
      let target = valStr(args["target"])
      let body = newObj()
      body["path"] = jstr(target)
      body["source"] = jstr(valStr(args["program"]))
      body["apply"] = jbool(not args["apply"].isFalse)
      body["save"] = jbool(not args["save"].isFalse)
      if args["timeoutMs"].isNum: body["timeoutMs"] = args["timeoutMs"]
      fetchPostJson("/api/program", toJson(body), proc(ok: bool, data: string) =
        var reply = newObj()
        if not ok:
          reply["ok"] = jfalse
          reply["error"] = jstr(data)
        else:
          try:
            let outcome = parseJson(data)
            # A completed job's outcome always carries its own "ok" (true or
            # false, e.g. a failing automation script) -- that shape is a
            # successful host reply, letting the Luau flow inspect it itself.
            # No "ok" key at all means the request never became a job (no
            # window claimed it, bad auth, ...): a host-level failure.
            if not outcome["ok"].isTrue:
              reply["ok"] = jfalse
              reply["error"] = if outcome["error"].isStr: outcome["error"]
                                else: jstr("qnote.run: the server did not run the program")
            else:
              reply["ok"] = jtrue
              reply["value"] = outcome
          except JsonError:
            reply["ok"] = jfalse
            reply["error"] = jstr("qnote.run: bad response from the server")
        post(reply))
      return
    var reply = newObj()
    try:
      reply["ok"] = jtrue
      reply["value"] = ui.scriptOp(op, args)
    except ValueError as e:
      reply = newObj()
      reply["ok"] = jfalse
      reply["error"] = jstr(e.msg)
    post(reply)
  of "done":
    if int(num(message["run"])) != rt.runId: return
    ui.finishRun(message["ok"].isTrue, valStr(message["error"]))
  else: discard

# ------------------------------------------------------ connector labels --

proc labelScriptEdges(ui: EditorUi) =
  ## New connectors leaving an If or a loop get the branch they stand for:
  ## the first one true / loop, the next false / done.
  let g = ui.graph.g
  var seen = initTable[string, (bool, bool)]()  # has primary, has secondary
  var pending: seq[Val]
  for item in g.items:
    if not item.eqs("type", "edge"): continue
    let source = g.getItem(valStr(item["sourceId"]))
    if source == nil or not isScriptBlock(source): continue
    let vsType = valStr(source["vsType"])
    if vsType notin ["condition", "for", "while"]: continue
    let secondary = if vsType == "condition": @falseLabels else: @doneLabels
    let label = edgeLabel(item)
    var state = seen.getOrDefault(idOf(source), (false, false))
    if label.len == 0: pending.add item
    elif label in secondary: state[1] = true
    else: state[0] = true
    seen[idOf(source)] = state
  for edge in pending:
    let source = g.getItem(valStr(edge["sourceId"]))
    let vsType = valStr(source["vsType"])
    var state = seen.getOrDefault(idOf(source), (false, false))
    var label = ""
    if not state[0]:
      label = if vsType == "condition": "true" else: "loop"
      state[0] = true
    elif not state[1]:
      label = if vsType == "condition": "false" else: "done"
      state[1] = true
    seen[idOf(source)] = state
    if label.len > 0:
      discard ui.graph.updateItem(idOf(edge), o1("text", jstr(label)))

# ---------------------------------------------------------------- examples --

proc insertScriptExample(ui: EditorUi) =
  ## A beginner-friendly program using the value builder.
  let gv = ui.graph
  let g = gv.g
  let view = g.getViewState()
  let ox = jsRound((num(view["scrollX"]) + num(view["width"]) / 2) / g.zoom - 390)
  let oy = jsRound((num(view["scrollY"]) + num(view["height"]) / 2) / g.zoom - 170)
  let before = gv.snapshot()
  proc place(vsType: string, x, y: float64, fields: openArray[(string, string)] = [],
             title = ""): string =
    let (_, d) = findBlockDef(vsType)
    let t = scriptTemplate(d)
    t["x"] = jnum(ox + x)
    t["y"] = jnum(oy + y)
    if title.len > 0: t["text"] = jstr(title)
    for (k, v) in fields: t["visualScript"].put(k, jstr(v))
    idOf(g.addNode(t, select = false))
  proc link(a, b: string, label = "") =
    var sourceAnchor, targetAnchor: Val
    for port in variablePorts(g.byId[a]):
      if port.direction == "output":
        sourceAnchor = clone(port.anchor)
        break
    for port in variablePorts(g.byId[b]):
      if port.direction == "input":
        targetAnchor = clone(port.anchor)
        break
    discard g.addEdge(obj(("sourceId", jstr(a)), ("targetId", jstr(b)), ("text", jstr(label)),
                          ("sourceAnchor", sourceAnchor), ("targetAnchor", targetAnchor),
                          ("lineStyle", jstr("curved"))), select = false)
  let start = place("start", 0, 40)
  let countMeta = """{"mode":"builder","operation":"+","expression":"(4)","parts":[{"kind":"number","value":"4"}]}"""
  let outputExpr = "(tostring(\"This is \") .. tostring(count))"
  let outputMeta = """{"mode":"builder","operation":"text","expression":"(tostring(\"This is \") .. tostring(count))","parts":[{"kind":"text","value":"This is "},{"kind":"variable","value":"count"}]}"""
  let count = place("set", 0, 190, [("name", "count"), ("value", "(4)"),
    ("__builder_value", countMeta)], "Count")
  let show = place("output", 330, 190, [("value", outputExpr), ("mode", "block"),
    ("__builder_value", outputMeta)], "Built output")
  link(start, count)
  link(count, show)
  var ids = @[start, count, show]
  g.setSelection(ids)
  gv.commit(before, "Insert Script Example")
  ui.labelScriptEdges()
  # A phone screen is narrower than the example; show all of it.
  if ui.layout == lmPhone: ui.run("fit")

proc insertQNoteExample(ui: EditorUi) =
  ## A small example that adds a heading and a paragraph to the QNote
  ## document open in this workspace right now.
  let gv = ui.graph
  let g = gv.g
  let view = g.getViewState()
  let ox = jsRound((num(view["scrollX"]) + num(view["width"]) / 2) / g.zoom - 390)
  let oy = jsRound((num(view["scrollY"]) + num(view["height"]) / 2) / g.zoom - 170)
  let before = gv.snapshot()
  proc place(vsType: string, x, y: float64, fields: openArray[(string, string)] = [],
             title = ""): string =
    let (_, d) = findBlockDef(vsType)
    let t = scriptTemplate(d)
    t["x"] = jnum(ox + x)
    t["y"] = jnum(oy + y)
    if title.len > 0: t["text"] = jstr(title)
    for (k, v) in fields: t["visualScript"].put(k, jstr(v))
    idOf(g.addNode(t, select = false))
  proc link(a, b: string, label = "") =
    discard g.addEdge(obj(("sourceId", jstr(a)), ("targetId", jstr(b)), ("text", jstr(label)),
                          ("sourceAnchor", clone(variablePorts(g.byId[a])[^1].anchor)),
                          ("targetAnchor", clone(variablePorts(g.byId[b])[0].anchor)),
                          ("lineStyle", jstr("curved"))), select = false)
  let start = place("start", 0, 40)
  let open = place("qnoteOpen", 0, 190, [("path", "\"\"")], "The open note")
  let heading = place("qnoteType", 300, 130,
    [("text", "\"Hello from QGraph!\""), ("kind", "h1")])
  let para = place("qnoteType", 300, 280,
    [("text", "\"This paragraph was written by a QGraph script.\""), ("kind", "text")])
  let run = place("qnoteRun", 600, 200, [("save", "true"), ("timeoutMs", "60000")], "Send it")
  link(start, open)
  link(open, heading)
  link(heading, para)
  link(para, run)
  var ids = @[start, open, heading, para, run]
  g.setSelection(ids)
  gv.commit(before, "Insert QNote Example")
  ui.labelScriptEdges()
  if ui.layout == lmPhone: ui.run("fit")

# ------------------------------------------------------------------ plugins --
#
# Third-party blocks, described in XML, loaded at runtime with no recompile
# (ComfyUI/Obsidian-style). Deliberately declarative-only, by design, not an
# oversight: a plugin's <node> cannot supply Luau of its own -- it can only
# attach its own fields/ports around one of the five fixed operations wired
# into blockBody's generic dispatch above (each a factored-out call into the
# exact same codegen a built-in block already uses). A downloaded plugin ZIP
# therefore cannot do anything the fixed operation set doesn't already do.
#
#   <qgraphPlugin id="com.example.pack" name="My Pack" version="1.0.0">
#     <node type="myplugin.insertQuote" label="Insert Quote" color="#8b5cf6"
#           icon="message" width="220" height="92" description="...">
#       <field key="text" label="Quote text" kind="expr" default="&quot;Wisdom.&quot;"/>
#       <port name="text" type="string" direction="input"/>
#       <operation ref="qnote.insertText">
#         <param name="kind" value="text"/>
#         <param name="text" field="text"/>
#       </operation>
#     </node>
#   </qgraphPlugin>

proc parsePluginXml(text: string): seq[(ScriptBlockDef, PluginOperation, seq[PluginFieldDef])] =
  let root = parseXml(text)
  if root == nil or root.localName != "qgraphPlugin": return
  for nodeEl in root.elements:
    if nodeEl.localName != "node": continue
    let vsType = nodeEl.attr("type")
    # Namespaced ("pack.block") so a plugin can never shadow a built-in
    # block type, and never registered twice.
    if vsType.len == 0 or '.' notin vsType or findBlockDef(vsType)[0]: continue
    var fields: seq[PluginFieldDef]
    var fieldDefaults: seq[(string, string)]
    var inputPorts, outputPorts: seq[(string, string)]
    var operation: PluginOperation
    var hasOperation = false
    for child in nodeEl.elements:
      case child.localName
      of "field":
        let key = child.attr("key")
        if key.len == 0: continue
        let fkind = if child.attr("kind") == "expr": pfkExpr else: pfkText
        let default = child.attrOr("default", "")
        fields.add PluginFieldDef(key: key, label: child.attrOr("label", key), default: default, kind: fkind)
        fieldDefaults.add (key, default)
      of "port":
        let pname = child.attr("name")
        if pname.len == 0: continue
        let ptype = child.attrOr("type", "any")
        if child.attr("direction") == "output": outputPorts.add (pname, ptype)
        else: inputPorts.add (pname, ptype)
      of "operation":
        let opRef = child.attr("ref")
        if opRef.len == 0: continue
        var params: seq[PluginParam]
        for p in child.elements:
          if p.localName != "param": continue
          let pname = p.attr("name")
          if pname.len == 0: continue
          if p.hasAttr("field"):
            params.add PluginParam(name: pname, kind: ppkField, text: p.attr("field"))
          else:
            params.add PluginParam(name: pname, kind: ppkLiteral, text: p.attrOr("value", ""))
        operation = PluginOperation(opRef: opRef, params: params)
        hasOperation = true
      else: discard
    if not hasOperation: continue  # declarative-only: no fixed op, no block
    # The colour lands in a style attribute and the block's stroke, so only
    # a plain #rgb/#rrggbb is accepted; sizes are clamped to sane bounds.
    var color = nodeEl.attrOr("color", "#8b5cf6")
    if not (color.len in [4, 7] and color[0] == '#' and color[1 .. ^1].allCharsInSet(HexDigits)):
      color = "#8b5cf6"
    proc dim(name, fallback: string): float64 =
      let v = jsNumber(nodeEl.attrOr(name, fallback))
      if v != v: jsNumber(fallback) else: clamp(v, 40.0, 1000.0)
    let def = blockDef(vsType, nodeEl.attrOr("label", vsType), nodeEl.attrOr("description", ""),
      color, nodeEl.attrOr("icon", "script"), dim("width", "220"), dim("height", "92"),
      fieldDefaults, inputPorts, outputPorts)
    result.add (def, operation, fields)

proc loadPlugins(ui: EditorUi) =
  ## GET /api/plugins -> [{id, name, version, ...}, ...], then one manifest
  ## fetch per plugin. Silent on any failure -- no route yet (no plugin
  ## server behind this page), a network error, bad XML: a plugin-less
  ## QGraph must look and behave exactly as it does today, never a startup
  ## error for something optional and possibly not even installed.
  fetchBytes("/api/plugins?app=qochart", proc(ok: bool, data: string) =
    if not ok: return
    var list: Val
    try: list = parseJson(data)
    except JsonError: return
    if not list.isArr or list.len == 0: return
    var remaining = list.len
    var added = 0
    proc checkDone() =
      if remaining == 0 and added > 0: ui.refreshScriptBlockPalette()
    for entry in list:
      let id = valStr(entry["id"])
      if id.len == 0:
        dec remaining
        continue
      fetchBytes("/api/plugins/" & id & "/manifest.xml", proc(ok2: bool, xmlText: string) =
        if ok2:
          try:
            for (def, operation, fields) in parsePluginXml(xmlText):
              scriptBlockDefs.add def
              pluginOperations[def.vsType] = operation
              pluginFields[def.vsType] = fields
              inc added
          except CatchableError: discard
        dec remaining
        checkDone())
    checkDone())
