## mxGraph stencil programs (PixelStencils.draw / run).
##
## The stencil XML libraries are parsed on the page (the sidebar needs them
## too); the flat JSON draw programs are registered here and precompiled into
## typed ops so painting a stencil is a tight loop.

import std/[tables, math, strutils]
import jsval, canvas

type
  SOpKind = enum
    sBegin, sMove, sLine, sQuad, sCurve, sArc, sClose, sRect, sRoundRect, sEllipse,
    sFill, sStroke, sFillStroke, sStrokeWidth, sFillColor, sStrokeColor, sFontColor,
    sFontSize, sAlpha, sDashed, sDashPattern, sLineJoin, sLineCap, sMiterLimit,
    sSave, sRestore, sText, sUnknown
  SOp = object
    kind: SOpKind
    x, y, x1, y1, x2, y2, w, h, rx, ry, rotation, large, sweep, arcsize: float64
    value: float64
    str: string
    hasStr: bool
    flag: bool
    pattern: seq[float64]
    align, valign: string
  Stencil* = object
    name*, library*, key*, aspect*: string
    w*, h*: float64
    ops: seq[SOp]

var registry = initTable[string, Stencil]()

proc normalizeKey*(value: string): string =
  ## Lower case with underscores for whitespace runs, like mxGraph style names.
  var i = 0
  let s = value.toLowerAscii()
  while i < s.len:
    if s[i] in {' ', '\t', '\n', '\r', '\f', '\v'}:
      result.add '_'
      while i < s.len and s[i] in {' ', '\t', '\n', '\r', '\f', '\v'}: inc i
    else:
      result.add s[i]
      inc i

proc jsParseFloat*(s: string): float64 =
  ## parseFloat(s): the longest numeric prefix after leading whitespace.
  var i = 0
  while i < s.len and s[i] in {' ', '\t', '\n', '\r', '\f', '\v'}: inc i
  let start = i
  if i < s.len and s[i] in {'+', '-'}: inc i
  if s.continuesWith("Infinity", i):
    return (if s[start] == '-': -Inf else: Inf)
  var digits = false
  while i < s.len and s[i] in {'0'..'9'}:
    inc i
    digits = true
  if i < s.len and s[i] == '.':
    inc i
    while i < s.len and s[i] in {'0'..'9'}:
      inc i
      digits = true
  if not digits: return NaN
  if i < s.len and s[i] in {'e', 'E'}:
    var j = i + 1
    if j < s.len and s[j] in {'+', '-'}: inc j
    if j < s.len and s[j] in {'0'..'9'}:
      while j < s.len and s[j] in {'0'..'9'}: inc j
      i = j
  parseNumStr(s[start ..< i])

proc compile(ops: Val): seq[SOp] =
  for o in ops:
    var op = SOp()
    let name = o.st("op")
    template g(k: static string): float64 = num(o[k])
    case name
    of "begin": op.kind = sBegin
    of "move":
      op.kind = sMove
      op.x = g("x"); op.y = g("y")
    of "line":
      op.kind = sLine
      op.x = g("x"); op.y = g("y")
    of "quad":
      op.kind = sQuad
      op.x1 = g("x1"); op.y1 = g("y1"); op.x = g("x"); op.y = g("y")
    of "curve":
      op.kind = sCurve
      op.x1 = g("x1"); op.y1 = g("y1"); op.x2 = g("x2"); op.y2 = g("y2")
      op.x = g("x"); op.y = g("y")
    of "arc":
      op.kind = sArc
      op.rx = g("rx"); op.ry = g("ry"); op.rotation = g("rotation")
      op.large = g("large"); op.sweep = g("sweep"); op.x = g("x"); op.y = g("y")
    of "close": op.kind = sClose
    of "rect":
      op.kind = sRect
      op.x = g("x"); op.y = g("y"); op.w = g("w"); op.h = g("h")
    of "roundrect":
      op.kind = sRoundRect
      op.x = g("x"); op.y = g("y"); op.w = g("w"); op.h = g("h"); op.arcsize = g("arcsize")
    of "ellipse":
      op.kind = sEllipse
      op.x = g("x"); op.y = g("y"); op.w = g("w"); op.h = g("h")
    of "fill": op.kind = sFill
    of "stroke": op.kind = sStroke
    of "fillstroke": op.kind = sFillStroke
    of "strokewidth":
      op.kind = sStrokeWidth
      let w = o["width"]
      op.hasStr = not nullish(w)
      op.str = if op.hasStr: str(w) else: ""
    of "fillcolor", "strokecolor", "fontcolor":
      op.kind = if name == "fillcolor": sFillColor elif name == "strokecolor": sStrokeColor
                else: sFontColor
      let c = o["color"]
      op.hasStr = not nullish(c)
      op.str = if op.hasStr: str(c) else: ""
    of "fontsize":
      op.kind = sFontSize
      op.value = g("size")
    of "alpha":
      op.kind = sAlpha
      op.value = g("alpha")
    of "dashed":
      op.kind = sDashed
      op.flag = truthy(o["on"])
    of "dashpattern":
      op.kind = sDashPattern
      for v in o["pattern"]: op.pattern.add num(v)
    of "linejoin", "linecap":
      op.kind = if name == "linejoin": sLineJoin else: sLineCap
      let v = if name == "linejoin": o["join"] else: o["cap"]
      op.hasStr = not nullish(v)
      op.str = if op.hasStr: str(v) else: ""
    of "miterlimit":
      op.kind = sMiterLimit
      op.value = g("limit")
    of "save": op.kind = sSave
    of "restore": op.kind = sRestore
    of "text":
      op.kind = sText
      op.str = o.so("str", "")
      op.x = g("x"); op.y = g("y")
      op.align = o.so("align", "left")
      op.valign = o.so("valign", "top")
    else: op.kind = sUnknown
    result.add op

proc register*(shapes: Val) =
  ## Registers parsed stencil programs ({key, name, library, w, h, aspect,
  ## background, foreground}).
  for shape in shapes:
    var s = Stencil(name: shape.st("name"), library: shape.st("library"),
                    key: shape.st("key"), aspect: shape.so("aspect", "variable"),
                    w: num(shape["w"]), h: num(shape["h"]))
    s.ops = compile(shape["background"]) & compile(shape["foreground"])
    registry[s.key] = s

proc has*(key: string): bool = registry.hasKey(normalizeKey(key))

type Paint* = object
  fill*, stroke*: string
  textColor*: string
  hasTextColor*: bool
  strokeWidth*: float64
  alpha*: float64
  dash*: seq[float64]
  hasDash*: bool

proc svgArc(ctx: Ctx, fromX, fromY: float64, op: SOp) =
  ## SVG elliptical arc (endpoint form) as a canvas ellipse.
  var rx = abs(op.rx)
  var ry = abs(op.ry)
  if rx == 0 or ry == 0:
    ctx.lineTo(op.x, op.y)
    return
  let phi = op.rotation * PI / 180
  let cosPhi = cos(phi)
  let sinPhi = sin(phi)
  let dx = (fromX - op.x) / 2
  let dy = (fromY - op.y) / 2
  let x1 = cosPhi * dx + sinPhi * dy
  let y1 = -sinPhi * dx + cosPhi * dy
  let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
  if lambda > 1:
    let scale = sqrt(lambda)
    rx *= scale
    ry *= scale
  let sign = if op.large != op.sweep: 1.0 else: -1.0
  let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
  let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
  let factor = if denominator == 0: 0.0 else: sign * sqrt(max(0.0, numerator / denominator))
  let cx1 = factor * rx * y1 / ry
  let cy1 = -factor * ry * x1 / rx
  let cx = cosPhi * cx1 - sinPhi * cy1 + (fromX + op.x) / 2
  let cy = sinPhi * cx1 + cosPhi * cy1 + (fromY + op.y) / 2
  let startAngle = arctan2((y1 - cy1) / ry, (x1 - cx1) / rx)
  let endAngle = arctan2((-y1 - cy1) / ry, (-x1 - cx1) / rx)
  ctx.ellipse(cx, cy, rx, ry, phi, startAngle, endAngle, op.sweep == 0)

type RunState = object
  fill, stroke: string
  lineWidth: float64
  dash: seq[float64]
  hasDash: bool
  dashPattern: seq[float64]
  hasPattern: bool
  alpha, fontSize: float64
  fontColor: string

proc run(ctx: Ctx, ops: seq[SOp], paint: Paint) =
  var cx = 0.0
  var cy = 0.0
  var state = RunState(fill: paint.fill, stroke: paint.stroke, lineWidth: paint.strokeWidth,
                       dash: paint.dash, hasDash: paint.hasDash, alpha: paint.alpha,
                       fontSize: 12, fontColor: if paint.hasTextColor and paint.textColor.len > 0:
                         paint.textColor else: "#172033")
  var stack: seq[RunState]
  ctx.globalAlpha = state.alpha

  template applyStroke() =
    if state.stroke.len > 0: ctx.strokeStyle = state.stroke
    ctx.lineWidth = state.lineWidth
    if state.hasDash: ctx.setLineDash(state.dash) else: ctx.setLineDash([])

  for op in ops:
    case op.kind
    of sBegin: ctx.beginPath()
    of sMove:
      ctx.moveTo(op.x, op.y)
      cx = op.x; cy = op.y
    of sLine:
      ctx.lineTo(op.x, op.y)
      cx = op.x; cy = op.y
    of sQuad:
      ctx.quadraticCurveTo(op.x1, op.y1, op.x, op.y)
      cx = op.x; cy = op.y
    of sCurve:
      ctx.bezierCurveTo(op.x1, op.y1, op.x2, op.y2, op.x, op.y)
      cx = op.x; cy = op.y
    of sArc:
      svgArc(ctx, cx, cy, op)
      cx = op.x; cy = op.y
    of sClose: ctx.closePath()
    of sRect:
      ctx.beginPath()
      ctx.rect(op.x, op.y, op.w, op.h)
    of sRoundRect:
      ctx.beginPath()
      ctx.roundRect(op.x, op.y, op.w, op.h, min(op.w, op.h) * (op.arcsize / 100))
    of sEllipse:
      ctx.beginPath()
      ctx.ellipse(op.x + op.w / 2, op.y + op.h / 2, op.w / 2, op.h / 2, 0, 0, PI * 2)
    of sFill:
      if state.fill.len > 0: ctx.fillStyle = state.fill
      ctx.fill()
    of sStroke:
      applyStroke()
      ctx.stroke()
    of sFillStroke:
      if state.fill.len > 0: ctx.fillStyle = state.fill
      ctx.fill()
      applyStroke()
      ctx.stroke()
    of sStrokeWidth:
      state.lineWidth = if op.hasStr and op.str == "inherit": paint.strokeWidth
                        elif op.hasStr: jsParseFloat(op.str)
                        else: NaN
    of sFillColor:
      # A missing colour assigns null, which the canvas ignores ("" here).
      state.fill = if not op.hasStr: "" elif op.str == "none": "transparent" else: op.str
    of sStrokeColor:
      state.stroke = if not op.hasStr: "" elif op.str == "none": "transparent" else: op.str
    of sAlpha:
      state.alpha = paint.alpha * op.value
      ctx.globalAlpha = state.alpha
    of sDashed:
      if op.flag:
        state.hasDash = true
        state.dash = if state.hasPattern: state.dashPattern else: @[4.0, 4.0]
      else:
        state.hasDash = false
        state.dash = @[]
    of sDashPattern:
      state.dashPattern = op.pattern
      state.hasPattern = true
      if state.hasDash: state.dash = op.pattern
    of sLineJoin:
      if op.hasStr: ctx.lineJoin = op.str
    of sLineCap:
      if op.hasStr: ctx.lineCap = op.str
    of sMiterLimit: ctx.miterLimit = op.value
    of sFontSize: state.fontSize = op.value
    of sFontColor:
      state.fontColor = if op.hasStr: op.str else: ""
    of sSave:
      ctx.save()
      stack.add state
    of sRestore:
      ctx.restore()
      if stack.len > 0: state = stack.pop()
    of sText:
      ctx.fillStyle = if state.fontColor.len > 0: state.fontColor
                      elif paint.hasTextColor and paint.textColor.len > 0: paint.textColor
                      else: "#172033"
      ctx.font = jsNumStr(if state.fontSize == state.fontSize and state.fontSize != 0:
                            state.fontSize else: 12.0) & "px Arial, sans-serif"
      ctx.textAlign = op.align
      ctx.textBaseline = if op.valign == "middle": "middle"
                         elif op.valign == "bottom": "bottom" else: "top"
      ctx.fillText(op.str, op.x, op.y)
    of sUnknown: discard

proc draw*(ctx: Ctx, key: string, bx, by, bw, bh: float64, paint: Paint): bool =
  ## Draws a registered stencil scaled into the box; false if unknown.
  let k = normalizeKey(key)
  if not registry.hasKey(k): return false
  let stencil = registry[k]
  var scaleX = bw / stencil.w
  var scaleY = bh / stencil.h
  var offsetX = 0.0
  var offsetY = 0.0
  if stencil.aspect == "fixed":
    let uniform = min(scaleX, scaleY)
    offsetX = (bw - stencil.w * uniform) / 2
    offsetY = (bh - stencil.h * uniform) / 2
    scaleX = uniform
    scaleY = uniform
  ctx.save()
  ctx.translate(bx + offsetX, by + offsetY)
  ctx.scale(scaleX, scaleY)
  let inverse = 1 / max(1e-6, min(abs(scaleX), abs(scaleY)))
  var local = paint
  local.strokeWidth = paint.strokeWidth * inverse
  run(ctx, stencil.ops, local)
  ctx.restore()
  true
