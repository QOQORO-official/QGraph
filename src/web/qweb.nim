## qweb -- Nim bindings for the browser host (web/js/qweb.js).
##
## The design follows bindweb: DOM mutations are appended to a byte command
## buffer and executed by the host in one call when the buffer is flushed,
## and every DOM object is an integer handle. Nim allocates the handles for
## the nodes it creates, so building a dialog or a palette of hundreds of
## thumbnails costs no round trips at all. Reads (layout, form values,
## queries) are immediate calls that flush first, so they always observe the
## mutations issued before them.
##
## Beyond the DOM the host offers typed reflection (get/set/invoke on any
## handle), synchronous event dispatch into Nim listeners, timers and
## animation frames, fetch/file/blob I/O, workers and shared-memory threads.

import std/tables
import ../host

{.pragma: wexport, exportc,
  codegenDecl: "__attribute__((export_name(\"$2\"))) $1 $2$3".}

type
  Node* = distinct int32
    ## A handle to any page object: element, text node, window, canvas
    ## context, video, file, blob, bitmap, worker...

  JsKind* = enum
    jsUndefined, jsNull, jsNumber, jsString, jsBool, jsHandle, jsBytes

  JsResult* = object
    kind*: JsKind
    num*: float64
    str*: string
    node*: Node

  JsArgKind = enum
    akUndefined, akNull, akNumber, akString, akBool, akHandle, akBytes, akJson

  JsArg* = object
    kind: JsArgKind
    num: float64
    str: string
    node: Node

  Event* = object
    ## The event being dispatched. Only valid inside the listener call.

  DomRect* = object
    left*, top*, width*, height*, right*, bottom*: float64

const
  nilNode* = Node(0)
  window* = Node(1)
  document* = Node(2)
  body* = Node(3)
  head* = Node(4)
  documentElement* = Node(5)
  localStorage* = Node(6)
  navigator* = Node(7)
  location* = Node(8)
  console* = Node(9)
  performance* = Node(10)

proc `==`*(a, b: Node): bool {.borrow.}
proc isNil*(n: Node): bool {.inline.} = int32(n) == 0
proc id*(n: Node): int32 {.inline.} = int32(n)

# ---------------------------------------------------------------- imports --

proc qw_flush(p: pointer, n: int32) {.importc, cdecl.}
proc qw_get(h: int32, np: pointer, nl: int32): int32 {.importc, cdecl.}
proc qw_get2(h: int32, ap: pointer, al: int32, bp: pointer, bl: int32): int32 {.importc, cdecl.}
proc qw_invoke(h: int32, np: pointer, nl: int32, ap: pointer, al: int32, argc: int32): int32 {.importc, cdecl.}
proc qw_construct(cp: pointer, cl: int32, ap: pointer, al: int32, argc: int32): int32 {.importc, cdecl.}
proc qw_rect(h: int32, dst: ptr float64) {.importc, cdecl.}
proc qw_query(h: int32, sp: pointer, sl: int32): int32 {.importc, cdecl.}
proc qw_query_all(h: int32, sp: pointer, sl: int32, dst: ptr int32, cap: int32): int32 {.importc, cdecl.}
proc qw_closest(h: int32, sp: pointer, sl: int32): int32 {.importc, cdecl.}
proc qw_matches(h: int32, sp: pointer, sl: int32): int32 {.importc, cdecl.}
proc qw_contains(a, b: int32): int32 {.importc, cdecl.}
proc qw_same(a, b: int32): int32 {.importc, cdecl.}
proc qw_active_element(): int32 {.importc, cdecl.}
proc qw_context(canvas, kind, alpha, desync: int32): int32 {.importc, cdecl.}
proc qw_replay(ctx: int32, p: pointer, n: int32) {.importc, cdecl.}
proc qw_put_rgba(ctx: int32, p: pointer, w, h: int32) {.importc, cdecl.}
proc qw_node_text(h: int32): int32 {.importc, cdecl.}
proc qw_select_contents(h: int32) {.importc, cdecl.}
proc qw_exec_command(cp: pointer, cl: int32, vp: pointer, vl: int32, has: int32): int32 {.importc, cdecl.}
proc qw_dom_snapshot(hp: pointer, hl: int32, mode: int32): int32 {.importc, cdecl.}
proc qw_ev_num(f: int32): float64 {.importc, cdecl.}
proc qw_ev_str(f: int32): int32 {.importc, cdecl.}
proc qw_ev_handle(f: int32): int32 {.importc, cdecl.}
proc qw_ev_prevent() {.importc, cdecl.}
proc qw_ev_stop() {.importc, cdecl.}
proc qw_timeout(id: int32, ms: float64) {.importc, cdecl.}
proc qw_clear_timeout(id: int32) {.importc, cdecl.}
proc qw_raf(id: int32) {.importc, cdecl.}
proc qw_cancel_raf(id: int32) {.importc, cdecl.}
proc qw_fetch(id: int32, up: pointer, ul: int32, mode: int32) {.importc, cdecl.}
proc qw_read_blob(id: int32, h: int32, mode: int32) {.importc, cdecl.}
proc qw_blob(p: pointer, n: int32, mp: pointer, ml: int32): int32 {.importc, cdecl.}
proc qw_image_bitmap(id: int32, h: int32) {.importc, cdecl.}
proc qw_canvas_blob(id: int32, h: int32, mp: pointer, ml: int32) {.importc, cdecl.}
proc qw_clipboard_write(p: pointer, n: int32) {.importc, cdecl.}
proc qw_prompt(mp: pointer, ml: int32, dp: pointer, dl: int32): int32 {.importc, cdecl.}
proc qw_last_error(): int32 {.importc, cdecl.}
proc qw_presenter(canvas: int32, kind: int32): int32 {.importc, cdecl.}
proc qw_present(presenter: int32, source: int32) {.importc, cdecl.}
proc qw_worker_new(kind: int32): int32 {.importc, cdecl.}
proc qw_post(target: int32, p: pointer, n: int32, hp: pointer, hc: int32) {.importc, cdecl.}
proc qw_is_worker(): int32 {.importc, cdecl.}
proc qw_is_shared(): int32 {.importc, cdecl.}
proc qw_cores(): int32 {.importc, cdecl.}
proc qw_reply_len(): int32 {.importc, cdecl.}
proc qw_reply_copy(dst: pointer) {.importc, cdecl.}
proc qw_result_number(): float64 {.importc, cdecl.}

proc c_malloc(n: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

template sp(s: string): pointer = (if s.len == 0: nil else: unsafeAddr s[0])

proc takeReply(n: int32): string =
  ## Reads the host's pending reply (n bytes).
  if n <= 0:
    if n == 0: qw_reply_copy(nil)
    return ""
  result = newString(n)
  qw_reply_copy(addr result[0])

proc replyNow(): string =
  let n = qw_reply_len()
  takeReply(n)

# --------------------------------------------------------- command buffer --

var cmd: seq[byte]
var nextNode = 1'i32 shl 24

proc flush*() =
  ## Executes all queued DOM commands. Reentrant: listeners that fire while
  ## the host executes (focus/blur, for instance) queue into a fresh buffer.
  if cmd.len == 0: return
  var batch = move(cmd)
  cmd = newSeqOfCap[byte](max(1024, batch.len))
  qw_flush(addr batch[0], int32(batch.len))

proc wI32(v: int32) {.inline.} =
  let n = cmd.len
  cmd.setLen(n + 4)
  copyMem(addr cmd[n], unsafeAddr v, 4)

proc wF64(v: float64) {.inline.} =
  let n = cmd.len
  cmd.setLen(n + 8)
  copyMem(addr cmd[n], unsafeAddr v, 8)

proc wStr(s: string) =
  wI32(int32(s.len))
  if s.len > 0:
    let n = cmd.len
    let padded = (s.len + 3) and not 3
    cmd.setLen(n + padded)
    copyMem(addr cmd[n], unsafeAddr s[0], s.len)
    for i in n + s.len ..< n + padded: cmd[i] = 0

template wSid(s: string) = wI32(strId(s))

proc newNode(): Node =
  result = Node(nextNode)
  inc nextNode

# Argument encoding shared by the buffer and the invoke scratch.
proc encodeArg(buf: var seq[byte], a: JsArg) =
  template i32(v: int32) =
    let n = buf.len
    buf.setLen(n + 4)
    var x = v
    copyMem(addr buf[n], addr x, 4)
  template str(s: string) =
    i32(int32(s.len))
    if s.len > 0:
      let n = buf.len
      let padded = (s.len + 3) and not 3
      buf.setLen(n + padded)
      copyMem(addr buf[n], unsafeAddr s[0], s.len)
      for i in n + s.len ..< n + padded: buf[i] = 0
  i32(int32(ord(a.kind)))
  case a.kind
  of akUndefined, akNull: discard
  of akNumber:
    let n = buf.len
    buf.setLen(n + 8)
    var x = a.num
    copyMem(addr buf[n], addr x, 8)
  of akString, akBytes, akJson: str(a.str)
  of akBool: i32(if a.num != 0: 1'i32 else: 0'i32)
  of akHandle: i32(int32(a.node))

converter toArg*(v: string): JsArg = JsArg(kind: akString, str: v)
converter toArg*(v: float64): JsArg = JsArg(kind: akNumber, num: v)
converter toArg*(v: int): JsArg = JsArg(kind: akNumber, num: float64(v))
converter toArg*(v: int32): JsArg = JsArg(kind: akNumber, num: float64(v))
converter toArg*(v: bool): JsArg = JsArg(kind: akBool, num: (if v: 1.0 else: 0.0))
converter toArg*(v: Node): JsArg =
  if v.isNil: JsArg(kind: akNull) else: JsArg(kind: akHandle, node: v)
proc jsNull*(): JsArg = JsArg(kind: akNull)
proc jsUndef*(): JsArg = JsArg(kind: akUndefined)
proc jsJson*(json: string): JsArg = JsArg(kind: akJson, str: json)
proc jsBytes*(data: string): JsArg = JsArg(kind: akBytes, str: data)

# ------------------------------------------------------------ DOM (queued) --

proc createElement*(tag: string): Node =
  result = newNode()
  wI32(1); wI32(int32(result)); wSid(tag)

proc createElementNS*(ns, tag: string): Node =
  result = newNode()
  wI32(2); wI32(int32(result)); wSid(ns); wSid(tag)

proc createTextNode*(text: string): Node =
  result = newNode()
  wI32(3); wI32(int32(result)); wStr(text)

proc appendChild*(parent, child: Node) =
  wI32(4); wI32(int32(parent)); wI32(int32(child))

proc insertBefore*(parent, child, before: Node) =
  wI32(5); wI32(int32(parent)); wI32(int32(child)); wI32(int32(before))

proc remove*(n: Node) =
  ## Detaches the node (its handle stays valid).
  wI32(6); wI32(int32(n))

proc setAttribute*(n: Node, name, value: string) =
  wI32(7); wI32(int32(n)); wSid(name); wStr(value)

proc removeAttribute*(n: Node, name: string) =
  wI32(8); wI32(int32(n)); wSid(name)

proc setProp*(n: Node, name: string, value: JsArg) =
  wI32(9); wI32(int32(n)); wSid(name); encodeArg(cmd, value)

proc style*(n: Node, prop, value: string) =
  ## n.style[prop] = value (camelCase property names, as in JS).
  wI32(10); wI32(int32(n)); wSid(prop); wStr(value)

proc addClass*(n: Node, cls: string) =
  wI32(11); wI32(int32(n)); wSid(cls)

proc removeClass*(n: Node, cls: string) =
  wI32(12); wI32(int32(n)); wSid(cls)

proc toggleClass*(n: Node, cls: string, on: bool) =
  wI32(13); wI32(int32(n)); wSid(cls); wI32(if on: 1 else: 0)

proc call*(n: Node, meth: string, args: varargs[JsArg]) =
  ## Queued n[meth](...args); the result is discarded.
  wI32(16); wI32(int32(n)); wSid(meth); wI32(int32(args.len))
  for a in args: encodeArg(cmd, a)

proc release*(n: Node) =
  ## Forgets the handle (the object itself is untouched).
  wI32(17); wI32(int32(n))

proc dropTree*(n: Node) =
  ## Removes the element and releases every handle and listener inside it.
  wI32(18); wI32(int32(n))

proc `text=`*(n: Node, value: string) =
  wI32(19); wI32(int32(n)); wStr(value)

proc `html=`*(n: Node, value: string) =
  wI32(20); wI32(int32(n)); wStr(value)

proc `hidden=`*(n: Node, value: bool) =
  wI32(21); wI32(int32(n)); wSid("hidden"); wI32(if value: 1 else: 0)

proc `className=`*(n: Node, value: string) =
  wI32(22); wI32(int32(n)); wStr(value)

proc setData*(n: Node, key, value: string) =
  wI32(23); wI32(int32(n)); wSid(key); wStr(value)

proc deleteData*(n: Node, key: string) =
  wI32(24); wI32(int32(n)); wSid(key)

proc `cssText=`*(n: Node, value: string) =
  wI32(25); wI32(int32(n)); wStr(value)

proc setProp2*(n: Node, a, b: string, value: JsArg) =
  ## n[a][b] = value.
  wI32(26); wI32(int32(n)); wSid(a); wSid(b); encodeArg(cmd, value)

proc alias*(n: Node): Node =
  ## A second handle for the same object.
  result = newNode()
  wI32(27); wI32(int32(result)); wI32(int32(n))

# Convenience -------------------------------------------------------------

proc el*(tag: string, cls = ""): Node =
  result = createElement(tag)
  if cls.len > 0: result.className = cls

proc add*(parent, child: Node): Node {.discardable.} =
  appendChild(parent, child)
  child

proc focus*(n: Node, preventScroll = false) =
  if preventScroll: n.call("focus", jsJson("{\"preventScroll\":true}"))
  else: n.call("focus")

proc blur*(n: Node) = n.call("blur")
proc click*(n: Node) = n.call("click")
proc `value=`*(n: Node, v: string) = n.setProp("value", v)
proc `checked=`*(n: Node, v: bool) = n.setProp("checked", v)
proc `disabled=`*(n: Node, v: bool) = n.setProp("disabled", v)
proc `title=`*(n: Node, v: string) = n.setProp("title", v)
proc `typ=`*(n: Node, v: string) = n.setProp("type", v)

# ------------------------------------------------------- reads (immediate) --

proc readResult(tag: int32): JsResult =
  case tag
  of 0: JsResult(kind: jsUndefined)
  of 1: JsResult(kind: jsNull)
  of 2: JsResult(kind: jsNumber, num: qw_result_number())
  of 3: JsResult(kind: jsString, str: replyNow())
  of 4: JsResult(kind: jsBool, num: qw_result_number())
  of 5: JsResult(kind: jsHandle, node: Node(int32(qw_result_number())))
  of 6: JsResult(kind: jsBytes, str: replyNow())
  else: JsResult(kind: jsUndefined)

proc get*(n: Node, prop: string): JsResult =
  flush()
  readResult(qw_get(int32(n), sp(prop), int32(prop.len)))

proc get2*(n: Node, a, b: string): JsResult =
  flush()
  readResult(qw_get2(int32(n), sp(a), int32(a.len), sp(b), int32(b.len)))

proc toNum*(r: JsResult): float64 =
  case r.kind
  of jsNumber, jsBool: r.num
  of jsString: hostParseNum(r.str)
  else: 0

proc toStr*(r: JsResult): string =
  case r.kind
  of jsString, jsBytes: r.str
  of jsNumber: hostFormatNum(r.num)
  of jsBool: (if r.num != 0: "true" else: "false")
  of jsNull: "null"
  else: ""

proc toBool*(r: JsResult): bool =
  case r.kind
  of jsBool, jsNumber: r.num != 0 and r.num == r.num
  of jsString: r.str.len > 0
  of jsHandle: not r.node.isNil
  else: false

proc toNode*(r: JsResult): Node = (if r.kind == jsHandle: r.node else: nilNode)

proc getNum*(n: Node, prop: string): float64 = n.get(prop).toNum
proc getStr*(n: Node, prop: string): string = n.get(prop).toStr
proc getBool*(n: Node, prop: string): bool = n.get(prop).toBool
proc getNode*(n: Node, prop: string): Node = n.get(prop).toNode

proc value*(n: Node): string = n.getStr("value")
proc checked*(n: Node): bool = n.getBool("checked")
proc hidden*(n: Node): bool = n.getBool("hidden")

proc invoke*(n: Node, meth: string, args: varargs[JsArg]): JsResult =
  flush()
  var buf: seq[byte]
  for a in args: encodeArg(buf, a)
  let tag = qw_invoke(int32(n), sp(meth), int32(meth.len),
                      (if buf.len == 0: nil else: addr buf[0]), int32(buf.len), int32(args.len))
  if tag < 0: JsResult(kind: jsUndefined) else: readResult(tag)

proc construct*(ctor: string, args: varargs[JsArg]): Node =
  flush()
  var buf: seq[byte]
  for a in args: encodeArg(buf, a)
  Node(qw_construct(sp(ctor), int32(ctor.len),
       (if buf.len == 0: nil else: addr buf[0]), int32(buf.len), int32(args.len)))

proc lastError*(): string = takeReply(qw_last_error())

proc rect*(n: Node): DomRect =
  flush()
  var r: array[6, float64]
  qw_rect(int32(n), addr r[0])
  DomRect(left: r[0], top: r[1], width: r[2], height: r[3], right: r[4], bottom: r[5])

proc query*(n: Node, selector: string): Node =
  flush()
  Node(qw_query(int32(n), sp(selector), int32(selector.len)))

proc queryAll*(n: Node, selector: string): seq[Node] =
  flush()
  var buf = newSeq[int32](256)
  var count = qw_query_all(int32(n), sp(selector), int32(selector.len), addr buf[0], 256)
  if count > 256:
    buf.setLen(count)
    count = qw_query_all(int32(n), sp(selector), int32(selector.len), addr buf[0], count)
  for i in 0 ..< min(count, int32(buf.len)): result.add Node(buf[i])

proc closest*(n: Node, selector: string): Node =
  flush()
  Node(qw_closest(int32(n), sp(selector), int32(selector.len)))

proc matches*(n: Node, selector: string): bool =
  flush()
  qw_matches(int32(n), sp(selector), int32(selector.len)) != 0

proc contains*(outer, inner: Node): bool =
  flush()
  qw_contains(int32(outer), int32(inner)) != 0

proc same*(a, b: Node): bool =
  ## True when both handles name the same object.
  if a == b: return true
  qw_same(int32(a), int32(b)) != 0

proc activeElement*(): Node =
  flush()
  Node(qw_active_element())

proc innerText*(n: Node): string =
  flush()
  takeReply(qw_node_text(int32(n)))

proc selectContents*(n: Node) =
  flush()
  qw_select_contents(int32(n))

proc execCommand*(command: string, value: string = "", hasValue = false): bool =
  flush()
  qw_exec_command(sp(command), int32(command.len), sp(value), int32(value.len),
                  if hasValue: 1 else: 0) != 0

proc domSnapshot*(markup: string, svg = false): string =
  ## Browser-parsed tree of `markup` as JSON (see qweb.js snapshot()).
  flush()
  takeReply(qw_dom_snapshot(sp(markup), int32(markup.len), if svg: 1 else: 0))

# ----------------------------------------------------------------- canvas --

proc context2d*(canvas: Node, alpha = true, desynchronized = false): Node =
  flush()
  Node(qw_context(int32(canvas), 0, if alpha: 1 else: 0, if desynchronized: 1 else: 0))

proc bitmapContext*(canvas: Node): Node =
  flush()
  Node(qw_context(int32(canvas), 1, 1, 0))

proc replay*(ctx: Node, commands: ptr seq[float64]) =
  ## Plays a recorded Canvas2D command list onto `ctx`.
  flush()
  if commands == nil or commands[].len == 0: return
  qw_replay(int32(ctx), addr commands[][0], int32(commands[].len))

proc putRgba*(ctx: Node, rgba: openArray[byte], width, height: int) =
  flush()
  if rgba.len >= width * height * 4 and width > 0 and height > 0:
    qw_put_rgba(int32(ctx), unsafeAddr rgba[0], int32(width), int32(height))

proc newPresenter*(canvas: Node, canvas2dOnly = false): Node =
  flush()
  Node(qw_presenter(int32(canvas), if canvas2dOnly: 1 else: 0))

proc present*(presenter, source: Node) =
  flush()
  qw_present(int32(presenter), int32(source))

# ----------------------------------------------------------------- events --

var listeners = initTable[int32, proc(e: Event)]()
var nextListener = 1'i32

proc on*(n: Node, kind: string, handler: proc(e: Event), capture = false,
         passive = false, once = false): int32 {.discardable.} =
  ## addEventListener; returns the listener id for `off`.
  result = nextListener
  inc nextListener
  listeners[result] = handler
  var flags = 0'i32
  if capture: flags = flags or 1
  if passive: flags = flags or 2
  if once: flags = flags or 4
  wI32(14); wI32(int32(n)); wSid(kind); wI32(result); wI32(flags)

proc off*(listener: int32) =
  if listener == 0: return
  listeners.del(listener)
  wI32(15); wI32(listener)

proc clientX*(e: Event): float64 = qw_ev_num(0)
proc clientY*(e: Event): float64 = qw_ev_num(1)
proc button*(e: Event): int = int(qw_ev_num(2))
proc buttons*(e: Event): int = int(qw_ev_num(3))
proc modifiers*(e: Event): int = int(qw_ev_num(4))
  ## shift 1, ctrl 2, meta 4, alt 8, touch pointer 16
proc shiftKey*(e: Event): bool = (e.modifiers and 1) != 0
proc ctrlKey*(e: Event): bool = (e.modifiers and 2) != 0
proc metaKey*(e: Event): bool = (e.modifiers and 4) != 0
proc altKey*(e: Event): bool = (e.modifiers and 8) != 0
proc deltaX*(e: Event): float64 = qw_ev_num(5)
proc deltaY*(e: Event): float64 = qw_ev_num(6)
proc pointerId*(e: Event): float64 = qw_ev_num(7)
proc isPrimary*(e: Event): bool = qw_ev_num(8) != 0
proc detail*(e: Event): float64 = qw_ev_num(9)
proc kind*(e: Event): string = takeReply(qw_ev_str(0))
proc key*(e: Event): string = takeReply(qw_ev_str(1))
proc code*(e: Event): string = takeReply(qw_ev_str(2))
proc pointerType*(e: Event): string = takeReply(qw_ev_str(3))
proc data*(e: Event): string = takeReply(qw_ev_str(4))
proc origin*(e: Event): string = takeReply(qw_ev_str(5))
proc target*(e: Event): Node = Node(qw_ev_handle(0))
proc currentTarget*(e: Event): Node = Node(qw_ev_handle(1))
proc relatedTarget*(e: Event): Node = Node(qw_ev_handle(2))
proc dataTransfer*(e: Event): Node = Node(qw_ev_handle(3))
proc source*(e: Event): Node = Node(qw_ev_handle(4))
proc eventObject*(e: Event): Node = Node(qw_ev_handle(5))
proc preventDefault*(e: Event) =
  flush()
  qw_ev_prevent()
proc stopPropagation*(e: Event) =
  flush()
  qw_ev_stop()

# ------------------------------------------------------------------ timers --

var timers = initTable[int32, proc(now: float64)]()
var nextTimer = 1'i32

proc setTimeout*(ms: float64, cb: proc()): int32 {.discardable.} =
  result = nextTimer
  inc nextTimer
  let f = cb
  timers[result] = proc(now: float64) = f()
  flush()
  qw_timeout(result, ms)

proc clearTimeout*(id: int32) =
  if id == 0 or not timers.hasKey(id): return
  timers.del(id)
  qw_clear_timeout(id)

proc requestAnimationFrame*(cb: proc(now: float64)): int32 {.discardable.} =
  result = nextTimer
  inc nextTimer
  timers[result] = cb
  flush()
  qw_raf(result)

proc cancelAnimationFrame*(id: int32) =
  if id == 0 or not timers.hasKey(id): return
  timers.del(id)
  qw_cancel_raf(id)

# --------------------------------------------------------------- async I/O --

type Completion* = proc(ok: bool, data: string, handle: Node)

var pending = initTable[int32, Completion]()
var nextRequest = 1'i32

proc request(cb: Completion): int32 =
  result = nextRequest
  inc nextRequest
  pending[result] = cb

proc fetchBytes*(url: string, cb: proc(ok: bool, data: string), preferCache = false) =
  ## GET `url`; `data` is the body (or the error text when not ok).
  let id = request(proc(ok: bool, data: string, h: Node) = cb(ok, data))
  flush()
  qw_fetch(id, sp(url), int32(url.len), if preferCache: 2 else: 1)

proc fetchBlob*(url: string, cb: proc(ok: bool, blob: Node)) =
  let id = request(proc(ok: bool, data: string, h: Node) = cb(ok, h))
  flush()
  qw_fetch(id, sp(url), int32(url.len), 3)

type BlobRead* = enum brText, brDataUrl, brBytes

proc readBlob*(blob: Node, mode: BlobRead, cb: proc(ok: bool, data: string)) =
  let id = request(proc(ok: bool, data: string, h: Node) = cb(ok, data))
  flush()
  qw_read_blob(id, int32(blob), int32(ord(mode)))

proc newBlob*(data: string, mime: string): Node =
  flush()
  Node(qw_blob(sp(data), int32(data.len), sp(mime), int32(mime.len)))

proc imageBitmap*(source: Node, cb: proc(ok: bool, bitmap: Node)) =
  let id = request(proc(ok: bool, data: string, h: Node) = cb(ok, h))
  flush()
  qw_image_bitmap(id, int32(source))

proc canvasBlob*(canvas: Node, mime: string, cb: proc(ok: bool, blob: Node)) =
  let id = request(proc(ok: bool, data: string, h: Node) = cb(ok, h))
  flush()
  qw_canvas_blob(id, int32(canvas), sp(mime), int32(mime.len))

proc clipboardWrite*(text: string) =
  flush()
  qw_clipboard_write(sp(text), int32(text.len))

proc prompt*(message: string, default = ""): (bool, string) =
  ## window.prompt; (false, "") when cancelled.
  flush()
  let n = qw_prompt(sp(message), int32(message.len), sp(default), int32(default.len))
  if n < 0: (false, "") else: (true, takeReply(n))

proc createObjectURL*(blob: Node): string =
  window.getNode("URL").invoke("createObjectURL", blob).toStr

proc revokeObjectURL*(url: string) =
  window.getNode("URL").call("revokeObjectURL", url)

proc storageGet*(key: string): (bool, string) =
  ## localStorage.getItem; (false, "") when absent or unavailable.
  let r = localStorage.invoke("getItem", key)
  if r.kind == jsString: (true, r.str) else: (false, "")

proc storageSet*(key, value: string): bool =
  ## localStorage.setItem; false when the quota is exceeded.
  flush()
  var buf: seq[byte]
  encodeArg(buf, toArg(key))
  encodeArg(buf, toArg(value))
  const m = "setItem"
  qw_invoke(int32(localStorage), unsafeAddr m[0], int32(m.len), addr buf[0], int32(buf.len), 2) >= 0

# ----------------------------------------------------------------- workers --

var onMessage*: proc(fromId: int32, data: string, handles: seq[Node])
  ## Called for every message from a worker (or, inside a worker, the page).
var onWorkerError*: proc(id: int32)

proc isWorker*(): bool = qw_is_worker() != 0
proc sharedMemory*(): bool = qw_is_shared() != 0
proc hardwareConcurrency*(): int = int(qw_cores())

proc spawnWorker*(kind: int32): int32 =
  ## Starts a worker running this same module; its qw_worker_main(kind)
  ## runs once it has loaded. Returns 0 when workers are unavailable.
  flush()
  qw_worker_new(kind)

proc postMessage*(target: int32, data: string, handles: openArray[Node] = []) =
  ## Sends bytes (and transferable handles) to a worker; target 0 is the
  ## page when called inside a worker.
  flush()
  var hs = newSeq[int32](handles.len)
  for i, h in handles: hs[i] = int32(h)
  qw_post(target, sp(data), int32(data.len),
          (if hs.len == 0: nil else: addr hs[0]), int32(hs.len))

# ----------------------------------------------------------------- exports --

proc qw_alloc(n: int32): pointer {.wexport.} = c_malloc(csize_t(max(n, 1)))

proc copyOut(p: pointer, n: int32): string =
  result = newString(n)
  if n > 0: copyMem(addr result[0], p, n)

proc qw_event(id: int32) {.wexport.} =
  let handler = listeners.getOrDefault(id, nil)
  if handler != nil: handler(Event())
  flush()

proc qw_listeners_released(p: ptr UncheckedArray[int32], n: int32) {.wexport.} =
  for i in 0 ..< n: listeners.del(p[i])
  c_free(p)

proc qw_on_timer(id: int32, now: float64) {.wexport.} =
  let cb = timers.getOrDefault(id, nil)
  timers.del(id)
  if cb != nil: cb(now)
  flush()

proc qw_on_complete(id: int32, failed: int32, p: pointer, n: int32, h: int32) {.wexport.} =
  let data = copyOut(p, n)
  if p != nil: c_free(p)
  let cb = pending.getOrDefault(id, nil)
  pending.del(id)
  if cb != nil: cb(failed == 0, data, Node(h))
  flush()

proc qw_on_message(fromId: int32, p: pointer, n: int32, hp: ptr UncheckedArray[int32], hc: int32) {.wexport.} =
  let data = copyOut(p, n)
  if p != nil: c_free(p)
  var handles: seq[Node]
  for i in 0 ..< hc: handles.add Node(hp[i])
  if hp != nil: c_free(hp)
  if onMessage != nil: onMessage(fromId, data, handles)
  flush()

proc qw_on_worker_error(id: int32) {.wexport.} =
  if onWorkerError != nil: onWorkerError(id)
  flush()
