## SVG -> classic mxGraph XML -> editable diagram objects
## (SvgMxGraphConverter). The SVG is parsed by the browser's XML parser; the
## geometry, transforms, path flattening and cell generation are here.

import std/[math, strutils]
import ../jsval, ../geometry
import htmltree, mxformat, jsutil

type
  SvgError* = object of CatchableError
  M = object
    a, b, c, d, e, f: float64
  P = object
    x, y: float64
  Presentation = seq[(string, string)]

  SvgResult* = object
    xml*: string
    document*: Val
    items*: Val
    width*, height*: float64
    warnings*: seq[string]

var serial = 0

proc numv(value: string, fallback = 0.0): float64 =
  let v = jsParseFloat(value)
  if isFiniteJs(v): v else: fallback

proc esc(value: string): string =
  for c in value:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&apos;"
    else: result.add c

const Defaults = [("fill", "#000000"), ("stroke", "none"), ("stroke-width", "1"), ("opacity", "1"),
  ("stroke-dasharray", ""), ("font-family", "Arial, Helvetica, sans-serif"),
  ("font-size", "12"), ("font-weight", "normal"), ("font-style", "normal"),
  ("text-anchor", "start"), ("marker-start", ""), ("marker-end", "")]

proc lookup(p: Presentation, name: string): string =
  for (k, v) in p:
    if k == name: return v
  ""

proc presentation(element: HNode, inherited: Presentation, hasInherited: bool): Presentation =
  for (name, fallback) in Defaults:
    var value = element.attr(name)
    if value.len == 0: value = element.cssProp(name)
    if value.len == 0 and hasInherited: value = inherited.lookup(name)
    result.add (name, if value.len == 0: fallback else: value)

proc multiply(a, b: M): M =
  M(a: a.a*b.a + a.c*b.b, b: a.b*b.a + a.d*b.b,
    c: a.a*b.c + a.c*b.d, d: a.b*b.c + a.d*b.d,
    e: a.a*b.e + a.c*b.f + a.e, f: a.b*b.e + a.d*b.f + a.f)

const Identity = M(a: 1, d: 1)

proc splitNumbers(body: string): seq[float64] =
  ## body.trim().split(/[\s,]+/).map(Number)
  let t = jsTrim(body)
  var parts: seq[string]
  var cur = ""
  var i = 0
  while i <= t.len:
    if i == t.len or t[i] in {' ', '\t', '\n', '\r', '\f', '\v', ','}:
      parts.add cur
      cur = ""
      while i < t.len and t[i] in {' ', '\t', '\n', '\r', '\f', '\v', ','}: inc i
      if i == t.len: break
      continue
    cur.add t[i]
    inc i
  if parts.len == 0: parts.add ""
  for p in parts: result.add jsNumber(p)

proc orD(x, d: float64): float64 = (if x != x or x == 0: d else: x)

proc transform(value: string): M =
  result = Identity
  var i = 0
  while i < value.len:
    var kind = ""
    for k in ["matrix", "translate", "scale", "rotate"]:
      if value.continuesWith(k, i):
        kind = k
        break
    if kind.len == 0:
      inc i
      continue
    var j = i + kind.len
    while j < value.len and value[j] in {' ', '\t', '\n', '\r', '\f', '\v'}: inc j
    if j >= value.len or value[j] != '(':
      inc i
      continue
    let close = value.find(')', j + 1)
    if close < 0: break
    let v = splitNumbers(value[j + 1 ..< close])
    template at(k: int): float64 = (if k < v.len: v[k] else: NaN)
    var next = Identity
    if kind == "matrix" and v.len >= 6:
      next = M(a: v[0], b: v[1], c: v[2], d: v[3], e: v[4], f: v[5])
    elif kind == "translate":
      next.e = orD(at(0), 0)
      next.f = orD(at(1), 0)
    elif kind == "scale":
      next.a = orD(at(0), 1)
      next.d = if v.len > 1: v[1] else: next.a
    elif kind == "rotate":
      let r = orD(at(0), 0) * PI / 180
      let c = cos(r)
      let s = sin(r)
      next = M(a: c, b: s, c: -s, d: c)
      if v.len > 2:
        next = multiply(multiply(M(a: 1, d: 1, e: v[1], f: v[2]), next), M(a: 1, d: 1, e: -v[1], f: -v[2]))
    result = multiply(result, next)
    i = close + 1

proc pt(x, y: float64, m: M): P = P(x: m.a*x + m.c*y + m.e, y: m.b*x + m.d*y + m.f)

proc box(points: openArray[P]): Rect =
  var xs, ys: seq[float64]
  for p in points:
    xs.add p.x
    ys.add p.y
  var x = xs[0]
  var y = ys[0]
  var mx = xs[0]
  var my = ys[0]
  for v in xs:
    x = jsMin(x, v)
    mx = jsMax(mx, v)
  for v in ys:
    y = jsMin(y, v)
    my = jsMax(my, v)
  Rect(x: x, y: y, width: mx - x, height: my - y)

proc transformedRect(x, y, width, height: float64, m: M): (Rect, float64) =
  let center = pt(x + width / 2, y + height / 2, m)
  let scaleX = hypot(m.a, m.b)
  let scaleY = hypot(m.c, m.d)
  let dot = m.a * m.c + m.b * m.d
  if scaleX > 0 and scaleY > 0 and abs(dot) <= 0.000001 * scaleX * scaleY:
    let tw = abs(width * scaleX)
    let th = abs(height * scaleY)
    return (Rect(x: center.x - tw / 2, y: center.y - th / 2, width: tw, height: th),
            arctan2(m.b, m.a) * 180 / PI)
  (box([pt(x, y, m), pt(x + width, y, m), pt(x, y + height, m), pt(x + width, y + height, m)]), 0.0)

type StyleVal = object
  isNull: bool
  text: string

proc sv(s: string): StyleVal = StyleVal(text: s)
proc sn(x: float64): StyleVal = StyleVal(text: jsStr(x))
proc snull(): StyleVal = StyleVal(isNull: true)

proc styleText(style: Presentation, shape: string, extra: openArray[(string, StyleVal)] = []): string =
  var values: seq[(string, StyleVal)] = @[
    ("shape", sv(shape)), ("html", sn(0)), ("fillColor", sv(style.lookup("fill"))),
    ("strokeColor", sv(style.lookup("stroke"))),
    ("strokeWidth", sn(numv(style.lookup("stroke-width"), 1))),
    ("opacity", sn(numv(style.lookup("opacity"), 1) * 100)),
    ("dashed", sn(if style.lookup("stroke-dasharray").len > 0: 1 else: 0)),
    ("startArrow", sv(if style.lookup("marker-start").len > 0: "classic" else: "none")),
    ("endArrow", sv(if style.lookup("marker-end").len > 0: "classic" else: "none")),
    ("endFill", sn(if style.lookup("marker-end").len > 0: 1 else: 0))]
  for (k, v) in extra:
    var found = false
    for item in values.mitems:
      if item[0] == k:
        item[1] = v
        found = true
    if not found: values.add (k, v)
  for (k, v) in values:
    if not v.isNull: result.add k & "=" & v.text & ";"

proc geometry(bounds: Rect): string =
  "<mxGeometry x=\"" & jsStr(bounds.x) & "\" y=\"" & jsStr(bounds.y) & "\" width=\"" &
    jsStr(jsMax(0.1, bounds.width)) & "\" height=\"" & jsStr(jsMax(0.1, bounds.height)) & "\" as=\"geometry\" />"

proc vertex(value: string, bounds: Rect, style: string): string =
  inc serial
  "<mxCell id=\"svg-" & $serial & "\" value=\"" & esc(value) & "\" style=\"" & esc(style) &
    "\" vertex=\"1\" parent=\"1\">" & geometry(bounds) & "</mxCell>"

proc edge(points: seq[P], style: string, circular = false): string =
  if points.len < 2: return ""
  inc serial
  let source = points[0]
  let target = points[^1]
  var waypoints = ""
  if not circular and points.len > 2:
    waypoints = "<Array as=\"points\">"
    for p in points[1 .. ^2]:
      waypoints.add "<mxPoint x=\"" & jsStr(p.x) & "\" y=\"" & jsStr(p.y) & "\" />"
    waypoints.add "</Array>"
  "<mxCell id=\"svg-" & $serial & "\" value=\"\" style=\"" & esc(style) & "\" edge=\"1\" parent=\"1\">" &
    "<mxGeometry relative=\"1\" as=\"geometry\"><mxPoint x=\"" & jsStr(source.x) & "\" y=\"" &
    jsStr(source.y) & "\" as=\"sourcePoint\" />" & waypoints & "<mxPoint x=\"" & jsStr(target.x) &
    "\" y=\"" & jsStr(target.y) & "\" as=\"targetPoint\" /></mxGeometry></mxCell>"

proc tokens(data: string): seq[string] =
  ## /[a-zA-Z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:e[-+]?\d+)?/ig
  var i = 0
  let n = data.len
  while i < n:
    let c = data[i]
    if c in {'a'..'z', 'A'..'Z'}:
      result.add $c
      inc i
      continue
    var j = i
    if j < n and data[j] in {'-', '+'}: inc j
    let digitsStart = j
    while j < n and data[j] in {'0'..'9'}: inc j
    var matched = false
    var e = j
    if j < n and data[j] == '.' and j + 1 < n and data[j + 1] in {'0'..'9'}:
      e = j + 1
      while e < n and data[e] in {'0'..'9'}: inc e
      matched = true
    elif j > digitsStart:
      e = j
      if e < n and data[e] == '.': inc e
      matched = true
    if not matched:
      inc i
      continue
    if e < n and data[e] in {'e', 'E'}:
      var k = e + 1
      if k < n and data[k] in {'-', '+'}: inc k
      if k < n and data[k] in {'0'..'9'}:
        while k < n and data[k] in {'0'..'9'}: inc k
        e = k
    result.add data[i ..< e]
    i = e

proc isLetter(s: string): bool = s.len == 1 and s[0] in {'a'..'z', 'A'..'Z'}

proc paths(data: string, m: M, style: Presentation, warnings: var seq[string]): seq[string] =
  let t = tokens(data)
  var i = 0
  var command = ""
  var current = P()
  var start: P
  var hasStart = false
  var sub: seq[P]
  var res: seq[string]
  proc read(): float64 =
    let v = if i < t.len: numv(t[i]) else: 0.0
    inc i
    v
  proc flush() =
    if sub.len > 1: res.add edge(sub, styleText(style, "none", [("edgeStyle", sv("none"))]))
    sub = @[]
  while i < t.len:
    if isLetter(t[i]):
      command = t[i]
      inc i
    let relative = command == command.toLowerAscii()
    let upper = command.toUpperAscii()
    if upper == "M" or upper == "L":
      var x = read()
      var y = read()
      if relative:
        x += current.x
        y += current.y
      if upper == "M":
        flush()
        start = P(x: x, y: y)
        hasStart = true
        command = if relative: "l" else: "L"
      current = P(x: x, y: y)
      sub.add pt(x, y, m)
    elif upper == "H" or upper == "V":
      let v = read()
      if upper == "H": current.x = if relative: current.x + v else: v
      else: current.y = if relative: current.y + v else: v
      sub.add pt(current.x, current.y, m)
    elif upper == "Q":
      var qx = read()
      var qy = read()
      var ax = read()
      var ay = read()
      if relative:
        qx += current.x; qy += current.y; ax += current.x; ay += current.y
      let q0 = current
      for q in 1 .. 8:
        let u = float64(q) / 8
        let w = 1 - u
        sub.add pt(w*w*q0.x + 2*w*u*qx + u*u*ax, w*w*q0.y + 2*w*u*qy + u*u*ay, m)
      current = P(x: ax, y: ay)
    elif upper == "C":
      var x1 = read()
      var y1 = read()
      var x2 = read()
      var y2 = read()
      var cx = read()
      var cy = read()
      if relative:
        x1 += current.x; y1 += current.y; x2 += current.x; y2 += current.y
        cx += current.x; cy += current.y
      let c0 = current
      for c in 1 .. 12:
        let cu = float64(c) / 12
        let cv = 1 - cu
        sub.add pt(cv*cv*cv*c0.x + 3*cv*cv*cu*x1 + 3*cv*cu*cu*x2 + cu*cu*cu*cx,
                   cv*cv*cv*c0.y + 3*cv*cv*cu*y1 + 3*cv*cu*cu*y2 + cu*cu*cu*cy, m)
      current = P(x: cx, y: cy)
    elif upper == "A":
      let rx = read()
      let ry = read()
      let rotation = read()
      let large = read()
      let sweep = read()
      var ex = read()
      var ey = read()
      if relative:
        ex += current.x
        ey += current.y
      let source = pt(current.x, current.y, m)
      let target = pt(ex, ey, m)
      if sub.len == 1 and abs(rx - ry) < 0.01 and abs(rotation) < 0.01 and i >= t.len:
        let chord = hypot(ex - current.x, ey - current.y)
        var angle = 2 * arcsin(jsMin(1.0, chord / (2 * abs(rx)))) * 180 / PI
        if large != 0 and large == large: angle = 360 - angle
        res.add edge(@[source, target], styleText(style, "none", [("edgeStyle", sv("none")),
          ("qochartRoute", sv("circular")), ("arcSweep", sn(angle)),
          ("arcSide", sn(if sweep != 0 and sweep == sweep: -1 else: 1)), ("circleRadius", sn(abs(rx)))]), true)
        sub = @[]
      else:
        warnings.add "A compound or elliptical arc was approximated by its endpoint."
        sub.add target
      current = P(x: ex, y: ey)
    elif upper == "Z":
      if hasStart:
        current = start
        sub.add pt(start.x, start.y, m)
      command = ""
    else:
      warnings.add "Unsupported path command " & command & " was skipped."
      break
  flush()
  res

proc utf16Len(s: string): int =
  var i = 0
  while i < s.len:
    let c = ord(s[i])
    if c < 0x80: inc i
    elif c < 0xE0: i += 2
    elif c < 0xF0: i += 3
    else:
      i += 4
      inc result
    inc result

proc walk(element: HNode, inherited: Presentation, hasInherited: bool, parent: M,
          cells: var seq[string], warnings: var seq[string]) =
  let style = presentation(element, inherited, hasInherited)
  let m = multiply(parent, transform(element.attr("transform")))
  let name = element.local
  if name == "svg" or name == "g":
    for child in element.elements: walk(child, style, true, m, cells, warnings)
    return
  if name in ["defs", "marker", "title", "desc"]: return
  case name
  of "line":
    cells.add edge(@[pt(numv(element.attr("x1")), numv(element.attr("y1")), m),
                     pt(numv(element.attr("x2")), numv(element.attr("y2")), m)],
                   styleText(style, "none", [("edgeStyle", sv("none"))]))
  of "polyline", "polygon":
    let raw = splitNumbers(element.attr("points"))
    var points: seq[P]
    var p = 0
    while p + 1 < raw.len:
      points.add pt(raw[p], raw[p + 1], m)
      p += 2
    if name == "polygon" and points.len > 0: points.add points[0]
    cells.add edge(points, styleText(style, "none", [("edgeStyle", sv("none"))]))
  of "rect":
    let (bounds, rotation) = transformedRect(numv(element.attr("x")), numv(element.attr("y")),
      numv(element.attr("width")), numv(element.attr("height")), m)
    cells.add vertex("", bounds, styleText(style, "rectangle", [
      ("rounded", sn(if numv(element.attr("rx")) > 0: 1 else: 0)),
      ("rotation", if abs(rotation) > 0.000001: sn(rotation) else: snull())]))
  of "circle", "ellipse":
    let cx = numv(element.attr("cx"))
    let cy = numv(element.attr("cy"))
    let rx = if name == "circle": numv(element.attr("r")) else: numv(element.attr("rx"))
    let ry = if name == "circle": rx else: numv(element.attr("ry"))
    cells.add vertex("", box([pt(cx - rx, cy - ry, m), pt(cx + rx, cy - ry, m),
                             pt(cx - rx, cy + ry, m), pt(cx + rx, cy + ry, m)]),
                     styleText(style, "ellipse"))
  of "text":
    let tp = pt(numv(element.attr("x")), numv(element.attr("y")), m)
    let text = element.textContent()
    let fontSize = numv(style.lookup("font-size"), 12)
    let tw = jsMax(fontSize, float64(utf16Len(text)) * fontSize * 0.62)
    var tx = tp.x
    let anchor = style.lookup("text-anchor")
    if anchor == "middle": tx -= tw / 2
    elif anchor == "end": tx -= tw
    let weight = style.lookup("font-weight")
    let fontStyle = (if weight.toLowerAscii() == "bold" or numv(weight, 400) >= 700: 1 else: 0) +
                    (if style.lookup("font-style") == "italic": 2 else: 0)
    let textRotation = arctan2(m.b, m.a) * 180 / PI
    cells.add vertex(text, Rect(x: tx, y: tp.y - fontSize, width: tw, height: fontSize * 1.4),
      styleText(style, "text", [("fillColor", sv("none")), ("strokeColor", sv("none")),
        ("fontColor", sv(style.lookup("fill"))), ("fontFamily", sv(style.lookup("font-family"))),
        ("fontSize", sn(fontSize)), ("fontStyle", sn(float64(fontStyle))),
        ("align", sv(if anchor == "middle": "center" elif anchor == "end": "right" else: "left")),
        ("verticalAlign", sv("middle")),
        ("rotation", if abs(textRotation) > 0.000001: sn(textRotation) else: snull())]))
  of "path":
    cells.add paths(element.attr("d"), m, style, warnings)
  else:
    warnings.add "Unsupported <" & name & "> element was skipped."

proc convert*(svgText: string): SvgResult =
  serial = 0
  let (svg, error) = parseSvg(svgText)
  if error.len > 0:
    raise newException(SvgError, jsTrim(error.splitWhitespace().join(" ")))
  if svg == nil or svg.local != "svg":
    raise newException(SvgError, "The input must contain an <svg> root element.")
  let view = splitNumbers(svg.attr("viewBox"))
  template at(k: int): float64 = (if k < view.len: view[k] else: NaN)
  let width = numv(svg.attr("width"), orD(at(2), 300))
  let height = numv(svg.attr("height"), orD(at(3), 150))
  let matrix = M(a: 1, d: 1, e: (if view.len == 4: -view[0] else: 0.0),
                 f: (if view.len == 4: -view[1] else: 0.0))
  var cells: seq[string]
  var warnings: seq[string]
  walk(svg, @[], false, matrix, cells, warnings)
  var kept: seq[string]
  for c in cells:
    if c.len > 0: kept.add c
  if kept.len == 0: raise newException(SvgError, "No supported editable SVG elements were found.")
  let xml = "<mxGraphModel><root><mxCell id=\"0\" /><mxCell id=\"1\" parent=\"0\" />" & kept.join("") &
    "</root></mxGraphModel>"
  let document = parse(xml)
  SvgResult(xml: xml, document: document, items: document["items"], width: width, height: height,
            warnings: warnings)
