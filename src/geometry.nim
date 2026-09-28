## Scene geometry: connector routing, circular arcs, table grids and item
## bounds. A direct port of PixelGeometry from the JavaScript editor, working
## on the dynamic item objects of the retained scene.

import std/[math, tables, strutils]
import jsval

type
  Pt* = object
    x*, y*: float64
  Rect* = object
    x*, y*, width*, height*: float64
  Scene* = Table[string, Val]
    ## id -> item, the painter's `items` Map and the graph's `byId`.
  VariablePort* = object
    name*, dataType*, direction*, side*: string
    index*: int
    anchor*: Val
    point*: Pt

proc pt*(x, y: float64): Pt {.inline.} = Pt(x: x, y: y)
proc rect*(x, y, w, h: float64): Rect {.inline.} = Rect(x: x, y: y, width: w, height: h)

proc jsMax*(a, b: float64): float64 {.inline.} =
  ## Math.max: NaN-propagating.
  if a != a or b != b: NaN else: max(a, b)

proc jsMin*(a, b: float64): float64 {.inline.} =
  ## Math.min: NaN-propagating.
  if a != a or b != b: NaN else: min(a, b)

proc clamp*(value, lo, hi: float64): float64 {.inline.} =
  ## Math.max(lo, Math.min(hi, value)), NaN-propagating like JS.
  jsMax(lo, jsMin(hi, value))

proc jsMin*(a, b, c: float64): float64 {.inline.} = jsMin(jsMin(a, b), c)
proc jsMax*(a, b, c: float64): float64 {.inline.} = jsMax(jsMax(a, b), c)

proc jsRound*(x: float64): float64 {.inline.} =
  ## Math.round: halves round towards +Infinity.
  floor(x + 0.5)

proc isFiniteNum*(x: float64): bool {.inline.} = x == x and x != Inf and x != -Inf

proc toPt*(v: Val): Pt = Pt(x: num(v["x"]), y: num(v["y"]))
proc ptVal*(p: Pt): Val =
  result = newObj()
  result["x"] = jnum(p.x)
  result["y"] = jnum(p.y)

proc ptsVal*(ps: openArray[Pt]): Val =
  result = newArr()
  for p in ps: result.a.add ptVal(p)

proc valPts*(v: Val): seq[Pt] =
  for x in v:
    if x != nil and x.kind == vObj: result.add toPt(x)

proc rectVal*(r: Rect): Val =
  result = newObj()
  result["x"] = jnum(r.x)
  result["y"] = jnum(r.y)
  result["width"] = jnum(r.width)
  result["height"] = jnum(r.height)

proc lookup*(scene: Scene, id: Val): Val {.inline.} =
  ## scene[id] with JavaScript's key coercion (null -> "null").
  if id == nil: return nil
  let key = if id.kind == vStr: id.s else: str(id)
  scene.getOrDefault(key, nil)

proc boundsOfPoints*(points: openArray[Pt], padding = 0.0): Rect =
  if points.len == 0: return rect(0, 0, 0, 0)
  var minX = points[0].x
  var minY = points[0].y
  var maxX = minX
  var maxY = minY
  for i in 1 ..< points.len:
    minX = jsMin(minX, points[i].x)
    minY = jsMin(minY, points[i].y)
    maxX = jsMax(maxX, points[i].x)
    maxY = jsMax(maxY, points[i].y)
  rect(minX - padding, minY - padding, maxX - minX + padding * 2, maxY - minY + padding * 2)

proc intersects*(a, b: Rect): bool {.inline.} =
  a.x + a.width >= b.x and a.y + a.height >= b.y and a.x <= b.x + b.width and
    a.y <= b.y + b.height

proc rotatePoint*(p, center: Pt, degrees: float64): Pt =
  if degrees == 0 or degrees != degrees: return p
  let radians = degrees * PI / 180
  let c = cos(radians)
  let s = sin(radians)
  let dx = p.x - center.x
  let dy = p.y - center.y
  pt(center.x + dx * c - dy * s, center.y + dx * s + dy * c)

proc rot*(node: Val): float64 =
  ## node.rotation || 0
  node.fo("rotation", 0)

proc nodeX*(n: Val): float64 = num(n["x"])
proc nodeY*(n: Val): float64 = num(n["y"])
proc nodeW*(n: Val): float64 = num(n["width"])
proc nodeH*(n: Val): float64 = num(n["height"])

proc nodeCenter*(node: Val): Pt {.inline.} =
  pt(nodeX(node) + nodeW(node) / 2, nodeY(node) + nodeH(node) / 2)

proc isSocketWire*(edge: Val): bool =
  if edge == nil or not edge.eqs("type", "edge"): return false
  for key in ["sourceAnchor", "targetAnchor"]:
    if edge.get(key).so("portKind", "") in ["input", "output"]: return true

proc portLabels*(node: Val, direction: string): seq[(string, string)] =
  let source = if direction == "input": node.so("inputPorts", "In")
               else: node.so("outputPorts", "Out")
  for entry in source.replace(';', ',').replace('\n', ',').split(','):
    if result.len >= 8: break
    let parts = entry.strip().split(':', maxsplit = 1)
    let name = parts[0].strip()
    if name.len == 0: continue
    result.add (name, if parts.len > 1: parts[1].strip().toLowerAscii() else: "any")

proc textOf*(v: Val): string {.inline.} =
  ## String(value == null ? '' : value)
  if nullish(v): "" else: str(v)

proc scriptField*(node: Val, key: string): string =
  let vs = node["visualScript"]
  if vs != nil and vs.isObj and not nullish(vs.get(key)): str(vs.get(key)) else: ""

proc scriptCodeVariable*(node: Val): string =
  ## Default code socket exposes the first global assignment, not a nil
  ## function return. Locals deliberately remain private to the code block.
  for line in scriptField(node, "code").split('\n'):
    let text = line.strip()
    let eq = text.find('=')
    if eq <= 0 or text.startsWith("--"): continue
    let name = text[0 ..< eq].strip()
    if name.len == 0 or name[0] notin {'a'..'z', 'A'..'Z', '_'}: continue
    var valid = true
    for ch in name:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}: valid = false
    if valid and eq + 1 < text.len and text[eq + 1] != '=': return name

proc orDash*(s: string): string = (if s.strip.len == 0: "…" else: s.strip)

proc scriptRows*(node: Val): seq[(string, string)] =
  ## What a script block shows under its title: (caption, value) rows; an
  ## empty caption marks a code line. Also what a port's dot aligns beside
  ## (see scriptPortRow/scriptRowLayout below) -- the one text layout both
  ## painter.nim's drawVisualScript and this module's hit-testing read.
  let f = proc(k: string): string = scriptField(node, k)
  case node.so("vsType", "")
  of "start": result.add ("", "▶ when Run is pressed")
  of "luau", "function", "process":
    let code = f("code")
    if code.strip.len == 0: result.add ("", "-- Luau code")
    for line in code.split('\n'): result.add ("", line)
  of "set": result.add ("", orDash(f("name")) & " = " & orDash(f("value")))
  of "condition":
    result.add ("", "if " & orDash(f("test")))
    result.add ("then", "true ▸   else ▸ false")
  of "for":
    let step = f("step").strip
    result.add ("", "for " & orDash(f("iterator")) & " = " & orDash(f("from")) & ", " &
      orDash(f("to")) & (if step.len > 0 and step != "1": ", " & step else: ""))
    result.add ("edges", "loop ▸   done ▸")
  of "while":
    result.add ("", "while " & orDash(f("condition")))
    let limit = f("max").strip
    result.add ("max", if limit.len == 0 or limit == "0": "no limit" else: limit & " times")
  of "output":
    result.add ("", orDash(f("value")))
    let mode = f("mode")
    result.add ("show", if mode == "console": "in the console"
                        elif mode == "alert": "as a browser alert"
                        else: "on this block")
  of "ask":
    result.add ("", orDash(f("name")) & " = prompt(" & orDash(f("message")) & ")")
  of "delay": result.add ("", "wait(" & orDash(f("seconds")) & ")")
  of "shape":
    result.add ("shape", orDash(f("target")))
    result.add ("", orDash(f("property")) & " = " & orDash(f("value")))
  of "qnoteOpen":
    let path = f("path").strip
    result.add ("note", if path.len == 0 or path == "\"\"": "the note open now" else: path)
  of "qnoteType":
    let text = orDash(f("text"))
    let blockKind = f("kind").strip
    try:
      # Built from values: one line per inserted element, in order, with
      # the same "value never chose one -> block's kind" rule the compiler uses.
      let meta = parseJson(f("__builder_text"))
      if meta.eqs("mode", "builder") and meta["parts"].isArr and meta["parts"].len > 0 and
          meta.so("expression", "") == f("text"):
        for part in meta["parts"]:
          let insertAs = part.so("insertAs", if blockKind.len == 0: "text" else: blockKind)
          if insertAs == "newline":
            result.add ("↵", "newline × " & part.so("count", "1"))
            continue
          let value = part.so("value", "")
          let shown = if value.strip.len == 0: "…"
                      elif part.eqs("kind", "text"): "\"" & value & "\""
                      else: value
          let tag = case insertAs
            of "h1": "H1"
            of "h2": "H2"
            of "h3": "H3"
            of "bullet": "•"
            of "number": "1."
            of "alpha": "a."
            else: ""
          result.add (tag, shown)
        return
    except JsonError: discard
    block:
      case blockKind
      of "h1": result.add ("H1", text)
      of "h2": result.add ("H2", text)
      of "h3": result.add ("H3", text)
      of "bullet": result.add ("", "• " & text)
      of "number": result.add ("", "1. " & text)
      of "alpha": result.add ("", "a. " & text)
      else: result.add ("", "Type " & text)
  of "qnoteParagraph":
    result.add ("", "¶ new paragraph")
  of "qnoteFind":
    result.add ("find", orDash(f("find")))
    result.add ("replace", orDash(f("replace")))
  of "qnoteFormat", "qnoteParagraphFormat":
    result.add ("", orDash(f("property")) & " = " & orDash(f("value")))
  of "qnoteMessage":
    result.add ("", orDash(f("text")))
  of "qnoteAnchor":
    let mode = f("mode").strip
    result.add ((if mode == "before": "before" elif mode == "after": "after" else: "replace"),
                "field " & orDash(f("field")))
  of "qnoteImage":
    result.add ("", orDash(f("src")))
    let w = f("width").strip
    let h = f("height").strip
    if w.len > 0 or h.len > 0: result.add ("size", (if w.len > 0: w else: "auto") & " × " & (if h.len > 0: h else: "auto"))
    if f("name").strip.len > 0: result.add ("name", f("name").strip)
  of "qnoteImageSource":
    result.add ("image", orDash(f("target")))
    result.add ("from", orDash(f("src")))
  of "qnoteTable":
    result.add ("", orDash(f("rows")) & " × " & orDash(f("cols")))
    if f("name").strip.len > 0: result.add ("name", f("name").strip)
    if f("data").strip.len > 0: result.add ("fill", f("data").strip)
  of "qnoteTableFill":
    result.add ("table", orDash(f("target")))
    result.add ("rows", orDash(f("data")))
  of "qnoteNameObject":
    result.add ("name", orDash(f("name")))
  of "qnoteXml":
    let xml = f("xml").strip.replace('\n', ' ')
    result.add ("", if xml.len > 60: xml[0 ..< 57] & "…" else: orDash(xml))
  of "qnoteTemplate":
    let name = f("templateName").strip
    result.add ("template", if name.len > 0: name elif f("template").strip.len > 0: f("template") else: "choose one…")
    let vars = f("variables").strip
    if vars.len > 0 and vars != "{}": result.add ("with", vars)
  of "qnoteRun":
    result.add ("", "Send to QNote")
    result.add ("save", orDash(f("save")))
  else:
    let rows = node["visualRows"]
    if rows != nil and rows.isArr:
      for row in rows:
        if row.isArr and row.len >= 2: result.add (textOf(row[0]), textOf(row[1]))
    let summary = node["visualSummary"]
    if summary != nil and summary.isArr and summary.len >= 2:
      result.add ("", textOf(summary[1]))
    if result.len == 0:
      # A plugin-registered block: this module can't see the plugin
      # registry, but the block carries its own declared fields.
      let vs = node["visualScript"]
      if vs != nil and vs.isObj:
        for key in vs.keys:
          if key in ["label", "vsType", "lastResult", "lastError"] or key.startsWith("__"): continue
          result.add (key, orDash(scriptField(node, key)))

proc scriptPortKey*(node: Val, name: string): string =
  # Legacy code blocks called the two directions `in` and `result`.
  # They are one displayed socket, without changing saved wire identities.
  let lower = name.toLowerAscii()
  let kind = node.so("vsType", "")
  if kind == "start":
    # A Start block has only one execution socket, including old documents
    # with independently named input/output ports or inherited style ports.
    "next"
  elif kind in ["set", "output"] and
      (lower in ["in", "out", "input", "output", "result", "value", "name"] or
       name == scriptField(node, "name")):
    "value"
  elif kind in ["luau", "function", "process"] and lower in ["in", "out", "input", "output", "result"]:
    "result"
  elif kind == "qnoteOpen" and lower in ["in", "out", "input", "output", "next", "path"]:
    "path"
  elif kind == "qnoteType" and lower in ["in", "out", "input", "output", "next", "text"]:
    "text"
  elif kind == "qnoteRun" and lower in ["in", "out", "input", "output", "next", "result"]:
    "result"
  else: name

proc scriptPortRow(node: Val, name: string): int =
  ## Which of a script block's own text rows (scriptRows above) a named port
  ## visually belongs beside. Almost every block's data lives in its first
  ## row; "Set shape" is the one block with two distinct rows (which shape,
  ## then which property) worth telling apart.
  if node.so("vsType", "") in ["luau", "function", "process"]:
    for i, row in scriptRows(node):
      if row[1].strip.len > 0 and not row[1].strip.startsWith("--"): return i
  if node.eqs("vsType", "shape") and name == "value": return 1
  if node.eqs("vsType", "qnoteFind") and name == "replace": return 1
  0

const scriptValueCharW = 6.6
  ## Advance width estimate, 11px ui-monospace (painter.nim's `scriptMono`)
  ## -- the value text is always this font, so a character count is exact
  ## enough to place a pin against without a live canvas to measure with.
const scriptCaptionCharW = 5.6
  ## Advance width estimate, 9px Inter 600 -- captions are a handful of
  ## short fixed words (THEN/EDGES/MAX/SHOW/SHAPE), so this only needs to be
  ## close.

proc scriptRowLayout(node: Val, row: int): (float64, float64) =
  ## Local x offsets (pixels from the node's left edge) where a row's value
  ## text starts (after any caption) and ends, mirroring painter.nim's
  ## drawVisualScript layout closely enough for a pin to land right against
  ## the text it represents instead of the block's outer edge.
  let rows = scriptRows(node)
  if row < 0 or row >= rows.len: return (9.0, 9.0)
  let (caption, value) = rows[row]
  let valueStart = if caption.len > 0: 9.0 + caption.toUpperAscii.len.float64 * scriptCaptionCharW + 6.0
                   else: 9.0
  let available = jsMax(0.0, nodeW(node) - 18.0 - (valueStart - 9.0))
  let shown = jsMin(value.len.float64 * scriptValueCharW, available)
  (valueStart, valueStart + shown)

proc scriptPortKeys(node: Val): seq[string] =
  ## Every declared field name, input-declared order first, deduplicated --
  ## a two-way field (e.g. Set variable's `value`) appears once, not twice.
  for (n, _) in portLabels(node, "input"):
    let key = scriptPortKey(node, n)
    if key notin result: result.add key
  for (n, _) in portLabels(node, "output"):
    let key = scriptPortKey(node, n)
    if key notin result: result.add key

proc scriptPortSide(node: Val, key: string): string =
  ## Both logical directions sit after the value, never on opposite edges.
  "output"

proc scriptPortLocalPoint(node: Val, key: string): (float64, float64) =
  ## The single local (x, y) pixel point, from the node's top-left, where a
  ## named field's pin sits -- one point per field name (see scriptPortSide),
  ## so a two-way field is one dot a wire can either feed or read from,
  ## rather than a separate input dot and output dot for the same variable.
  let key = scriptPortKey(node, key)
  let row = scriptPortRow(node, key)
  let side = scriptPortSide(node, key)
  var siblings: seq[string]
  for k in scriptPortKeys(node):
    if scriptPortRow(node, k) == row and scriptPortSide(node, k) == side: siblings.add k
  var slot = 0
  for i, k in siblings:
    if k == key: slot = i
  let header = jsMin(26.0, nodeH(node))
  let localY = header + 13.0 + float64(row) * 15.0
  let (valueStart, valueEnd) = scriptRowLayout(node, row)
  let localX = if side == "input": jsMax(3.0, valueStart - 6.0 - float64(slot) * 11.0)
               else: valueEnd + 7.0 + float64(slot) * 11.0
  (localX, localY)

proc portYFraction*(node: Val, direction: string, index: int,
                    entries: seq[(string, string)]): float64 =
  ## A port's vertical position as a fraction of the node's height. For an
  ## ordinary shape this spreads every port evenly down the side. For a
  ## script block it instead glues the dot to the text row that shows the
  ## variable it reads or writes (scriptRows/scriptPortRow), so the pin
  ## always sits beside its field instead of floating independently of the
  ## block's own content.
  if node.eqs("kind", "visualScript") and entries.len > 0:
    let (_, y) = scriptPortLocalPoint(node, entries[index][0])
    return clamp(y / jsMax(1.0, nodeH(node)), 0.06, 0.94)
  float64(index + 1) / float64(entries.len + 1)

proc portXFraction*(node: Val, direction: string, index: int,
                    entries: seq[(string, string)]): float64 =
  ## A port's horizontal position as a fraction of the node's width. For an
  ## ordinary shape this is the classic 0 (west/input) or 1 (east/output). A
  ## script block instead hugs the actual text of the row it belongs to (see
  ## scriptPortLocalPoint) -- and, notably, does not depend on `direction`:
  ## a field's input and output variants resolve to the identical point, so
  ## they draw and hit-test as one shared dot, not two.
  if node.eqs("kind", "visualScript") and entries.len > 0:
    let (x, _) = scriptPortLocalPoint(node, entries[index][0])
    return clamp(x / jsMax(1.0, nodeW(node)), 0.02, 0.98)
  if direction == "input": 0.0 else: 1.0

proc variablePorts*(node: Val): seq[VariablePort] =
  if not node.tr("portsEnabled") or node.eqs("type", "edge"): return
  let center = nodeCenter(node)
  for direction in ["input", "output"]:
    let entries = portLabels(node, direction)
    let side = if direction == "input": "west" else: "east"
    for i, entry in entries:
      let x = portXFraction(node, direction, i, entries)
      let y = portYFraction(node, direction, i, entries)
      let anchor = newObj()
      anchor["x"] = jnum(x)
      anchor["y"] = jnum(y)
      anchor["side"] = jstr(side)
      anchor["portKind"] = jstr(direction)
      anchor["portIndex"] = jnum(i)
      anchor["portName"] = jstr(entry[0])
      let p = pt(nodeX(node) + x * nodeW(node), nodeY(node) + y * nodeH(node))
      result.add VariablePort(name: entry[0], dataType: entry[1], direction: direction,
                              side: side, index: i, anchor: anchor,
                              point: rotatePoint(p, center, rot(node)))

proc nodePort*(node: Val, side: string): Pt =
  let center = nodeCenter(node)
  var p = center
  if side == "north": p.y = nodeY(node)
  if side == "south": p.y = nodeY(node) + nodeH(node)
  if side == "west": p.x = nodeX(node)
  if side == "east": p.x = nodeX(node) + nodeW(node)
  rotatePoint(p, center, rot(node))

proc nodeAnchor*(node: Val, anchor: Val, fallbackSide: string): Pt =
  ## Normalised anchor on a node, glued through move/resize/rotate.
  if node.tr("portsEnabled") and anchor != nil and anchor["portIndex"].isNum:
    let direction = anchor.so("portKind", "")
    let entries = portLabels(node, direction)
    let index = int(num(anchor["portIndex"]))
    if direction in ["input", "output"] and index >= 0 and index < entries.len:
      let x = portXFraction(node, direction, index, entries)
      let y = portYFraction(node, direction, index, entries)
      return rotatePoint(pt(nodeX(node) + x * nodeW(node), nodeY(node) + y * nodeH(node)),
                         nodeCenter(node), rot(node))
  if nullish(anchor) or not isFiniteNum(num(anchor["x"])) or not isFiniteNum(num(anchor["y"])):
    return nodePort(node, if fallbackSide.len > 0: fallbackSide else: "east")
  let center = nodeCenter(node)
  let p = pt(nodeX(node) + clamp(num(anchor["x"]), 0, 1) * nodeW(node),
             nodeY(node) + clamp(num(anchor["y"]), 0, 1) * nodeH(node))
  rotatePoint(p, center, rot(node))

proc oppositeSide*(side: string): string =
  if side == "north": "south"
  elif side == "south": "north"
  elif side == "west": "east"
  else: "west"

proc nearestSide*(node: Val, p: Pt): string =
  let center = nodeCenter(node)
  let local = rotatePoint(p, center, -rot(node))
  let d = [abs(local.y - nodeY(node)), abs(local.x - nodeX(node) - nodeW(node)),
           abs(local.y - nodeY(node) - nodeH(node)), abs(local.x - nodeX(node))]
  const names = ["north", "east", "south", "west"]
  var best = 0
  for i in 1 .. 3:
    if d[i] < d[best]: best = i
  names[best]

proc samePoint*(a, b: Pt): bool {.inline.} =
  abs(a.x - b.x) < 0.01 and abs(a.y - b.y) < 0.01

proc simplifyOrthogonal*(points: openArray[Pt]): seq[Pt] =
  for p in points:
    if result.len == 0 or not samePoint(result[^1], p): result.add p
  var j = result.len - 2
  while j > 0:
    let a = result[j - 1]
    let b = result[j]
    let c = result[j + 1]
    if (abs(a.x - b.x) < 0.01 and abs(b.x - c.x) < 0.01) or
        (abs(a.y - b.y) < 0.01 and abs(b.y - c.y) < 0.01):
      result.delete(j)
    dec j

proc orthogonalizeRoute*(points: seq[Pt], sourceSide, targetSide: string): seq[Pt] =
  ## Old mxGraph control points are routing hints: add the missing elbows.
  if points.len < 2: return points
  var res = @[points[0]]
  var horizontal = sourceSide == "east" or sourceSide == "west"
  for i in 1 ..< points.len - 1:
    let hint = points[i]
    var previous = res[^1]
    let dx = abs(hint.x - previous.x)
    let dy = abs(hint.y - previous.y)
    if dx > 0.01 and dy > 0.01:
      let elbow = if horizontal: pt(hint.x, previous.y) else: pt(previous.x, hint.y)
      res.add elbow
      horizontal = not horizontal
    previous = res[^1]
    if not samePoint(previous, hint):
      horizontal = abs(hint.y - previous.y) < 0.01
      res.add hint
  let target = points[^1]
  let last = res[^1]
  if abs(target.x - last.x) > 0.01 and abs(target.y - last.y) > 0.01:
    let horizontalTarget = targetSide == "east" or targetSide == "west"
    res.add(if horizontalTarget: pt(last.x, target.y) else: pt(target.x, last.y))
  res.add target
  simplifyOrthogonal(res)

proc automaticRoute*(source, target: Pt, sourceSide, targetSide: string): seq[Pt] =
  ## sourceSide/targetSide are "" for a free (dangling) terminal.
  let horizontalSource = sourceSide == "east" or sourceSide == "west"
  let horizontalTarget = targetSide == "east" or targetSide == "west"
  let hasSource = sourceSide.len > 0
  let hasTarget = targetSide.len > 0
  const gap = 28.0
  let s = source
  let t = target

  if hasSource and not hasTarget:
    return simplifyOrthogonal(if horizontalSource: @[s, pt(t.x, s.y), t]
                              else: @[s, pt(s.x, t.y), t])
  if not hasSource and hasTarget:
    return simplifyOrthogonal(if horizontalTarget: @[s, pt(s.x, t.y), t]
                              else: @[s, pt(t.x, s.y), t])
  if not hasSource and not hasTarget:
    return simplifyOrthogonal(@[s, pt(t.x, s.y), t])

  var so = s
  var to = t
  if sourceSide == "east": so.x += gap
  if sourceSide == "west": so.x -= gap
  if sourceSide == "north": so.y -= gap
  if sourceSide == "south": so.y += gap
  if targetSide == "east": to.x += gap
  if targetSide == "west": to.x -= gap
  if targetSide == "north": to.y -= gap
  if targetSide == "south": to.y += gap

  var points = @[s, so]
  if horizontalSource and horizontalTarget:
    let midX = (so.x + to.x) / 2
    points.add pt(midX, so.y)
    points.add pt(midX, to.y)
  elif not horizontalSource and not horizontalTarget:
    let midY = (so.y + to.y) / 2
    points.add pt(so.x, midY)
    points.add pt(to.x, midY)
  elif horizontalSource:
    points.add pt(to.x, so.y)
  else:
    points.add pt(so.x, to.y)
  points.add to
  points.add t
  simplifyOrthogonal(points)

proc anchorSideOf(anchor: Val): string =
  if truthy(anchor):
    let s = anchor["side"]
    if truthy(s): return str(s)
  ""

proc edgeSides*(edge: Val, source, target: Val): (string, string) =
  ## The routing sides of an edge's two terminals ("" when dangling).
  var sourceSide = ""
  if source != nil:
    sourceSide = anchorSideOf(edge["sourceAnchor"])
    if sourceSide.len == 0: sourceSide = edge.so("sourceSide", "east")
  var targetSide = ""
  if target != nil:
    targetSide = anchorSideOf(edge["targetAnchor"])
    if targetSide.len == 0:
      let ts = edge["targetSide"]
      targetSide = if truthy(ts): str(ts)
                   else: oppositeSide(if sourceSide.len > 0: sourceSide else: "east")
  (sourceSide, targetSide)

proc edgePoints*(edge: Val, scene: Scene): seq[Pt] =
  let source = lookup(scene, edge["sourceId"])
  let target = lookup(scene, edge["targetId"])
  let (sourceSide, targetSide) = edgeSides(edge, source, target)
  let preview = edge["previewPoints"]
  var sourcePoint, targetPoint: Pt
  var haveSource, haveTarget: bool
  if source != nil:
    sourcePoint = nodeAnchor(source, edge["sourceAnchor"], sourceSide)
    haveSource = true
  else:
    let sp = edge["sourcePoint"]
    if truthy(sp):
      sourcePoint = toPt(sp)
      haveSource = true
    elif preview.len > 0 and not nullish(preview[0]):
      sourcePoint = toPt(preview[0])
      haveSource = true
  if target != nil:
    targetPoint = nodeAnchor(target, edge["targetAnchor"], targetSide)
    haveTarget = true
  else:
    let tp = edge["targetPoint"]
    if truthy(tp):
      targetPoint = toPt(tp)
      haveTarget = true
    elif preview.len > 0 and not nullish(preview[preview.len - 1]):
      targetPoint = toPt(preview[preview.len - 1])
      haveTarget = true

  if not haveSource or not haveTarget:
    return valPts(preview)

  let route = edge["route"]
  if not nullish(route) and route.len > 0:
    var routed = @[sourcePoint]
    for p in route:
      if p != nil and p.kind == vObj: routed.add toPt(p)
      else: routed.add pt(NaN, NaN)
    routed.add targetPoint
    if edge.eqs("lineStyle", "orthogonal"):
      return orthogonalizeRoute(routed, sourceSide, targetSide)
    return routed

  if edge.eqs("lineStyle", "straight"):
    return @[sourcePoint, targetPoint]
  automaticRoute(sourcePoint, targetPoint, sourceSide, targetSide)

type CircArc* = object
  valid*: bool
  source*, target*, center*, middle*: Pt
  radius*, startAngle*, endAngle*, sweepDegrees*: float64
  anticlockwise*: bool
  side*: float64
  samples*: seq[Pt]
  closed*: bool

proc circularArc*(edge: Val, scene: Scene): CircArc =
  let endpoints = edgePoints(edge, scene)
  if endpoints.len < 2: return
  let source = endpoints[0]
  let target = endpoints[^1]
  let dx = target.x - source.x
  let dy = target.y - source.y
  let chord = hypot(dx, dy)
  let side = if num(edge["arcSide"]) < 0: -1.0 else: 1.0
  var requested = abs(num(edge["arcSweep"]))
  if not isFiniteNum(requested) or requested < 1:
    requested = if chord < 0.01: 360.0 else: 180.0
  var center: Pt
  var radius, startAngle, sweepDegrees: float64

  if chord < 0.01:
    sweepDegrees = clamp(requested, 1, 360)
    var r = abs(num(edge["circleRadius"]))
    if not truthy(jnum(r)): r = 60
    radius = clamp(r, 5, 10000)
    center = source
    startAngle = -PI / 2
  else:
    sweepDegrees = clamp(requested, 1, 180)
    let radians = sweepDegrees * PI / 180
    radius = chord / (2 * sin(radians / 2))
    let height = if sweepDegrees >= 179.999: 0.0 else: chord / (2 * tan(radians / 2))
    let normal = pt(-dy / chord, dx / chord)
    center = pt((source.x + target.x) / 2 - normal.x * height * side,
                (source.y + target.y) / 2 - normal.y * height * side)
    startAngle = arctan2(source.y - center.y, source.x - center.x)

  let sweepRadians = sweepDegrees * PI / 180
  let endAngle = startAngle - side * sweepRadians
  let divisions = max(12, int(ceil(sweepDegrees / 4)))
  var samples = newSeqOfCap[Pt](divisions + 1)
  for i in 0 .. divisions:
    let angle = startAngle - side * sweepRadians * float64(i) / float64(divisions)
    samples.add pt(center.x + cos(angle) * radius, center.y + sin(angle) * radius)
  if chord >= 0.01:
    samples[0] = source
    samples[^1] = target
  let middleAngle = startAngle - side * sweepRadians / 2
  CircArc(valid: true, source: source, target: target, center: center, radius: radius,
          startAngle: startAngle, endAngle: endAngle, anticlockwise: side > 0,
          side: side, sweepDegrees: sweepDegrees, samples: samples,
          middle: pt(center.x + cos(middleAngle) * radius, center.y + sin(middleAngle) * radius),
          closed: chord < 0.01)

# --------------------------------------------------------------- tables --

type
  Track* = object
    pos*, size*: float64   ## y/height for rows, x/width for columns
  TableGrid* = object
    rows*, columns*: seq[Track]
    titleHeight*, contentY*, contentBottom*: float64
  CellBox* = object
    row*, column*, rowspan*, colspan*: int
    cell*: Val
    x*, y*, width*, height*: float64
  CellOrigin* = object
    row*, column*, rowspan*, colspan*: int
    cell*: Val

proc weightsFor(v: Val, count: int): seq[float64] =
  if v.isArr and v.len == count:
    for x in v: result.add num(x)
  else:
    result = newSeq[float64](count)
    for i in 0 ..< count: result[i] = 1

proc tableGrid*(node: Val): TableGrid =
  let rowCount = max(1, int(node.fo("rows", 3)))
  let columnCount = max(1, int(node.fo("columns", 3)))
  let height = nodeH(node)
  let width = nodeW(node)
  let titleHeight = if node.nul("tableTitle"): 0.0
                    else: clamp(node.nor("tableTitleHeight", 30), 0, height)
  let availableHeight = max(0.0, height - titleHeight)
  let rowWeights = weightsFor(node["rowWeights"], rowCount)
  let columnWeights = weightsFor(node["columnWeights"], columnCount)
  var rowTotal = 0.0
  for w in rowWeights: rowTotal += w
  if not truthy(jnum(rowTotal)): rowTotal = float64(rowCount)
  var columnTotal = 0.0
  for w in columnWeights: columnTotal += w
  if not truthy(jnum(columnTotal)): columnTotal = float64(columnCount)

  let x0 = nodeX(node)
  let y0 = nodeY(node)
  var offset = 0.0
  let fixedRows = node.tr("fixedRows")
  for r in 0 ..< rowCount:
    var h: float64
    if fixedRows:
      h = max(1.0, (if truthy(jnum(rowWeights[r])): rowWeights[r] else: 1.0))
    else:
      h = availableHeight * rowWeights[r] / rowTotal
    if offset + h > availableHeight: h = max(0.0, availableHeight - offset)
    result.rows.add Track(pos: y0 + titleHeight + offset, size: h)
    offset += h
  let rowExtent = offset
  offset = 0
  for c in 0 ..< columnCount:
    let w = width * columnWeights[c] / columnTotal
    result.columns.add Track(pos: x0 + offset, size: w)
    offset += w
  result.titleHeight = titleHeight
  result.contentY = y0 + titleHeight
  result.contentBottom = y0 + titleHeight + min(rowExtent, availableHeight)

proc parseCellKey*(key: string): (float64, float64) =
  var comma = -1
  for i, c in key:
    if c == ',':
      comma = i
      break
  if comma < 0: return (parseNumStr(key), NaN)
  (parseNumStr(key[0 ..< comma]), parseNumStr(key[comma + 1 .. ^1]))

proc cellObj*(v: Val): Val =
  ## typeof cell === 'string' ? { text: cell } : cell || {}
  if v != nil and v.kind == vStr:
    result = newObj()
    result["text"] = v
  elif truthy(v): result = v
  else: result = newObj()

proc tableCellOriginAt*(node: Val, row0, column0: float64): CellOrigin =
  let rows = max(1.0, (let r = num(node["rows"]); if truthy(jnum(r)): r else: 1.0))
  let columns = max(1.0, (let c = num(node["columns"]); if truthy(jnum(c)): c else: 1.0))
  var row = max(0.0, min(rows - 1, (if truthy(jnum(row0)): row0 else: 0.0)))
  var column = max(0.0, min(columns - 1, (if truthy(jnum(column0)): column0 else: 0.0)))
  let cells = node["cells"]
  if cells.isObj:
    for i in 0 ..< cells.ks.len:
      let key = atomName(cells.ks[i])
      let (originRow, originColumn) = parseCellKey(key)
      let cell = cellObj(cells.vs[i])
      let rowspan = max(1.0, min(rows - originRow, cell.fo("rowspan", 1)))
      let colspan = max(1.0, min(columns - originColumn, cell.fo("colspan", 1)))
      if row >= originRow and row < originRow + rowspan and
          column >= originColumn and column < originColumn + colspan:
        return CellOrigin(row: int(originRow), column: int(originColumn),
                          rowspan: int(rowspan), colspan: int(colspan), cell: cell)
  let empty = newObj()
  empty["text"] = jstr("")
  CellOrigin(row: int(row), column: int(column), rowspan: 1, colspan: 1, cell: empty)

proc tableCellBox*(node: Val, row, column: float64): CellBox =
  let grid = tableGrid(node)
  let origin = tableCellOriginAt(node, row, column)
  var width = 0.0
  var height = 0.0
  for c in origin.column ..< origin.column + origin.colspan:
    if c >= 0 and c < grid.columns.len: width += grid.columns[c].size
  for r in origin.row ..< origin.row + origin.rowspan:
    if r >= 0 and r < grid.rows.len: height += grid.rows[r].size
  CellBox(row: origin.row, column: origin.column, rowspan: origin.rowspan,
          colspan: origin.colspan, cell: origin.cell,
          x: grid.columns[origin.column].pos, y: grid.rows[origin.row].pos,
          width: width, height: height)

proc tableCellAt*(node: Val, p: Pt): (bool, CellBox) =
  let grid = tableGrid(node)
  var row = -1
  var column = -1
  for r in 0 ..< grid.rows.len:
    if p.y >= grid.rows[r].pos and p.y < grid.rows[r].pos + grid.rows[r].size: row = r
  for c in 0 ..< grid.columns.len:
    if p.x >= grid.columns[c].pos and p.x < grid.columns[c].pos + grid.columns[c].size: column = c
  if row < 0 or column < 0: return (false, CellBox())
  (true, tableCellBox(node, float64(row), float64(column)))

proc cellBoxVal*(b: CellBox): Val =
  result = newObj()
  result["row"] = jnum(b.row)
  result["column"] = jnum(b.column)
  result["rowspan"] = jnum(b.rowspan)
  result["colspan"] = jnum(b.colspan)
  result["cell"] = b.cell
  result["x"] = jnum(b.x)
  result["y"] = jnum(b.y)
  result["width"] = jnum(b.width)
  result["height"] = jnum(b.height)

# --------------------------------------------------------------- bounds --

proc nodeCorners*(node: Val): array[4, Pt] =
  let c = nodeCenter(node)
  let r = rot(node)
  let x = nodeX(node)
  let y = nodeY(node)
  let w = nodeW(node)
  let h = nodeH(node)
  [rotatePoint(pt(x, y), c, r), rotatePoint(pt(x + w, y), c, r),
   rotatePoint(pt(x + w, y + h), c, r), rotatePoint(pt(x, y + h), c, r)]

proc itemBounds*(item: Val, scene: Scene): Rect =
  if item.eqs("type", "edge"):
    if item.eqs("lineStyle", "circular"):
      let arc = circularArc(item, scene)
      if arc.valid: return boundsOfPoints(arc.samples, 12)
    return boundsOfPoints(edgePoints(item, scene), 12)
  boundsOfPoints(nodeCorners(item), 10)
