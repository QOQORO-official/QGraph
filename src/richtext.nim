## Rich text model, canvas layout engine and HTML writer (PixelRichText).
##
## Model: { blocks: [ { type, indent, align, runs: [ { text, ...marks } ] } ] }
## where type is p|h1|h2|h3|ul|ol|pre and marks are bold, italic, underline,
## strike, script (sub|sup), color, size, family, link.
##
## Parsing HTML into the model needs the browser's HTML parser, so fromHtml
## lives on the page (web/js/RichText.js) and is reached through the host.

import std/[tables, strutils]
import jsval, canvas, host

const
  IndentStep* = 22.0
  MarkerGap = 8.0

proc blockScale(t: string): float64 =
  case t
  of "h1": 1.7
  of "h2": 1.4
  of "h3": 1.2
  else: 1.0

# ---------------------------------------------------------------- model --

proc emptyModel*(): Val =
  let b = newObj()
  b["type"] = jstr("p")
  b["indent"] = jnum(0)
  b["runs"] = newArr()
  result = newObj()
  result["blocks"] = newArr([b])

proc fromPlain*(text: string): Val =
  result = newObj()
  let blocks = newArr()
  for line in text.split('\n'):
    let b = newObj()
    b["type"] = jstr("p")
    b["indent"] = jnum(0)
    let runs = newArr()
    if line.len > 0:
      let r = newObj()
      r["text"] = jstr(line)
      runs.push r
    b["runs"] = runs
    blocks.push b
  result["blocks"] = blocks

proc fromPlainVal*(v: Val): Val =
  fromPlain(if nullish(v): "" else: str(v))

proc toPlain*(model: Val): string =
  if not truthy(model) or not model["blocks"].isArr: return ""
  var first = true
  for b in model["blocks"]:
    if not first: result.add '\n'
    first = false
    for run in b["runs"]:
      let t = run["text"]
      if truthy(t): result.add str(t)

proc isEmpty*(model: Val): bool = jsTrim(toPlain(model)) == ""

proc isPlain*(model: Val): bool =
  if not truthy(model) or not model["blocks"].isArr: return true
  for b in model["blocks"]:
    let t = b["type"]
    if truthy(t) and not isStrVal(t, "p"): return false
    if b.tr("indent"): return false
    if b.tr("align"): return false
    for run in b["runs"]:
      if run.tr("bold") or run.tr("italic") or run.tr("underline") or run.tr("strike") or
          run.tr("script") or run.tr("color") or run.tr("size") or run.tr("family") or
          run.tr("link"): return false
  true

# --------------------------------------------------------------- layout --

type
  RunStyle* = object
    size*: float64
    font*: string
    color*: string
    underline*, strike*: bool
    shift*: float64
  Segment* = object
    text*: string
    style*: RunStyle
    width*, x*: float64
  Line* = object
    segments*: seq[Segment]
    width*, size*, indent*, height*: float64
    align*: string
    marker*: string
    hasMarker*: bool
    blk*: Val
  Layout* = object
    lines*: seq[Line]
    width*, height*: float64

proc runStyle(run, blk, base: Val): RunStyle =
  let t = blk.st("type")
  let scale = blockScale(t)
  let runSize = num(run["size"])
  var size = (if runSize == runSize and runSize != 0: runSize else: base.fo("fontSize", 14)) * scale
  if run.tr("script"): size = size * 0.72
  let weight = if run.tr("bold") or t == "h1" or t == "h2" or t == "h3": "700"
               else: base.so("fontWeight", "500")
  var family = run.so("family", "")
  if family.len == 0 and t == "pre": family = "Consolas, monospace"
  if family.len == 0: family = base.so("fontFamily", "Arial, sans-serif")
  result.size = size
  result.font = (if run.tr("italic") or base.tr("italic"): "italic " else: "") &
    weight & " " & jsNumStr(size) & "px " & family
  result.color = run.so("color", base.so("color", "#172033"))
  result.underline = run["underline"].isTrue or base["underline"].isTrue or not run.nul("link")
  result.strike = run["strike"].isTrue or base["strike"].isTrue
  result.shift = if run.eqs("script", "sup"): -size * 0.42
                 elif run.eqs("script", "sub"): size * 0.22
                 else: 0.0

proc isSpaceAt(s: string, i: int): int =
  ## Byte length of the \s character at s[i], or 0.
  let c = s[i]
  if c in {' ', '\t', '\n', '\r', '\f', '\v'}: return 1
  if c == '\xC2' and i + 1 < s.len and s[i+1] == '\xA0': return 2
  if c == '\xE2' and i + 2 < s.len:
    let b1 = s[i+1]
    let b2 = s[i+2]
    if b1 == '\x80' and (b2 in {'\x80'..'\x8A'} or b2 in {'\xA8', '\xA9', '\xAF'}): return 3
    if b1 == '\x81' and b2 == '\x9F': return 3
  if c == '\xE3' and i + 2 < s.len and s[i+1] == '\x80' and s[i+2] == '\x80': return 3
  if c == '\xEF' and i + 2 < s.len and s[i+1] == '\xBB' and s[i+2] == '\xBF': return 3
  if c == '\xE1' and i + 2 < s.len and s[i+1] == '\x9A' and s[i+2] == '\x80': return 3
  0

proc isAllSpace*(s: string): bool =
  ## /^\s+$/.test(s)
  if s.len == 0: return false
  var i = 0
  while i < s.len:
    let n = isSpaceAt(s, i)
    if n == 0: return false
    i += n
  true

proc splitKeepSpaces*(s: string): seq[string] =
  ## s.split(/(\s+)/)
  var i = 0
  var start = 0
  while i < s.len:
    let n = isSpaceAt(s, i)
    if n > 0:
      result.add s[start ..< i]
      var j = i
      while j < s.len:
        let m = isSpaceAt(s, j)
        if m == 0: break
        j += m
      result.add s[i ..< j]
      i = j
      start = j
    else:
      inc i
  result.add s[start ..< s.len]

proc splitSpaces*(s: string): seq[string] =
  ## s.split(/\s+/)
  var i = 0
  var start = 0
  while i < s.len:
    let n = isSpaceAt(s, i)
    if n > 0:
      result.add s[start ..< i]
      var j = i
      while j < s.len:
        let m = isSpaceAt(s, j)
        if m == 0: break
        j += m
      i = j
      start = j
    else:
      inc i
  result.add s[start ..< s.len]

proc markerFont(line: Line, base: Val): string =
  base.so("fontWeight", "500") & " " & jsNumStr(line.size) & "px " &
    base.so("fontFamily", "Arial, sans-serif")

type FontState = object
  ## The 2D context's current font during layout/draw. The JS engine set
  ## ctx.font as a side effect of measuring list markers, which also changed
  ## how the rest of a wrapped run was measured; that is kept as it was.
  ctx: Ctx
  font: string

proc setFont(fs: var FontState, f: string) {.inline.} =
  fs.font = f
  if fs.ctx != nil: fs.ctx.font = f

proc measureMarker(fs: var FontState, line: Line, base: Val): float64 =
  fs.setFont(markerFont(line, base))
  measureText(fs.font, line.marker) + MarkerGap

proc layoutWith(fs: var FontState, model, base: Val, maxWidth: float64): Layout =
  let lineHeightFactor = base.fo("lineHeight", 1.28)
  let wrap = maxWidth > 0
  var counters = initTable[string, int]()
  let blocks = model["blocks"]
  var blockIndex = -1
  for blk in blocks:
    inc blockIndex
    let indent = blk.fo("indent", 0) * IndentStep
    var marker = ""
    var hasMarker = false
    let btype = blk.st("type")
    if btype == "ul" or btype == "ol":
      let key = btype & ":" & jsNumStr(blk.fo("indent", 0))
      let previous = blocks[blockIndex - 1]
      if not truthy(previous) or not isStrVal(previous["type"], btype) or
          previous.fo("indent", 0) != blk.fo("indent", 0):
        counters[key] = 0
      counters[key] = counters.getOrDefault(key, 0) + 1
      marker = if btype == "ul": "\xE2\x80\xA2" else: $counters[key] & "."
      hasMarker = true

    var current: Line
    var open = false
    var first = true
    let align = blk.so("align", base.so("align", "center"))

    template openLine() =
      current = Line(indent: indent, align: align, size: base.fo("fontSize", 14), blk: blk)
      if first and hasMarker:
        current.marker = marker
        current.hasMarker = true
      first = false
      open = true

    template closeLine() =
      if open:
        while current.segments.len > 0 and isAllSpace(current.segments[^1].text):
          current.width -= current.segments.pop().width
        current.height = current.size * lineHeightFactor
        let full = current.width + current.indent +
          (if current.hasMarker: fs.measureMarker(current, base) else: 0.0)
        result.width = max(result.width, full)
        result.lines.add current
        open = false

    openLine()
    let runs = blk["runs"]
    if runs.len == 0:
      closeLine()
      continue

    for run in runs:
      let style = runStyle(run, blk, base)
      fs.setFont(style.font)
      let rt = run["text"]
      let text = if nullish(rt): "" else: str(rt)
      let pieces = text.split('\n')
      for p in 0 ..< pieces.len:
        if p > 0:
          closeLine()
          openLine()
        for token in splitKeepSpaces(pieces[p]):
          if token.len == 0: continue
          let width = measureText(fs.font, token)
          let space = isAllSpace(token)
          if wrap and not space and current.segments.len > 0 and
              current.indent + current.width + width > maxWidth:
            closeLine()
            openLine()
          if space and current.segments.len == 0: continue
          current.segments.add Segment(text: token, style: style, width: width, x: current.width)
          current.width += width
          current.size = max(current.size, style.size)
    closeLine()

  for line in result.lines: result.height += line.height

proc layout*(model, base: Val, maxWidth: float64, ctx: Ctx = nil): Layout =
  ## Breaks the model into drawable lines. maxWidth <= 0 disables wrapping.
  var fs = FontState(ctx: ctx, font: if ctx != nil: ctx.font else: "10px sans-serif")
  layoutWith(fs, model, base, maxWidth)

proc draw*(ctx: Ctx, model: Val, bx, by, bw, bh: float64, base: Val): Layout =
  ## Draws a laid-out model inside the box.
  let padding = base.nn("padding", 9)
  let maxWidth = if base["wrap"].isFalse: 0.0 else: max(10.0, bw - padding * 2)
  var fs = FontState(ctx: ctx, font: ctx.font)
  result = layoutWith(fs, model, base, maxWidth)
  let vertical = base.so("verticalAlign", "middle")
  var y = by + (bh - result.height) / 2
  if vertical == "top": y = by + padding
  if vertical == "bottom": y = by + bh - result.height - padding

  ctx.textBaseline = "alphabetic"
  ctx.textAlign = "left"

  for line in result.lines:
    let markerWidth = if line.hasMarker: fs.measureMarker(line, base) else: 0.0
    let content = line.width + markerWidth
    var left = bx + padding + line.indent
    if line.align == "center": left = bx + (bw - content) / 2 + line.indent / 2
    elif line.align == "right": left = bx + bw - padding - content
    let baseline = y + line.height * 0.78

    if line.blk["hidden"].isTrue:
      y += line.height
      continue

    if line.hasMarker:
      ctx.font = markerFont(line, base)
      ctx.fillStyle = base.so("color", "#172033")
      ctx.fillText(line.marker, left, baseline)

    for seg in line.segments:
      let x = left + markerWidth + seg.x
      ctx.font = seg.style.font
      ctx.fillStyle = seg.style.color
      ctx.fillText(seg.text, x, baseline + seg.style.shift)
      if seg.style.underline or seg.style.strike:
        let rule = baseline + seg.style.shift +
          (if seg.style.strike: -seg.style.size * 0.3 else: seg.style.size * 0.16)
        ctx.beginPath()
        ctx.moveTo(x, rule)
        ctx.lineTo(x + seg.width, rule)
        ctx.strokeStyle = seg.style.color
        ctx.lineWidth = max(1.0, seg.style.size / 14)
        ctx.stroke()
    y += line.height

proc measure*(model, base: Val, maxWidth = 0.0): Layout =
  layout(model, base, maxWidth, nil)

# ---------------------------------------------------------- HTML writer --

proc escapeHtml*(s: string): string =
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    else: result.add c

proc runToHtml(run: Val): string =
  let rt = run["text"]
  let esc = escapeHtml(if nullish(rt): "" else: str(rt))
  var html = ""
  var i = 0
  while i < esc.len:
    if i + 1 < esc.len and esc[i] == ' ' and esc[i+1] == ' ':
      html.add " &nbsp;"
      i += 2
    else:
      html.add esc[i]
      inc i
  if run.tr("bold"): html = "<b>" & html & "</b>"
  if run.tr("italic"): html = "<i>" & html & "</i>"
  if run.tr("underline"): html = "<u>" & html & "</u>"
  if run.tr("strike"): html = "<s>" & html & "</s>"
  if run.eqs("script", "sub"): html = "<sub>" & html & "</sub>"
  if run.eqs("script", "sup"): html = "<sup>" & html & "</sup>"
  var style = ""
  if run.tr("color"): style.add "color:" & str(run["color"]) & ";"
  if run.tr("size"): style.add "font-size:" & str(run["size"]) & "px;"
  if run.tr("family"): style.add "font-family:" & str(run["family"]) & ";"
  if style.len > 0: html = "<span style=\"" & style & "\">" & html & "</span>"
  html

proc toHtml*(model: Val): string =
  if not truthy(model) or not model["blocks"].isArr: return ""
  var openList = ""
  for blk in model["blocks"]:
    var inner = ""
    for run in blk["runs"]: inner.add runToHtml(run)
    if inner.len == 0: inner = "<br>"
    let align = if blk.tr("align"): " style=\"text-align:" & str(blk["align"]) & "\"" else: ""
    let pad = if blk.tr("indent"): " style=\"margin-left:" & jsNumStr(num(blk["indent"]) * 22) & "px\"" else: ""
    let btype = blk.st("type")
    if btype == "ul" or btype == "ol":
      if openList != btype:
        if openList.len > 0: result.add "</" & openList & ">"
        result.add "<" & btype & ">"
        openList = btype
      result.add "<li>" & inner & "</li>"
      continue
    if openList.len > 0:
      result.add "</" & openList & ">"
      openList = ""
    let tag = if btype == "p": "div" else: str(blk["type"])
    result.add "<" & tag & (if align.len > 0: align else: pad) & ">" & inner & "</" & tag & ">"
  if openList.len > 0: result.add "</" & openList & ">"

# ------------------------------------------------------- HTML -> model --

var fromHtmlHook*: proc(html: string): Val
  ## Installed by the application: parses HTML with the browser's parser.

proc fromHtml*(html: string): Val =
  if fromHtmlHook == nil: return fromPlain(html)
  let model = fromHtmlHook(html)
  if model == nil: fromPlain(html) else: model
