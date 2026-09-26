## A Canvas2D recorder.
##
## The painter and the selection overlay are written against this object
## exactly as they were written against CanvasRenderingContext2D. Calls are
## appended to a flat float64 command buffer that web/js/QGraphWasm.js replays
## onto a real 2D context; strings (colours, fonts, label text) travel as
## interned ids. The recorder also mirrors the readable parts of canvas state
## (globalAlpha, lineWidth, textAlign, font, styles) through save/restore,
## including the browser's rule that invalid assignments are ignored, because
## the painter reads several of them back.

import host

const
  OpEnd* = 0.0
  OpSave* = 1.0
  OpRestore* = 2.0
  OpBeginPath* = 3.0
  OpMoveTo* = 4.0
  OpLineTo* = 5.0
  OpQuad* = 6.0
  OpBezier* = 7.0
  OpArc* = 8.0
  OpEllipse* = 9.0
  OpRect* = 10.0
  OpRoundRect* = 11.0
  OpClosePath* = 12.0
  OpFill* = 13.0
  OpStroke* = 14.0
  OpClip* = 15.0
  OpFillRect* = 16.0
  OpStrokeRect* = 17.0
  OpClearRect* = 18.0
  OpFillText* = 19.0
  OpFillStyle* = 20.0
  OpStrokeStyle* = 21.0
  OpFillGrad* = 22.0
  OpStrokeGrad* = 23.0
  OpLineWidth* = 24.0
  OpFont* = 25.0
  OpTextAlign* = 26.0
  OpTextBaseline* = 27.0
  OpGlobalAlpha* = 28.0
  OpLineCap* = 29.0
  OpLineJoin* = 30.0
  OpMiterLimit* = 31.0
  OpLineDash* = 32.0
  OpTranslate* = 33.0
  OpRotate* = 34.0
  OpScale* = 35.0
  OpSetTransform* = 36.0
  OpShadowColor* = 37.0
  OpShadowBlur* = 38.0
  OpShadowOffsetX* = 39.0
  OpShadowOffsetY* = 40.0
  OpLinearGrad* = 41.0
  OpRadialGrad* = 42.0
  OpColorStop* = 43.0
  OpMedia* = 44.0
  OpDrawImage* = 45.0
  OpDrawImage9* = 46.0
  OpFillPattern* = 47.0

type
  CtxState = object
    fillStyle, strokeStyle: string   ## "" + grad >= 0 means a gradient
    fillGrad, strokeGrad: int
    lineWidth, globalAlpha, miterLimit: float64
    font, textAlign, textBaseline, lineCap, lineJoin: string
    shadowColor: string
    shadowBlur, shadowOffsetX, shadowOffsetY: float64
    dash: seq[float64]

  Ctx* = ref object
    buf*: seq[float64]
    st: CtxState
    stack: seq[CtxState]
    gradients: int

proc defaultState(): CtxState =
  CtxState(fillStyle: "#000000", strokeStyle: "#000000", fillGrad: -1, strokeGrad: -1,
           lineWidth: 1, globalAlpha: 1, miterLimit: 10, font: "10px sans-serif",
           textAlign: "start", textBaseline: "alphabetic", lineCap: "butt",
           lineJoin: "miter", shadowColor: "rgba(0, 0, 0, 0)")

proc newCtx*(): Ctx =
  Ctx(st: defaultState(), buf: newSeqOfCap[float64](4096))

proc reset*(c: Ctx) =
  ## Starts a new command list for a freshly cleared canvas.
  c.buf.setLen(0)
  c.stack.setLen(0)
  c.st = defaultState()
  c.gradients = 0

proc finish*(c: Ctx) = c.buf.add OpEnd

template op(c: Ctx, code: float64) = c.buf.add code
template op(c: Ctx, code: float64, a: float64) =
  c.buf.add code
  c.buf.add a
template op(c: Ctx, code: float64, a, b: float64) =
  c.buf.add code
  c.buf.add a
  c.buf.add b

proc save*(c: Ctx) =
  c.stack.add c.st
  c.op OpSave

proc restore*(c: Ctx) =
  if c.stack.len > 0:
    c.st = c.stack.pop()
  c.op OpRestore

proc beginPath*(c: Ctx) = c.op OpBeginPath
proc closePath*(c: Ctx) = c.op OpClosePath
proc moveTo*(c: Ctx, x, y: float64) = c.op(OpMoveTo, x, y)
proc lineTo*(c: Ctx, x, y: float64) = c.op(OpLineTo, x, y)

proc quadraticCurveTo*(c: Ctx, cx, cy, x, y: float64) =
  c.buf.add OpQuad
  c.buf.add cx
  c.buf.add cy
  c.buf.add x
  c.buf.add y

proc bezierCurveTo*(c: Ctx, c1x, c1y, c2x, c2y, x, y: float64) =
  c.buf.add OpBezier
  c.buf.add c1x
  c.buf.add c1y
  c.buf.add c2x
  c.buf.add c2y
  c.buf.add x
  c.buf.add y

proc arc*(c: Ctx, x, y, r, a0, a1: float64, ccw = false) =
  c.buf.add OpArc
  c.buf.add x
  c.buf.add y
  c.buf.add r
  c.buf.add a0
  c.buf.add a1
  c.buf.add(if ccw: 1.0 else: 0.0)

proc ellipse*(c: Ctx, x, y, rx, ry, rotation, a0, a1: float64, ccw = false) =
  c.buf.add OpEllipse
  c.buf.add x
  c.buf.add y
  c.buf.add rx
  c.buf.add ry
  c.buf.add rotation
  c.buf.add a0
  c.buf.add a1
  c.buf.add(if ccw: 1.0 else: 0.0)

proc rect*(c: Ctx, x, y, w, h: float64) =
  c.buf.add OpRect
  c.buf.add x
  c.buf.add y
  c.buf.add w
  c.buf.add h

proc roundRect*(c: Ctx, x, y, w, h, r: float64) =
  c.buf.add OpRoundRect
  c.buf.add x
  c.buf.add y
  c.buf.add w
  c.buf.add h
  c.buf.add r

proc fill*(c: Ctx) = c.op OpFill
proc stroke*(c: Ctx) = c.op OpStroke
proc clip*(c: Ctx) = c.op OpClip

proc rectOp(c: Ctx, code, x, y, w, h: float64) =
  c.buf.add code
  c.buf.add x
  c.buf.add y
  c.buf.add w
  c.buf.add h

proc fillRect*(c: Ctx, x, y, w, h: float64) = c.rectOp(OpFillRect, x, y, w, h)
proc strokeRect*(c: Ctx, x, y, w, h: float64) = c.rectOp(OpStrokeRect, x, y, w, h)
proc clearRect*(c: Ctx, x, y, w, h: float64) = c.rectOp(OpClearRect, x, y, w, h)

proc fillText*(c: Ctx, text: string, x, y: float64) =
  c.buf.add OpFillText
  c.buf.add float64(strId(text))
  c.buf.add x
  c.buf.add y

proc measureText*(c: Ctx, text: string): float64 =
  ## ctx.measureText(text).width
  measureText(c.st.font, text)

# ---------------------------------------------------------------- state --

proc `fillStyle=`*(c: Ctx, color: string) =
  c.st.fillStyle = color
  c.st.fillGrad = -1
  c.op(OpFillStyle, float64(strId(color)))

proc `strokeStyle=`*(c: Ctx, color: string) =
  c.st.strokeStyle = color
  c.st.strokeGrad = -1
  c.op(OpStrokeStyle, float64(strId(color)))

proc fillStyle*(c: Ctx): string = c.st.fillStyle
proc strokeStyle*(c: Ctx): string = c.st.strokeStyle

proc `lineWidth=`*(c: Ctx, w: float64) =
  if w != w or w <= 0 or w == Inf: return
  c.st.lineWidth = w
  c.op(OpLineWidth, w)

proc lineWidth*(c: Ctx): float64 = c.st.lineWidth

proc `globalAlpha=`*(c: Ctx, a: float64) =
  if a != a or a < 0 or a > 1: return
  c.st.globalAlpha = a
  c.op(OpGlobalAlpha, a)

proc globalAlpha*(c: Ctx): float64 = c.st.globalAlpha

proc `miterLimit=`*(c: Ctx, v: float64) =
  if v != v or v <= 0 or v == Inf: return
  c.st.miterLimit = v
  c.op(OpMiterLimit, v)

proc `font=`*(c: Ctx, f: string) =
  if f.len == 0: return
  c.st.font = f
  c.op(OpFont, float64(strId(f)))

proc font*(c: Ctx): string = c.st.font

proc enumIndex(v: string, choices: openArray[string]): int =
  for i, x in choices:
    if x == v: return i
  -1

const
  TextAligns = ["start", "end", "left", "right", "center"]
  Baselines = ["top", "hanging", "middle", "alphabetic", "ideographic", "bottom"]
  LineCaps = ["butt", "round", "square"]
  LineJoins = ["round", "bevel", "miter"]

proc `textAlign=`*(c: Ctx, v: string) =
  let i = enumIndex(v, TextAligns)
  if i < 0: return
  c.st.textAlign = v
  c.op(OpTextAlign, float64(i))

proc textAlign*(c: Ctx): string = c.st.textAlign

proc `textBaseline=`*(c: Ctx, v: string) =
  let i = enumIndex(v, Baselines)
  if i < 0: return
  c.st.textBaseline = v
  c.op(OpTextBaseline, float64(i))

proc `lineCap=`*(c: Ctx, v: string) =
  let i = enumIndex(v, LineCaps)
  if i < 0: return
  c.st.lineCap = v
  c.op(OpLineCap, float64(i))

proc `lineJoin=`*(c: Ctx, v: string) =
  let i = enumIndex(v, LineJoins)
  if i < 0: return
  c.st.lineJoin = v
  c.op(OpLineJoin, float64(i))

proc setLineDash*(c: Ctx, dash: openArray[float64]) =
  for d in dash:
    if d != d or d < 0 or d == Inf: return
  c.st.dash = @dash
  c.buf.add OpLineDash
  c.buf.add float64(dash.len)
  for d in dash: c.buf.add d

proc `shadowColor=`*(c: Ctx, color: string) =
  c.st.shadowColor = color
  c.op(OpShadowColor, float64(strId(color)))

proc `shadowBlur=`*(c: Ctx, v: float64) =
  if v != v or v < 0 or v == Inf: return
  c.st.shadowBlur = v
  c.op(OpShadowBlur, v)

proc `shadowOffsetX=`*(c: Ctx, v: float64) =
  if v != v or v == Inf or v == -Inf: return
  c.st.shadowOffsetX = v
  c.op(OpShadowOffsetX, v)

proc `shadowOffsetY=`*(c: Ctx, v: float64) =
  if v != v or v == Inf or v == -Inf: return
  c.st.shadowOffsetY = v
  c.op(OpShadowOffsetY, v)

proc translate*(c: Ctx, x, y: float64) = c.op(OpTranslate, x, y)
proc rotate*(c: Ctx, a: float64) = c.op(OpRotate, a)
proc scale*(c: Ctx, x, y: float64) = c.op(OpScale, x, y)

proc setTransform*(c: Ctx, a, b, cc, d, e, f: float64) =
  c.buf.add OpSetTransform
  c.buf.add a
  c.buf.add b
  c.buf.add cc
  c.buf.add d
  c.buf.add e
  c.buf.add f

# ------------------------------------------------------------ gradients --

type Gradient* = object
  ctx: Ctx
  slot*: int

proc createLinearGradient*(c: Ctx, x0, y0, x1, y1: float64): Gradient =
  result = Gradient(ctx: c, slot: c.gradients)
  inc c.gradients
  c.buf.add OpLinearGrad
  c.buf.add float64(result.slot)
  c.buf.add x0
  c.buf.add y0
  c.buf.add x1
  c.buf.add y1

proc createRadialGradient*(c: Ctx, x0, y0, r0, x1, y1, r1: float64): Gradient =
  result = Gradient(ctx: c, slot: c.gradients)
  inc c.gradients
  c.buf.add OpRadialGrad
  c.buf.add float64(result.slot)
  c.buf.add x0
  c.buf.add y0
  c.buf.add r0
  c.buf.add x1
  c.buf.add y1
  c.buf.add r1

proc addColorStop*(g: Gradient, offset: float64, color: string) =
  g.ctx.buf.add OpColorStop
  g.ctx.buf.add float64(g.slot)
  g.ctx.buf.add offset
  g.ctx.buf.add float64(strId(color))

proc setFillGradient*(c: Ctx, g: Gradient) =
  c.st.fillStyle = ""
  c.st.fillGrad = g.slot
  c.op(OpFillGrad, float64(g.slot))

# ---------------------------------------------------------------- media --

var currentCmd*: ptr seq[float64]
  ## The command list the page should replay next (qg_cmd_ptr/qg_cmd_len).

proc media*(c: Ctx, nodeJson: string) =
  ## Hands an image/video node to the page's media painter (drawImageNode).
  c.op(OpMedia, float64(strId(nodeJson)))

proc drawImage*(c: Ctx, source: int32, dx, dy, dw, dh: float64) =
  ## ctx.drawImage(handle, dx, dy, dw, dh); `source` is a page handle
  ## (image, video, canvas or bitmap).
  c.buf.add OpDrawImage
  c.buf.add float64(source)
  c.buf.add dx
  c.buf.add dy
  c.buf.add dw
  c.buf.add dh

proc drawImage*(c: Ctx, source: int32, sx, sy, sw, sh, dx, dy, dw, dh: float64) =
  c.buf.add OpDrawImage9
  c.buf.add float64(source)
  for v in [sx, sy, sw, sh, dx, dy, dw, dh]: c.buf.add v

proc fillPattern*(c: Ctx, source: int32, repetition = 0) =
  ## fillStyle = createPattern(source, ["repeat", "repeat-x", "repeat-y",
  ## "no-repeat"][repetition]).
  c.st.fillStyle = ""
  c.st.fillGrad = -2
  c.buf.add OpFillPattern
  c.buf.add float64(source)
  c.buf.add float64(repetition)
