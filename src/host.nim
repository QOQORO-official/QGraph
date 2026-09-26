## The engine's view of the page.
##
## These are the wasm imports (module `env`). Everything the Nim engine cannot
## do on its own -- measuring text with the browser's fonts, reading the
## scroll container, opening DOM overlays, raising events for the UI -- goes
## through this small surface, implemented in web/js/QGraphWasm.js.

import std/tables

proc qg_parse_num(p: ptr char, len: int32): float64 {.importc, cdecl.}
proc qg_fmt_num(x: float64, dst: ptr char, cap: int32): int32 {.importc, cdecl.}
proc qg_date_now(): float64 {.importc, cdecl.}
proc qg_perf_now(): float64 {.importc, cdecl.}
proc qg_intern(id: int32, p: ptr char, len: int32) {.importc, cdecl.}
proc qg_measure(fontId: int32, p: ptr char, len: int32): float64 {.importc, cdecl.}
proc qg_host_call(op: int32, p: ptr char, len: int32): int32 {.importc, cdecl.}
proc qg_view_metrics(dst: ptr float64) {.importc, cdecl.}
proc qg_set_scroll(left, top: float64) {.importc, cdecl.}
proc qg_log(p: ptr char, len: int32) {.importc, cdecl.}

proc hostParseNum*(s: string): float64 =
  if s.len == 0: return qg_parse_num(nil, 0)
  qg_parse_num(unsafeAddr s[0], int32(s.len))

proc hostFormatNum*(x: float64): string =
  var buf: array[64, char]
  let n = qg_fmt_num(x, addr buf[0], int32(buf.len))
  result = newString(n)
  for i in 0 ..< n: result[i] = buf[i]

proc dateNow*(): float64 {.inline.} = qg_date_now()
proc perfNow*(): float64 {.inline.} = qg_perf_now()

proc log*(s: string) =
  if s.len > 0: qg_log(unsafeAddr s[0], int32(s.len))

# ------------------------------------------------------ string interning --
# Colours, fonts and label text cross to the canvas player as small integer
# ids. Each distinct string is sent to the page once.

var internIds = initTable[string, int32]()
var internCount = 0'i32

proc strId*(s: string): int32 =
  result = internIds.getOrDefault(s, -1)
  if result < 0:
    result = internCount
    inc internCount
    internIds[s] = result
    if s.len > 0: qg_intern(result, unsafeAddr s[0], int32(s.len))
    else: qg_intern(result, nil, 0)

proc resetInterning*() =
  ## Called by the page when it reloads its string table (never mid-frame).
  internIds.clear()
  internCount = 0

# ----------------------------------------------------------- measurement --

var measureCache = initTable[(int32, string), float64]()

proc measureText*(font, text: string): float64 =
  ## ctx.measureText(text).width with ctx.font = font.
  let key = (strId(font), text)
  result = measureCache.getOrDefault(key, -1.0)
  if result < 0:
    result = if text.len == 0: qg_measure(key[0], nil, 0)
             else: qg_measure(key[0], unsafeAddr text[0], int32(text.len))
    if measureCache.len > 100_000: measureCache.clear()
    measureCache[key] = result

# ---------------------------------------------------------- host calls --
# A generic request/response channel for the less frequent operations. The
# payload is JSON; the page may answer with a UTF-8 reply which it writes
# into `replyBuf` through qg_reply_buffer.

var replyBuf*: string

proc qg_reply_buffer*(len: int32): pointer {.exportc, codegenDecl: "__attribute__((export_name(\"qg_reply_buffer\"))) $1 $2$3".} =
  replyBuf = newString(len)
  if len == 0: nil else: addr replyBuf[0]

proc hostCall*(op: int32, payload: string = ""): string =
  replyBuf.setLen(0)
  let n = if payload.len > 0: qg_host_call(op, unsafeAddr payload[0], int32(payload.len))
          else: qg_host_call(op, nil, 0)
  if n <= 0: return ""
  result = replyBuf
  result.setLen(n)

type ViewMetrics* = object
  clientWidth*, clientHeight*, scrollLeft*, scrollTop*, dpr*: float64

var viewMetricsHook*: proc(): ViewMetrics
var setScrollHook*: proc(left, top: float64)
  ## The scrolling container the engine lays the world out in; installed by
  ## the application. NaN leaves an axis alone.

proc viewMetrics*(): ViewMetrics =
  if viewMetricsHook != nil: return viewMetricsHook()
  var buf: array[5, float64]
  qg_view_metrics(addr buf[0])
  ViewMetrics(clientWidth: buf[0], clientHeight: buf[1], scrollLeft: buf[2],
              scrollTop: buf[3], dpr: buf[4])

proc setScroll*(left, top: float64) =
  if setScrollHook != nil: setScrollHook(left, top)
  else: qg_set_scroll(left, top)

const
  HostEmit* = 1'i32              ## {name, data}
  HostRender* = 2'i32            ## {view, realtime}
  HostSpacer* = 3'i32            ## {width, height}
  HostRendererSync* = 4'i32      ## {}
  HostRendererUpsert* = 5'i32    ## {ids, defer, media}
  HostRendererRemove* = 6'i32    ## {ids}
  HostOverlay* = 7'i32           ## overlay command buffer is ready
  HostCursor* = 8'i32            ## {cursor}
  HostTooltip* = 9'i32           ## {text, x, y} or {hide}
  HostOpenLink* = 10'i32         ## {href}
  HostTextEditorOpen* = 11'i32   ## editor DOM description
  HostTextEditorClose* = 12'i32  ## {}
  HostRichFromHtml* = 13'i32     ## html -> rich text JSON (reply)
  HostTimer* = 14'i32            ## {name, ms} or {name, cancel}
  HostFocus* = 15'i32            ## focus the container
  HostMediaScan* = 16'i32        ## media items JSON for animation sniffing
