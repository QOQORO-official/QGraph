## SVG previews for the shape palette (PixelShapeSvg).
##
## The sidebar is ordinary DOM and the classic inventory was drawn as SVG,
## which stays crisp at any device pixel ratio. Geometry mirrors the painter's
## traceNode so an entry and the shape it creates have the same outline. The
## elements are created one by one through qweb, exactly as the classic
## palette built them, so the resulting DOM is the same.

import std/[math, strutils]
import ../jsval, ../web/qweb, ../geometry
import jsutil, htmltree, stencilxml

const NS = "http://www.w3.org/2000/svg"
const XhtmlNS = "http://www.w3.org/1999/xhtml"

type Attr = (string, string)

proc n(k: string, v: float64): Attr = (k, jsStr(v))
proc s(k: string, v: string): Attr = (k, v)

proc svgEl(name: string, attrs: openArray[Attr] = []): Node =
  result = createElementNS(NS, name)
  for (k, v) in attrs: result.setAttribute(k, v)

type Pt2 = (float64, float64)

proc points(list: openArray[Pt2]): string =
  var parts: seq[string]
  for (x, y) in list: parts.add jsStr(x) & "," & jsStr(y)
  parts.join(" ")

proc f(x: float64): string = jsStr(x)

proc numOr(v: Val, d: float64): float64 =
  ## v == null ? d : Number(v)
  if nullish(v): d else: num(v)

proc safeHtml*(markup: string): string =
  let prepared = markup
  var cleaned = ""
  # Adjacent quoted-string separators ('  +  ') from old palette constants.
  var i = 0
  while i < prepared.len:
    if prepared[i] == '\'':
      var j = i + 1
      while j < prepared.len and prepared[j] in {' ', '\t', '\n', '\r'}: inc j
      if j < prepared.len and prepared[j] == '+':
        var k = j + 1
        while k < prepared.len and prepared[k] in {' ', '\t', '\n', '\r'}: inc k
        if k < prepared.len and prepared[k] == '\'':
          i = k + 1
          continue
    cleaned.add prepared[i]
    inc i
  cleaned = cleaned.replace("\\n", "<br>")
  let tree = parseHtml(cleaned)
  serializeChildren(sanitized(tree, ["script", "iframe", "object", "embed", "link", "meta", "base"]))

proc htmlValue(templ: Val, source: Val): string =
  if source != nil and source["value"].isStr:
    let v = source["value"].s
    var i = v.find('<')
    while i >= 0:
      let gt = v.find('>', i + 1)
      if gt < 0: break
      if gt > i + 1: return v
      i = v.find('<', i + 1)
  if templ["html"].isStr and templ["html"].s.len > 0: return templ["html"].s
  "\x00"

proc addHtmlLabel(group: Node, node: Val, templ: Val, markup: string) =
  let foreign = svgEl("foreignObject", [n("x", 0), n("y", 0), n("width", num(node["width"])),
                                        n("height", num(node["height"])), s("pointer-events", "none")])
  let divEl = createElementNS(XhtmlNS, "div")
  divEl.setAttribute("xmlns", XhtmlNS)
  divEl.setAttribute("class", "geShapeHtmlLabel")
  let va = if templ["verticalAlign"].isStr: templ["verticalAlign"].s else: ""
  let ta = if templ["textAlign"].isStr: templ["textAlign"].s else: ""
  let padding = jsMax(0, if nullish(templ["textPadding"]): 2.0 else: num(templ["textPadding"]))
  let fontSize = jsMax(9, jsNumOr(templ["fontSize"], 11.0))
  divEl.cssText = [
    "display:flex",
    "box-sizing:border-box",
    "width:100%",
    "height:100%",
    "overflow:hidden",
    "padding:" & f(padding) & "px",
    "align-items:" & (if va == "top": "flex-start" elif va == "bottom": "flex-end" else: "center"),
    "justify-content:" & (if ta == "left": "flex-start" elif ta == "right": "flex-end" else: "center"),
    "text-align:" & (if ta.len > 0: ta else: "center"),
    "font-family:" & (if truthy(templ["fontFamily"]): str(templ["fontFamily"]) else: "Arial, Helvetica, sans-serif"),
    "font-size:" & f(fontSize) & "px",
    "font-weight:" & (if truthy(templ["fontWeight"]): str(templ["fontWeight"]) else: "400"),
    "line-height:1.2",
    "color:" & (if truthy(templ["textColor"]): str(templ["textColor"]) else: "#172033"),
    "background:transparent"].join(";")
  let content = createElementNS(XhtmlNS, "div")
  content.cssText = "box-sizing:border-box;max-width:100%;max-height:100%;overflow:hidden;"
  content.html = safeHtml(markup)
  divEl.appendChild(content)
  foreign.appendChild(divEl)
  group.appendChild(foreign)

proc escapeText(value: string): string =
  for c in value:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add c

proc addVisualScriptCard(group: Node, node: Val, templ: Val) =
  let vsType = if templ["vsType"].isStr: templ["vsType"].s else: ""
  let indicator = case vsType
    of "input", "process": "#7b8794"
    of "condition": "#d97706"
    of "for": "#ea580c"
    of "while": "#7c3aed"
    of "output": "#16a34a"
    of "function": "#0891b2"
    of "http": "#0d9488"
    of "delay": "#ca8a04"
    of "qnoteTemplate": "#7c3aed"
    of "sheetTemplate": "#0e7490"
    of "llm": "#e11d48"
    of "uiLLM": "#06b6d4"
    of "slack": "#611f69"
    else: "#7b8794"
  let w = num(node["width"])
  let h = num(node["height"])
  let headerHeight = jsMin(30, h)
  let lampY = headerHeight / 2
  group.appendChild svgEl("circle", [n("cx", 12), n("cy", lampY), n("r", 4.5), s("fill", indicator),
    s("stroke", "#6b7280"), n("stroke-width", 1), s("vector-effect", "non-scaling-stroke")])
  group.appendChild svgEl("circle", [n("cx", jsMax(12, w - 12)), n("cy", lampY), n("r", 4),
    s("fill", "#22c55e"), s("stroke", "#6b7280"), n("stroke-width", 1),
    s("vector-effect", "non-scaling-stroke")])
  let htmlStyle = clone(templ)
  htmlStyle["textPadding"] = jnum(0)
  htmlStyle["textAlign"] = jstr("left")
  htmlStyle["verticalAlign"] = jstr("top")
  htmlStyle["fontSize"] = jnum(12)
  htmlStyle["fontWeight"] = jnum(700)
  htmlStyle["textColor"] = jstr("#222222")
  let label = if truthy(templ["text"]): str(templ["text"]) elif vsType.len > 0: vsType else: "Script"
  addHtmlLabel(group, node, htmlStyle,
    "<div style=\"box-sizing:border-box;height:" & f(headerHeight) &
    "px;padding:7px 24px 0 25px;white-space:nowrap;overflow:hidden;" &
    "text-overflow:ellipsis;line-height:16px;\">" & escapeText(label) & "</div>")

proc isStrokeOnly(shape: string): bool =
  shape in ["text", "actor", "umlDestroy", "requiredInterface", "curlyBracket", "crossbar", "line"]

proc outline(node: Val): Node =
  let w = num(node["width"])
  let h = num(node["height"])
  let shape = if truthy(node["shape"]): str(node["shape"]) else: "rect"
  let radius = numOr(node["radius"], 4)
  case shape
  of "ellipse", "tapeData", "orEllipse", "sumEllipse", "lineEllipse", "umlEntity":
    svgEl("ellipse", [n("cx", w / 2), n("cy", h / 2), n("rx", w / 2), n("ry", h / 2)])
  of "diamond":
    svgEl("polygon", [s("points", points([(w / 2, 0.0), (w, h / 2), (w / 2, h), (0.0, h / 2)]))])
  of "triangle":
    svgEl("polygon", [s("points", points([(w / 2, 0.0), (w, h), (0.0, h)]))])
  of "hexagon":
    svgEl("polygon", [s("points", points([(w * 0.22, 0.0), (w * 0.78, 0.0), (w, h / 2),
      (w * 0.78, h), (w * 0.22, h), (0.0, h / 2)]))])
  of "parallelogram":
    svgEl("polygon", [s("points", points([(w * 0.22, 0.0), (w, 0.0), (w * 0.78, h), (0.0, h)]))])
  of "trapezoid":
    svgEl("polygon", [s("points", points([(w * 0.2, 0.0), (w * 0.8, 0.0), (w, h), (0.0, h)]))])
  of "step", "chevron":
    svgEl("polygon", [s("points", points([(0.0, 0.0), (w * 0.78, 0.0), (w, h / 2), (w * 0.78, h),
      (0.0, h), (w * 0.22, h / 2)]))])
  of "isoCube2":
    let isoAngle = jsMax(0.01, jsMin(94, numOr(node["isoAngle"], 15))) * PI / 200
    let isoHeight = jsMin(w * tan(isoAngle), h * 0.5)
    svgEl("polygon", [s("points", points([(w / 2, 0.0), (w, isoHeight), (w, h - isoHeight), (w / 2, h),
      (0.0, h - isoHeight), (0.0, isoHeight)]))])
  of "isoRectangle":
    svgEl("polygon", [s("points", points([(0.0, h / 2), (w / 2, 0.0), (w, h / 2), (w / 2, h)]))])
  of "line":
    let dir = if node["direction"].isStr: node["direction"].s else: ""
    if dir == "south" or dir == "north":
      svgEl("line", [n("x1", w / 2), n("y1", 0), n("x2", w / 2), n("y2", h)])
    else:
      svgEl("line", [n("x1", 0), n("y1", h / 2), n("x2", w), n("y2", h / 2)])
  of "curlyBracket":
    svgEl("path", [s("d", "M " & f(w) & " 0 C 0 0 " & f(w) & " " & f(h * 0.38) & " 0 " & f(h / 2) &
      " C " & f(w) & " " & f(h * 0.62) & " 0 " & f(h) & " " & f(w) & " " & f(h))])
  of "crossbar":
    svgEl("path", [s("d", "M 0 " & f(h / 2) & " L " & f(w) & " " & f(h / 2) & " M 0 0 L 0 " & f(h) &
      " M " & f(w) & " 0 L " & f(w) & " " & f(h))])
  of "plus":
    svgEl("polygon", [s("points", points([(w * 0.35, 0.0), (w * 0.65, 0.0), (w * 0.65, h * 0.35),
      (w, h * 0.35), (w, h * 0.65), (w * 0.65, h * 0.65), (w * 0.65, h), (w * 0.35, h),
      (w * 0.35, h * 0.65), (0.0, h * 0.65), (0.0, h * 0.35), (w * 0.35, h * 0.35)]))])
  of "note":
    let fold = jsMin(w, h) * 0.28
    svgEl("path", [s("d", "M 0 0 L " & f(w - fold) & " 0 L " & f(w) & " " & f(fold) & " L " & f(w) &
      " " & f(h) & " L 0 " & f(h) & " Z M " & f(w - fold) & " 0 L " & f(w - fold) & " " & f(fold) &
      " L " & f(w) & " " & f(fold))])
  of "cylinder":
    let ry = h * jsMax(0, jsMin(0.5, numOr(node["shapeSize"], 0.1875)))
    svgEl("path", [s("d", "M 0 " & f(ry) & " A " & f(w / 2) & " " & f(ry) & " 0 0 1 " & f(w) & " " & f(ry) &
      " L " & f(w) & " " & f(h - ry) & " A " & f(w / 2) & " " & f(ry) & " 0 0 1 0 " & f(h - ry) &
      " Z M 0 " & f(ry) & " A " & f(w / 2) & " " & f(ry) & " 0 0 0 " & f(w) & " " & f(ry))])
  of "document":
    svgEl("path", [s("d", "M 0 0 L " & f(w) & " 0 L " & f(w) & " " & f(h * 0.82) & " C " & f(w * 0.75) &
      " " & f(h) & " " & f(w * 0.25) & " " & f(h * 0.64) & " 0 " & f(h * 0.82) & " Z")])
  of "tape":
    svgEl("path", [s("d", "M 0 " & f(h * 0.18) & " C " & f(w * 0.25) & " " & f(-h * 0.1) & " " &
      f(w * 0.75) & " " & f(h * 0.4) & " " & f(w) & " " & f(h * 0.18) & " L " & f(w) & " " & f(h * 0.82) &
      " C " & f(w * 0.75) & " " & f(h * 1.1) & " " & f(w * 0.25) & " " & f(h * 0.6) & " 0 " & f(h * 0.82) & " Z")])
  of "cube":
    let d = jsMin(w, h) * 0.22
    svgEl("path", [s("d", "M 0 " & f(d) & " L " & f(d) & " 0 L " & f(w) & " 0 L " & f(w) & " " & f(h - d) &
      " L " & f(w - d) & " " & f(h) & " L 0 " & f(h) & " Z M 0 " & f(d) & " L " & f(w - d) & " " & f(d) &
      " L " & f(w) & " 0 M " & f(w - d) & " " & f(d) & " L " & f(w - d) & " " & f(h))])
  of "cloud":
    svgEl("path", [s("d", "M " & f(w * 0.25) & " " & f(h * 0.8) &
      " A " & f(w * 0.18) & " " & f(h * 0.22) & " 0 0 1 " & f(w * 0.18) & " " & f(h * 0.45) &
      " A " & f(w * 0.2) & " " & f(h * 0.26) & " 0 0 1 " & f(w * 0.45) & " " & f(h * 0.22) &
      " A " & f(w * 0.22) & " " & f(h * 0.25) & " 0 0 1 " & f(w * 0.82) & " " & f(h * 0.38) &
      " A " & f(w * 0.16) & " " & f(h * 0.22) & " 0 0 1 " & f(w * 0.78) & " " & f(h * 0.8) & " Z")])
  of "actor":
    let head = jsMin(w, h) * 0.22
    svgEl("path", [s("d", "M " & f(w / 2) & " " & f(head) & " m " & f(-head) & " 0 a " & f(head) & " " &
      f(head) & " 0 1 0 " & f(head * 2) & " 0 a " & f(head) & " " & f(head) & " 0 1 0 " & f(-head * 2) & " 0 " &
      "M " & f(w / 2) & " " & f(head * 2) & " L " & f(w / 2) & " " & f(h * 0.68) &
      " M " & f(w * 0.12) & " " & f(h * 0.42) & " L " & f(w * 0.88) & " " & f(h * 0.42) &
      " M " & f(w / 2) & " " & f(h * 0.68) & " L " & f(w * 0.15) & " " & f(h) &
      " M " & f(w / 2) & " " & f(h * 0.68) & " L " & f(w * 0.85) & " " & f(h))])
  of "speech":
    let tail = h * 0.22
    svgEl("path", [s("d", "M 0 0 L " & f(w) & " 0 L " & f(w) & " " & f(h - tail) & " L " & f(w * 0.32) &
      " " & f(h - tail) & " L " & f(w * 0.18) & " " & f(h) & " L " & f(w * 0.2) & " " & f(h - tail) &
      " L 0 " & f(h - tail) & " Z")])
  of "manualInput":
    let manualSize = jsMin(h, numOr(node["shapeSize"], 30))
    svgEl("polygon", [s("points", "0," & f(manualSize) & " " & f(w) & ",0 " & f(w) & "," & f(h) & " 0," & f(h))])
  of "loopLimit":
    let loopSize = jsMax(0, jsMin(w / 2, numOr(node["shapeSize"], 20)))
    let loopDrop = jsMax(0, jsMin(h, numOr(node["dy"], loopSize * 0.8)))
    svgEl("polygon", [s("points", f(loopSize) & ",0 " & f(w - loopSize) & ",0 " & f(w) & "," & f(loopDrop) &
      " " & f(w) & "," & f(h) & " 0," & f(h) & " 0," & f(loopDrop))])
  of "offPageConnector":
    let cs = h * jsMax(0, jsMin(1, numOr(node["shapeSize"], 3 / 8)))
    svgEl("polygon", [s("points", "0,0 " & f(w) & ",0 " & f(w) & "," & f(h - cs) & " " & f(w / 2) & "," &
      f(h) & " 0," & f(h - cs))])
  of "display":
    let dx = jsMin(w, h / 2)
    let ds = jsMin(w - dx, jsMax(0, numOr(node["shapeSize"], 0.25)) * w)
    svgEl("path", [s("d", "M 0 " & f(h / 2) & " L " & f(ds) & " 0 L " & f(w - dx) & " 0 Q " & f(w) & " 0 " &
      f(w) & " " & f(h / 2) & " Q " & f(w) & " " & f(h) & " " & f(w - dx) & " " & f(h) & " L " & f(ds) &
      " " & f(h) & " Z")])
  of "singleArrow", "doubleArrow":
    let direction = if truthy(node["direction"]): str(node["direction"]) else: "east"
    let vertical = direction == "north" or direction == "south"
    let aw = if vertical: h else: w
    let ah = if vertical: w else: h
    let shaft = ah * jsMax(0, jsMin(1, numOr(node["arrowWidth"], 0.3)))
    let tip = aw * jsMax(0, jsMin(1, numOr(node["arrowSize"], 0.2)))
    let at = (ah - shaft) / 2
    let ab = at + shaft
    proc ap(u, v: float64): string =
      if direction == "west": f(w - u) & "," & f(h - v)
      elif direction == "north": f(v) & "," & f(h - u)
      elif direction == "south": f(w - v) & "," & f(u)
      else: f(u) & "," & f(v)
    let arrow = if shape == "singleArrow":
      @[ap(0, at), ap(aw - tip, at), ap(aw - tip, 0), ap(aw, ah / 2), ap(aw - tip, ah), ap(aw - tip, ab), ap(0, ab)]
    else:
      @[ap(0, ah / 2), ap(tip, 0), ap(tip, at), ap(aw - tip, at), ap(aw - tip, 0), ap(aw, ah / 2),
        ap(aw - tip, ah), ap(aw - tip, ab), ap(tip, ab), ap(tip, ah)]
    svgEl("polygon", [s("points", arrow.join(" "))])
  of "cross":
    let cs = jsMin(w, h) * jsMax(0, jsMin(1, numOr(node["shapeSize"], 0.2)))
    let ct = (h - cs) / 2
    let cb = ct + cs
    let cl = (w - cs) / 2
    let cr = cl + cs
    svgEl("polygon", [s("points", "0," & f(ct) & " " & f(cl) & "," & f(ct) & " " & f(cl) & ",0 " & f(cr) &
      ",0 " & f(cr) & "," & f(ct) & " " & f(w) & "," & f(ct) & " " & f(w) & "," & f(cb) & " " & f(cr) & "," &
      f(cb) & " " & f(cr) & "," & f(h) & " " & f(cl) & "," & f(h) & " " & f(cl) & "," & f(cb) & " 0," & f(cb))])
  of "corner", "tee":
    let sd = jsMin(jsMin(w, h), numOr(node["shapeSize"], 20))
    if shape == "corner":
      svgEl("polygon", [s("points", "0,0 " & f(w) & ",0 " & f(w) & "," & f(sd) & " " & f(sd) & "," & f(sd) &
        " " & f(sd) & "," & f(h) & " 0," & f(h))])
    else:
      svgEl("polygon", [s("points", "0,0 " & f(w) & ",0 " & f(w) & "," & f(sd) & " " & f(w / 2 + sd / 2) &
        "," & f(sd) & " " & f(w / 2 + sd / 2) & "," & f(h) & " " & f(w / 2 - sd / 2) & "," & f(h) & " " &
        f(w / 2 - sd / 2) & "," & f(sd) & " 0," & f(sd))])
  of "sortShape":
    svgEl("polygon", [s("points", f(w / 2) & ",0 " & f(w) & "," & f(h / 2) & " " & f(w / 2) & "," & f(h) &
      " 0," & f(h / 2))])
  of "collate":
    svgEl("path", [s("d", "M 0 0 L " & f(w) & " 0 L " & f(w / 2) & " " & f(h / 2) & " Z M 0 " & f(h) &
      " L " & f(w) & " " & f(h) & " L " & f(w / 2) & " " & f(h / 2) & " Z")])
  of "datastore":
    let sw = jsNumOr(node["strokeWidth"], 1.0)
    let cap = jsMin(h / 2, jsRound(h / 8) + sw - 1)
    svgEl("path", [s("d", "M 0 " & f(cap) & " C 0 " & f(-cap / 3) & " " & f(w) & " " & f(-cap / 3) & " " &
      f(w) & " " & f(cap) & " L " & f(w) & " " & f(h - cap) & " C " & f(w) & " " & f(h + cap / 3) & " 0 " &
      f(h + cap / 3) & " 0 " & f(h - cap) & " Z")])
  of "switch":
    svgEl("path", [s("d", "M 0 0 Q " & f(w / 2) & " " & f(h / 2) & " " & f(w) & " 0 Q " & f(w / 2) & " " &
      f(h / 2) & " " & f(w) & " " & f(h) & " Q " & f(w / 2) & " " & f(h / 2) & " 0 " & f(h) &
      " Q " & f(w / 2) & " " & f(h / 2) & " 0 0 Z")])
  of "partialRectangle":
    svgEl("rect", [n("x", 0), n("y", 0), n("width", w), n("height", h), s("stroke", "none")])
  of "delay":
    let dx = jsMin(w, h / 2)
    svgEl("path", [s("d", "M 0 0 L " & f(w - dx) & " 0 Q " & f(w) & " 0 " & f(w) & " " & f(h / 2) &
      " Q " & f(w) & " " & f(h) & " " & f(w - dx) & " " & f(h) & " L 0 " & f(h) & " Z")])
  of "umlBoundary":
    svgEl("ellipse", [n("cx", w / 6 + (w * 5 / 6) / 2), n("cy", h / 2), n("rx", (w * 5 / 6) / 2), n("ry", h / 2)])
  of "umlControl":
    svgEl("ellipse", [n("cx", w / 2), n("cy", h / 8 + (h * 7 / 8) / 2), n("rx", w / 2), n("ry", (h * 7 / 8) / 2)])
  of "umlDestroy":
    svgEl("path", [s("d", "M " & f(w) & " 0 L 0 " & f(h) & " M 0 0 L " & f(w) & " " & f(h))])
  of "umlLifeline":
    let head = jsMax(0, jsMin(h, numOr(node["shapeSize"], 40)))
    svgEl("rect", [n("x", 0), n("y", 0), n("width", w), n("height", head)])
  of "umlFrame", "message":
    svgEl("rect", [n("x", 0), n("y", 0), n("width", w), n("height", h)])
  of "umlState":
    let arc = numOr(node["radius"], 10)
    svgEl("rect", [n("x", 0), n("y", 0), n("width", w), n("height", h), n("rx", arc), n("ry", arc)])
  of "module", "component":
    let jw = jsNumOr(node["jettyWidth"], (if shape == "module": 20.0 else: 32.0))
    let jh = jsNumOr(node["jettyHeight"], 12.0)
    let jx = jw / 2
    let ja = if shape == "module": jsMin(jh, h - jh) else: 0.3 * h - jh / 2
    let jb = if shape == "module": jsMin(ja + 2 * jh, h - jh) else: 0.7 * h - jh / 2
    svgEl("polygon", [s("points", points([(jx, 0.0), (w, 0.0), (w, h), (jx, h), (jx, jb + jh), (0.0, jb + jh),
      (0.0, jb), (jx, jb), (jx, ja + jh), (0.0, ja + jh), (0.0, ja), (jx, ja)]))])
  of "folder":
    let tabW = jsMax(0, jsMin(w, numOr(node["tabWidth"], 60)))
    let tabH = jsMax(0, jsMin(h, numOr(node["tabHeight"], 20)))
    if node.eqs("tabPosition", "left"):
      svgEl("polygon", [s("points", points([(0.0, 0.0), (tabW, 0.0), (tabW, tabH), (w, tabH), (w, h), (0.0, h)]))])
    else:
      svgEl("polygon", [s("points", points([(w - tabW, 0.0), (w, 0.0), (w, h), (0.0, h), (0.0, tabH),
        (w - tabW, tabH)]))])
  of "providedRequiredInterface":
    let pri = numOr(node["inset"], 2) + numOr(node["strokeWidth"], 1)
    let priW = jsMax(0, w - 2 * pri)
    let priH = jsMax(0, h - 2 * pri)
    svgEl("ellipse", [n("cx", priW / 2), n("cy", pri + priH / 2), n("rx", priW / 2), n("ry", priH / 2)])
  of "requiredInterface":
    svgEl("path", [s("d", "M 0 0 Q " & f(w) & " 0 " & f(w) & " " & f(h / 2) & " Q " & f(w) & " " & f(h) &
      " 0 " & f(h))])
  of "endState", "startState":
    let si = if shape == "endState": jsMin(4, jsMin(w / 5, h / 5)) else: 0.0
    svgEl("ellipse", [n("cx", w / 2), n("cy", h / 2), n("rx", jsMax(0, w / 2 - si)), n("ry", jsMax(0, h / 2 - si))])
  of "parallelMarker":
    let bw = w / 5
    svgEl("path", [s("d", "M 0 0 h " & f(bw) & " v " & f(h) & " h " & f(-bw) & " Z " &
      "M " & f(2 * bw) & " 0 h " & f(bw) & " v " & f(h) & " h " & f(-bw) & " Z " &
      "M " & f(4 * bw) & " 0 h " & f(bw) & " v " & f(h) & " h " & f(-bw) & " Z")])
  of "card":
    let cardSize = jsMax(0, jsMin(w, numOr(node["shapeSize"], 30)))
    let cardDrop = jsMax(0, jsMin(h, numOr(node["dy"], cardSize)))
    svgEl("polygon", [s("points", f(cardSize) & ",0 " & f(w) & ",0 " & f(w) & "," & f(h) & " 0," & f(h) &
      " 0," & f(cardDrop))])
  of "dataStorage":
    let ss = w * jsMax(0, jsMin(1, numOr(node["shapeSize"], 0.1)))
    svgEl("path", [s("d", "M " & f(ss) & " 0 L " & f(w) & " 0" & " Q " & f(w - ss * 2) & " " & f(h / 2) & " " &
      f(w) & " " & f(h) & " L " & f(ss) & " " & f(h) & " Q " & f(-ss) & " " & f(h / 2) & " " & f(ss) & " 0 Z")])
  of "xor", "or":
    svgEl("path", [s("d", "M 0 0 Q " & f(w) & " 0 " & f(w) & " " & f(h / 2) & " Q " & f(w) & " " & f(h) &
      " 0 " & f(h) & (if shape == "xor": " Q " & f(w / 2) & " " & f(h / 2) & " 0 0" else: "") & " Z")])
  of "text": nilNode
  else:
    svgEl("rect", [n("x", 0), n("y", 0), n("width", w), n("height", h),
                   n("rx", jsMax(0, radius)), n("ry", jsMax(0, radius))])

proc decorations(node: Val): seq[(Node, bool)] =
  ## Extra strokes on top of the outline; the flag marks the ones that chose
  ## their own fill.
  template emit(x: Node) =
    result.add (x, false)
  template emitFilled(x: Node) =
    result.add (x, true)
  let w = num(node["width"])
  let h = num(node["height"])
  let shape = if node["shape"].isStr: node["shape"].s else: ""
  if shape == "table":
    let rows = int(jsMax(1, jsNumOr(node["rows"], 3.0)))
    let columns = int(jsMax(1, jsNumOr(node["columns"], 3.0)))
    let title = if nullish(node["tableTitle"]): 0.0
                else: jsMax(0, jsMin(h, jsNumOr(node["tableTitleHeight"], 30.0)))
    let available = h - title
    var rowWeights, columnWeights: seq[float64]
    if node["rowWeights"].isArr and node["rowWeights"].len == rows:
      for v in node["rowWeights"]: rowWeights.add num(v)
    else:
      for i in 0 ..< rows: rowWeights.add 1
    if node["columnWeights"].isArr and node["columnWeights"].len == columns:
      for v in node["columnWeights"]: columnWeights.add num(v)
    else:
      for i in 0 ..< columns: columnWeights.add 1
    var rowTotal = 0.0
    for v in rowWeights: rowTotal += (if v != v: 0.0 else: v)
    if rowTotal == 0 or rowTotal != rowTotal: rowTotal = float64(rows)
    var columnTotal = 0.0
    for v in columnWeights: columnTotal += (if v != v: 0.0 else: v)
    if columnTotal == 0 or columnTotal != columnTotal: columnTotal = float64(columns)
    if title > 0: emit svgEl("line", [n("x1", 0), n("y1", title), n("x2", w), n("y2", title)])
    var rowY = title
    for r in 0 ..< rows - 1:
      rowY += (if truthy(node["fixedRows"]): (if rowWeights[r] != rowWeights[r] or rowWeights[r] == 0: 1.0 else: rowWeights[r])
               else: available * rowWeights[r] / rowTotal)
      if not node["rowLines"].isFalse or (truthy(node["firstRowLine"]) and r == 0):
        emit svgEl("line", [n("x1", 0), n("y1", rowY), n("x2", w), n("y2", rowY)])
    var columnX = 0.0
    let contentBottom = if truthy(node["fixedRows"]): jsMin(h, title + rowTotal) else: h
    for c in 0 ..< columns - 1:
      columnX += w * columnWeights[c] / columnTotal
      emit svgEl("line", [n("x1", columnX), n("y1", title), n("x2", columnX), n("y2", contentBottom)])

  if truthy(node["double"]) and (shape == "rect" or shape == "ellipse"):
    let inset = jsMin(5, jsMin(w, h) / 6)
    if shape == "ellipse":
      emit svgEl("ellipse", [n("cx", w / 2), n("cy", h / 2), n("rx", jsMax(0, w / 2 - inset)),
                                   n("ry", jsMax(0, h / 2 - inset))])
    else:
      let r = jsNumOr(node["radius"], 0)
      emit svgEl("rect", [n("x", inset), n("y", inset), n("width", jsMax(0, w - 2 * inset)),
        n("height", jsMax(0, h - 2 * inset)), n("rx", jsMax(0, r - inset / 2)), n("ry", jsMax(0, r - inset / 2))])

  case shape
  of "swimlane":
    let header = jsMin(jsNumOr(node["headerHeight"], 26.0), h)
    emit svgEl("line", [n("x1", 0), n("y1", header), n("x2", w), n("y2", header)])
  of "tapeData":
    emit svgEl("line", [n("x1", w / 2), n("y1", h), n("x2", w), n("y2", h)])
  of "isoCube2":
    let angle = jsMax(0.01, jsMin(94, numOr(node["isoAngle"], 15))) * PI / 200
    let ch = jsMin(w * tan(angle), h * 0.5)
    emit svgEl("path", [s("d", "M 0 " & f(ch) & " L " & f(w / 2) & " " & f(2 * ch) & " L " & f(w) & " " &
      f(ch) & " M " & f(w / 2) & " " & f(2 * ch) & " L " & f(w / 2) & " " & f(h))])
  of "orEllipse":
    emit svgEl("line", [n("x1", 0), n("y1", h / 2), n("x2", w), n("y2", h / 2)])
    emit svgEl("line", [n("x1", w / 2), n("y1", 0), n("x2", w / 2), n("y2", h)])
  of "sumEllipse":
    emit svgEl("line", [n("x1", w * 0.145), n("y1", h * 0.145), n("x2", w * 0.855), n("y2", h * 0.855)])
    emit svgEl("line", [n("x1", w * 0.855), n("y1", h * 0.145), n("x2", w * 0.145), n("y2", h * 0.855)])
  of "lineEllipse":
    if node.eqs("line", "vertical"):
      emit svgEl("line", [n("x1", w / 2), n("y1", 0), n("x2", w / 2), n("y2", h)])
    else:
      emit svgEl("line", [n("x1", 0), n("y1", h / 2), n("x2", w), n("y2", h / 2)])
  of "sortShape":
    emit svgEl("line", [n("x1", 0), n("y1", h / 2), n("x2", w), n("y2", h / 2)])
  of "datastore":
    let sw = jsNumOr(node["strokeWidth"], 1.0)
    let cap = jsMin(h / 2, jsRound(h / 8) + sw - 1)
    for row in 1 .. 3:
      let yy = cap * float64(row) / 2
      emit svgEl("path", [s("d", "M 0 " & f(yy) & " C 0 " & f(yy + cap) & " " & f(w) & " " & f(yy + cap) &
        " " & f(w) & " " & f(yy))])
  of "umlBoundary":
    emit svgEl("line", [n("x1", 0), n("y1", h / 4), n("x2", 0), n("y2", h * 3 / 4)])
    emit svgEl("line", [n("x1", 0), n("y1", h / 2), n("x2", w / 6), n("y2", h / 2)])
  of "umlEntity":
    emit svgEl("line", [n("x1", w / 8), n("y1", h), n("x2", w * 7 / 8), n("y2", h)])
  of "umlControl":
    emit svgEl("line", [n("x1", w * 3 / 8), n("y1", h / 8 * 1.1), n("x2", w * 5 / 8), n("y2", 0)])
    emit svgEl("line", [n("x1", w * 3 / 8), n("y1", h / 8 * 1.1), n("x2", w * 5 / 8), n("y2", h / 4)])
  of "umlLifeline":
    let head = jsMax(0, jsMin(h, numOr(node["shapeSize"], 40)))
    if head < h:
      emit svgEl("line", [n("x1", w / 2), n("y1", head), n("x2", w / 2), n("y2", h),
                                s("stroke-dasharray", "4 4")])
  of "umlFrame":
    let fw = jsMin(w, jsMax(10, numOr(node["frameWidth"], 60)))
    let fh = jsMin(h, jsMax(15, numOr(node["frameHeight"], 30)))
    emit svgEl("path", [s("d", "M 0 0 L " & f(fw) & " 0 L " & f(fw) & " " & f(jsMax(0, fh - 15)) &
      " L " & f(jsMax(0, fw - 10)) & " " & f(fh) & " L 0 " & f(fh))])
  of "module", "component":
    let mjw = jsNumOr(node["jettyWidth"], (if shape == "module": 20.0 else: 32.0))
    let mjh = jsNumOr(node["jettyHeight"], 12.0)
    let mjx = mjw / 2
    let mja = if shape == "module": jsMin(mjh, h - mjh) else: 0.3 * h - mjh / 2
    let mjb = if shape == "module": jsMin(mja + 2 * mjh, h - mjh) else: 0.7 * h - mjh / 2
    let fill = if truthy(node["fill"]): str(node["fill"]) else: "#ffffff"
    emitFilled svgEl("rect", [n("x", 0), n("y", mja), n("width", mjx), n("height", mjh), s("fill", fill)])
    emitFilled svgEl("rect", [n("x", 0), n("y", mjb), n("width", mjx), n("height", mjh), s("fill", fill)])
  of "providedRequiredInterface":
    emit svgEl("path", [s("d", "M " & f(w / 2) & " 0 Q " & f(w) & " 0 " & f(w) & " " & f(h / 2) &
      " Q " & f(w) & " " & f(h) & " " & f(w / 2) & " " & f(h))])
  of "endState":
    emit svgEl("ellipse", [n("cx", w / 2), n("cy", h / 2), n("rx", w / 2), n("ry", h / 2)])
  of "message":
    emit svgEl("path", [s("d", "M 0 0 L " & f(w / 2) & " " & f(h / 2) & " L " & f(w) & " 0")])
  of "process":
    let size = num(node["shapeSize"])
    let inset = if nullish(node["shapeSize"]): w * 0.1
                elif size > 1: jsMin(w / 2, size)
                else: w * jsMax(0, jsMin(0.5, size))
    emit svgEl("line", [n("x1", inset), n("y1", 0), n("x2", inset), n("y2", h)])
    emit svgEl("line", [n("x1", w - inset), n("y1", 0), n("x2", w - inset), n("y2", h)])
  of "internalStorage":
    let sdx = jsMax(0, jsMin(w, numOr(node["dx"], 20)))
    let sdy = jsMax(0, jsMin(h, numOr(node["dy"], 20)))
    emit svgEl("line", [n("x1", 0), n("y1", sdy), n("x2", w), n("y2", sdy)])
    emit svgEl("line", [n("x1", sdx), n("y1", 0), n("x2", sdx), n("y2", h)])
  of "partialRectangle":
    if not node["top"].isFalse: emit svgEl("line", [n("x1", 0), n("y1", 0), n("x2", w), n("y2", 0)])
    if not node["right"].isFalse: emit svgEl("line", [n("x1", w), n("y1", 0), n("x2", w), n("y2", h)])
    if not node["bottom"].isFalse: emit svgEl("line", [n("x1", w), n("y1", h), n("x2", 0), n("y2", h)])
    if not node["left"].isFalse: emit svgEl("line", [n("x1", 0), n("y1", h), n("x2", 0), n("y2", 0)])
  else: discard

proc parseWidth(v: Val): float64 =
  ## parseFloat(op.width) || 1
  let w = jsParseFloat(if nullish(v): "" else: str(v))
  if w != w or w == 0: 1.0 else: w

proc stencilPaths(node: Val, stroke, fill: string): Node =
  let stencil = program(if node["stencil"].isStr: node["stencil"].s else: "")
  if stencil == nil: return nilNode
  result = svgEl("g")
  var scaleX = num(node["width"]) / num(stencil["w"])
  var scaleY = num(node["height"]) / num(stencil["h"])
  var offsetX = 0.0
  var offsetY = 0.0
  if stencil.eqs("aspect", "fixed"):
    let uniform = jsMin(scaleX, scaleY)
    offsetX = (num(node["width"]) - num(stencil["w"]) * uniform) / 2
    offsetY = (num(node["height"]) - num(stencil["h"]) * uniform) / 2
    scaleX = uniform
    scaleY = uniform
  result.setAttribute("transform", "translate(" & f(offsetX) & "," & f(offsetY) & ") scale(" & f(scaleX) &
    "," & f(scaleY) & ")")
  let nodeStroke = jsNumOr(node["strokeWidth"], 1.0)
  type State = object
    fill, stroke: string
    strokeWidth, alpha, miterLimit: float64
    dashed: bool
    dashPattern: seq[string]
    hasPattern: bool
    lineJoin, lineCap: string
  var current = State(fill: fill, stroke: stroke, strokeWidth: nodeStroke, alpha: 1,
                      lineJoin: "miter", lineCap: "butt", miterLimit: 10)
  var stack: seq[State]
  var d = ""
  let group = result
  proc paint(kind: string) =
    var attrs: seq[Attr] = @[s("d", jsTrim(d)),
      s("fill", if kind == "stroke": "none" else: current.fill),
      s("stroke", if kind == "fill": "none" else: current.stroke),
      n("stroke-width", current.strokeWidth), s("stroke-linejoin", current.lineJoin),
      s("stroke-linecap", current.lineCap), n("stroke-miterlimit", current.miterLimit),
      n("opacity", current.alpha), s("vector-effect", "non-scaling-stroke")]
    if current.dashed:
      attrs.add s("stroke-dasharray", if current.hasPattern: current.dashPattern.join(" ") else: "4 4")
    group.appendChild svgEl("path", attrs)
  let ops = newArr()
  for o in stencil["background"]: ops.push o
  for o in stencil["foreground"]: ops.push o
  for op in ops:
    let kind = str(op["op"])
    case kind
    of "begin": d = ""
    of "move": d.add "M " & str(op["x"]) & " " & str(op["y"]) & " "
    of "line": d.add "L " & str(op["x"]) & " " & str(op["y"]) & " "
    of "quad": d.add "Q " & str(op["x1"]) & " " & str(op["y1"]) & " " & str(op["x"]) & " " & str(op["y"]) & " "
    of "curve":
      d.add "C " & str(op["x1"]) & " " & str(op["y1"]) & " " & str(op["x2"]) & " " & str(op["y2"]) & " " &
        str(op["x"]) & " " & str(op["y"]) & " "
    of "arc":
      d.add "A " & str(op["rx"]) & " " & str(op["ry"]) & " " &
        (if truthy(op["rotation"]): str(op["rotation"]) else: "0") & " " &
        (if truthy(op["large"]): "1" else: "0") & " " & (if truthy(op["sweep"]): "1" else: "0") & " " &
        str(op["x"]) & " " & str(op["y"]) & " "
    of "close": d.add "Z "
    of "rect":
      let x = num(op["x"])
      let y = num(op["y"])
      d = "M " & f(x) & " " & f(y) & " H " & f(x + num(op["w"])) & " V " & f(y + num(op["h"])) & " H " & f(x) & " Z"
    of "roundrect":
      let x = num(op["x"])
      let y = num(op["y"])
      let w = num(op["w"])
      let h = num(op["h"])
      var radius = jsMin(w, h) * (num(op["arcsize"]) / 100)
      radius = jsMin(jsMin(radius, w / 2), h / 2)
      d = "M " & f(x + radius) & " " & f(y) & " H " & f(x + w - radius) & " A " & f(radius) & " " & f(radius) &
        " 0 0 1 " & f(x + w) & " " & f(y + radius) & " V " & f(y + h - radius) & " A " & f(radius) & " " &
        f(radius) & " 0 0 1 " & f(x + w - radius) & " " & f(y + h) & " H " & f(x + radius) & " A " & f(radius) &
        " " & f(radius) & " 0 0 1 " & f(x) & " " & f(y + h - radius) & " V " & f(y + radius) & " A " &
        f(radius) & " " & f(radius) & " 0 0 1 " & f(x + radius) & " " & f(y) & " Z"
    of "ellipse":
      let rx = num(op["w"]) / 2
      let ry = num(op["h"]) / 2
      let cx = num(op["x"]) + rx
      let cy = num(op["y"]) + ry
      d = "M " & f(cx - rx) & " " & f(cy) & " A " & f(rx) & " " & f(ry) & " 0 1 0 " & f(cx + rx) & " " & f(cy) &
        " A " & f(rx) & " " & f(ry) & " 0 1 0 " & f(cx - rx) & " " & f(cy) & " Z"
    of "fillcolor": current.fill = if op.eqs("color", "none"): "none" else: str(op["color"])
    of "strokecolor": current.stroke = if op.eqs("color", "none"): "none" else: str(op["color"])
    of "strokewidth":
      current.strokeWidth = if op.eqs("width", "inherit"): nodeStroke
                            else: parseWidth(op["width"])
    of "alpha": current.alpha = num(op["alpha"])
    of "dashed": current.dashed = truthy(op["on"])
    of "dashpattern":
      current.dashPattern = @[]
      for v in op["pattern"]: current.dashPattern.add str(v)
      current.hasPattern = true
    of "linejoin": current.lineJoin = if nullish(op["join"]): "null" else: str(op["join"])
    of "linecap": current.lineCap = if nullish(op["cap"]): "null" else: str(op["cap"])
    of "miterlimit": current.miterLimit = num(op["limit"])
    of "save": stack.add current
    of "restore":
      if stack.len > 0: current = stack.pop()
    of "fill", "stroke", "fillstroke":
      if d.len > 0: paint(kind)
      d = ""
    else: discard

proc arrowMarker(defs: Node, id, colour, kind: string): string =
  if kind == "none": return ""
  let marker = svgEl("marker", [s("id", id), s("viewBox", "0 0 10 10"), n("refX", 9), n("refY", 5),
    n("markerWidth", 6), n("markerHeight", 6), s("orient", "auto-start-reverse")])
  if kind == "oval":
    marker.appendChild svgEl("circle", [n("cx", 5), n("cy", 5), n("r", 4), s("fill", colour)])
  elif kind == "diamond":
    marker.appendChild svgEl("polygon", [s("points", "0,5 5,0 10,5 5,10"), s("fill", colour)])
  elif kind == "open":
    marker.appendChild svgEl("path", [s("d", "M 0 0 L 10 5 L 0 10"), s("fill", "none"), s("stroke", colour),
      n("stroke-width", 1.6)])
  else:
    marker.appendChild svgEl("polygon", [s("points", "0,0 10,5 0,10"), s("fill", colour)])
  defs.appendChild marker
  id

var uid = 0

proc preview*(templ: Val, boxWidth0, boxHeight0: float64, source: Val = nil): Node =
  ## An <svg> preview of a template fitted into the compact sidebar box.
  if templ == nil: return nilNode
  let boxWidth = if boxWidth0 == 0: 32.0 else: boxWidth0
  let boxHeight = if boxHeight0 == 0: boxWidth else: boxHeight0
  let svg = svgEl("svg", [n("width", boxWidth), n("height", boxHeight),
    s("viewBox", "0 0 " & f(boxWidth) & " " & f(boxHeight)), s("xmlns", NS),
    s("shape-rendering", "geometricPrecision")])
  let defs = svgEl("defs")
  svg.appendChild defs
  let stroke = if truthy(templ["stroke"]) and not templ.eqs("stroke", "transparent"): str(templ["stroke"]) else: "#4a5564"
  let fill = if truthy(templ["fill"]) and not templ.eqs("fill", "transparent"): str(templ["fill"]) else: "none"
  const inset = 4.0

  if templ.eqs("type", "edge"):
    inc uid
    let id = "pm" & $uid
    let start = arrowMarker(defs, id & "s", stroke, if truthy(templ["startArrow"]): str(templ["startArrow"]) else: "none")
    let finish = arrowMarker(defs, id & "e", stroke, if truthy(templ["endArrow"]): str(templ["endArrow"]) else: "block")
    let sw = jsNumOr(templ["strokeWidth"], 1.5)
    let line = svgEl("line", [n("x1", inset), n("y1", boxHeight - inset), n("x2", boxWidth - inset), n("y2", inset),
      s("stroke", stroke), n("stroke-width", jsMax(1.2, jsMin(2.5, sw))), s("stroke-linecap", "round")])
    if truthy(templ["dashed"]):
      line.setAttribute("stroke-dasharray", if truthy(templ["dashPattern"]): arrJoin(templ["dashPattern"], " ") else: "4 3")
    if start.len > 0: line.setAttribute("marker-start", "url(#" & start & ")")
    if finish.len > 0: line.setAttribute("marker-end", "url(#" & finish & ")")
    svg.appendChild line
    return svg

  let node = newObj()
  node["shape"] = jstr(if truthy(templ["shape"]): str(templ["shape"]) else: "rect")
  node["stencil"] = templ["stencil"]
  node["width"] = jnum(jsMax(1, jsNumOr(templ["width"], 120.0)))
  node["height"] = jnum(jsMax(1, jsNumOr(templ["height"], 60.0)))
  for k in ["radius", "rows", "columns", "headerHeight", "direction", "line", "arrowSize", "arrowWidth",
            "shapeSize", "strokeWidth", "top", "right", "bottom", "left"]:
    node.put(k, templ.get(k))
  let nw = num(node["width"])
  let nh = num(node["height"])
  let scale = jsMin((boxWidth - inset * 2) / nw, (boxHeight - inset * 2) / nh)
  let group = svgEl("g", [s("transform", "translate(" & f((boxWidth - nw * scale) / 2) & "," &
    f((boxHeight - nh * scale) / 2) & ") scale(" & f(scale) & ")"), s("vector-effect", "non-scaling-stroke")])
  let shape = str(node["shape"])

  if shape == "stencil":
    let stencilGroup = stencilPaths(node, stroke, fill)
    if not stencilGroup.isNil:
      stencilGroup.setAttribute("vector-effect", "non-scaling-stroke")
      group.appendChild stencilGroup
      svg.appendChild group
      return svg

  if shape == "image":
    group.appendChild svgEl("rect", [n("x", 0), n("y", 0), n("width", nw), n("height", nh), s("fill", "#eef1f5"),
      s("stroke", "#b6bec9"), n("stroke-width", 1), s("vector-effect", "non-scaling-stroke")])
    group.appendChild svgEl("path", [s("d", "M " & f(nw * 0.15) & " " & f(nh * 0.75) & " L " & f(nw * 0.4) & " " &
      f(nh * 0.4) & " L " & f(nw * 0.6) & " " & f(nh * 0.62) & " L " & f(nw * 0.75) & " " & f(nh * 0.5) &
      " L " & f(nw * 0.88) & " " & f(nh * 0.75) & " Z"), s("fill", "#9aa4b2"), s("stroke", "none")])
    svg.appendChild group
    return svg

  let body = outline(node)
  if not body.isNil:
    body.setAttribute("fill", if shape == "parallelMarker": stroke elif isStrokeOnly(shape): "none" else: fill)
    body.setAttribute("stroke", if shape == "partialRectangle": "none" else: stroke)
    let sw = jsNumOr(templ["strokeWidth"], 1.5)
    body.setAttribute("stroke-width", f(jsMax(1, sw)))
    body.setAttribute("stroke-linejoin", "round")
    body.setAttribute("vector-effect", "non-scaling-stroke")
    group.appendChild body

  for (extra, hasFill) in decorations(node):
    extra.setAttribute("stroke", stroke)
    extra.setAttribute("stroke-width", "1")
    if not hasFill: extra.setAttribute("fill", "none")
    extra.setAttribute("vector-effect", "non-scaling-stroke")
    group.appendChild extra

  let markup = htmlValue(templ, source)
  let hasMarkup = markup != "\x00"
  if templ.eqs("kind", "visualScript"):
    addVisualScriptCard(group, node, templ)
  elif hasMarkup and (shape == "text" or shape == "html" or body.isNil):
    addHtmlLabel(group, node, templ, markup)
  elif shape == "text" or body.isNil:
    let label = svgEl("text", [n("x", nw / 2), n("y", nh / 2), s("text-anchor", "middle"),
      s("dominant-baseline", "central"), s("font-family", "Arial, Helvetica, sans-serif"),
      n("font-size", jsMin(nh * 0.8, nw * 0.5)),
      s("font-weight", if truthy(templ["fontWeight"]): str(templ["fontWeight"]) else: "400"),
      s("fill", if truthy(templ["textColor"]): str(templ["textColor"]) else: "#172033")])
    label.text = if truthy(templ["text"]): str(templ["text"])
                 elif source != nil and truthy(source["value"]): str(source["value"]) else: "Text"
    group.appendChild label
  svg.appendChild group
  svg
