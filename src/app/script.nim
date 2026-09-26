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

proc blockDef(vsType, label, description, color, iconName: string, width, height: float64,
              fields: openArray[(string, string)] = []): ScriptBlockDef =
  ScriptBlockDef(vsType: vsType, label: label, description: description, color: color,
                 iconName: iconName, width: width, height: height, fields: @fields)

let scriptBlockDefs = @[
  blockDef("start", "Start", "Where the program begins", "#10b981", "flag", 180, 64),
  blockDef("output", "Output", "Show a value on the block, in the console or as an alert",
    "#22c55e", "message", 220, 118, [("value", "\"Hello, world!\""), ("mode", "block")]),
  blockDef("luau", "Luau code", "Any Luau: variables, loops, functions, doc.*", "#6366f1",
    "script", 260, 150, [("code", "-- Globals are shared by every block\n" &
      "count = (count or 0) + 1\nprint(\"count is\", count)")]),
  blockDef("set", "Set variable", "Store a value for later blocks", "#0ea5e9", "variable", 210, 76,
    [("name", "count"), ("value", "0")]),
  blockDef("condition", "If", "Follow the true or the false connector", "#f59e0b", "branch",
    210, 92, [("test", "count > 3")]),
  blockDef("for", "Repeat", "Count through a range of numbers", "#f97316", "loop", 210, 92,
    [("iterator", "i"), ("from", "1"), ("to", "3"), ("step", "1")]),
  blockDef("while", "While", "Loop while a condition holds", "#a855f7", "loop", 210, 92,
    [("condition", "count < 10"), ("max", "100")]),
  blockDef("ask", "Ask", "Ask the user to type a value", "#3b82f6", "ask", 230, 76,
    [("name", "answer"), ("message", "\"What is your name?\""), ("default", "\"\"")]),
  blockDef("delay", "Wait", "Pause for a number of seconds", "#eab308", "clock", 180, 76,
    [("seconds", "1")]),
  blockDef("shape", "Set shape", "Change a shape on the canvas", "#ec4899", "wand", 230, 92,
    [("target", "Process"), ("property", "fill"), ("value", "\"#fde68a\"")]),
]

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
  if text.len == 0: fallback else: "(" & text & ")"

proc blockBody(item: Val, outs: seq[(string, string)], body: var seq[string]): string =
  ## Appends the Luau for one block; returns an error message or "".
  let id = idOf(item)
  let label = plainText(item)
  var targets: seq[string]
  for (_, t) in outs: targets.add t
  let next = "\treturn " & nextList(targets)
  let vsType = if item["vsType"].isStr: item["vsType"].s else: ""
  case vsType
  of "start":
    body.add next
  of "luau", "process", "function":
    let code = blockField(item, "code")
    if jsTrim(code).len > 0:
      body.add "\tlocal __result = (function()"
      for line in code.split('\n'): body.add line
      body.add "\tend)()"
      body.add "\tif __result ~= nil then result = __result end"
    body.add next
  of "set":
    let name = jsTrim(blockField(item, "name"))
    if not isLuauName(name, dotted = true):
      return "“" & name & "” is not a variable name (letters, digits and _, not starting with a digit)"
    body.add "\t" & name & " = " & expr(item, "value", "nil")
    body.add next
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
    body.add next
  of "ask":
    let name = jsTrim(blockField(item, "name"))
    if not isLuauName(name, dotted = true):
      return "“" & name & "” is not a variable name"
    body.add "\t" & name & " = prompt(" & expr(item, "message", "\"\"") & ", " &
      expr(item, "default", "nil") & ")"
    body.add next
  of "delay":
    body.add "\twait(" & expr(item, "seconds", "1") & ")"
    body.add next
  of "shape":
    let target = jsTrim(blockField(item, "target"))
    let prop = jsTrim(blockField(item, "property"))
    if target.len == 0: return "Name the shape to change (its label or id)"
    if not isLuauName(prop): return "“" & prop & "” is not a shape property"
    body.add "\tlocal target = doc.find(" & luaQuote(target) & ")"
    body.add "\tif target == nil then error(" & luaQuote("there is no shape labelled “" & target & "”") & ", 0) end"
    body.add "\tdoc.set(target.id, { " & prop & " = " & expr(item, "value", "nil") & " })"
    body.add next
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
    body.add next
  else:
    body.add "\twarn(" & luaQuote((if label.len > 0: label else: vsType) &
      ": this kind of block does not run here, so it was skipped") & ")"
    body.add next
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
  var incoming = initHashSet[string]()
  for item in g.items:
    if not item.eqs("type", "edge") or item["visible"].isFalse: continue
    let source = valStr(item["sourceId"])
    let target = valStr(item["targetId"])
    if source in isBlock and target in isBlock:
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
    "local __loops = {}"]
  for item in blocks:
    let first = lines.len + 1
    lines.add "__nodes[" & luaQuote(idOf(item)) & "] = function() -- " &
      plainText(item).replace("\n", " ")
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
    var reply = newObj()
    try:
      var args: Val = jnull
      try: args = parseJson(valStr(message["args"]))
      except JsonError: discard
      reply["ok"] = jtrue
      reply["value"] = ui.scriptOp(valStr(message["op"]), args)
    except ValueError as e:
      reply = newObj()
      reply["ok"] = jfalse
      reply["error"] = jstr(e.msg)
    let answer = newObj()
    answer["t"] = jstr("reply")
    answer["id"] = message["id"]
    answer["json"] = jstr(toJson(reply))
    if not rt.worker.isNil: rt.worker.call("postMessage", toJson(answer))
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
  ## A small program that shows every way to produce output.
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
                          ("lineStyle", jstr("orthogonal"))), select = false)
  let start = place("start", 0, 40)
  let ask = place("ask", 240, 34, [("name", "name"), ("message", "\"What is your name?\""),
                                   ("default", "\"Luau\"")])
  let greet = place("output", 520, 0, [("value", "\"Hello, \" .. (name or \"stranger\") .. \"!\""),
                                       ("mode", "block")], "Greeting")
  let code = place("luau", 240, 170, [("code", "-- Luau can read and change the diagram\n" &
    "local shapes = doc.nodes()\nprint(\"shapes on the canvas:\", #shapes)\n" &
    "total = 0\nfor i = 1, 10 do total += i end")], "Count")
  let show = place("output", 540, 180, [("value", "\"1 + … + 10 = \" .. total"), ("mode", "console")],
                   "Log it")
  link(start, ask)
  link(ask, greet)
  link(start, code)
  link(code, show)
  var ids = @[start, ask, greet, code, show]
  g.setSelection(ids)
  gv.commit(before, "Insert Script Example")
  ui.labelScriptEdges()
  # A phone screen is narrower than the example; show all of it.
  if ui.layout == lmPhone: ui.run("fit")
