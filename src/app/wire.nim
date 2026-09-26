## Messages between the page and its Nim workers: a JSON header followed
## by an optional raw byte payload (pixels, file bytes), so bulk data never
## goes through JSON.

import ../jsval

proc packMessage*(header: Val, payload = ""): string =
  let json = toJson(header)
  let n = uint32(json.len)
  result = newStringOfCap(4 + json.len + payload.len)
  result.add char(n and 0xFF)
  result.add char((n shr 8) and 0xFF)
  result.add char((n shr 16) and 0xFF)
  result.add char((n shr 24) and 0xFF)
  result.add json
  result.add payload

proc unpackMessage*(data: string): (Val, string) =
  if data.len < 4: return (nil, "")
  let n = int(uint32(data[0]) or (uint32(data[1]) shl 8) or (uint32(data[2]) shl 16) or
              (uint32(data[3]) shl 24))
  if 4 + n > data.len: return (nil, "")
  var header: Val = nil
  try: header = parseJson(data[4 ..< 4 + n])
  except JsonError: return (nil, "")
  (header, data[4 + n .. ^1])

import std/tables
import ../web/qweb

const
  WorkerRender* = 1'i32   ## scene painter on an OffscreenCanvas
  WorkerGif* = 2'i32      ## GIF decoding

type WorkerHandler* = proc(header: Val, payload: string, handles: seq[Node])

var workerHandlers = initTable[int32, WorkerHandler]()
var workerErrors = initTable[int32, proc()]()
var pageHandler: WorkerHandler

proc dispatchMessage(fromId: int32, data: string, handles: seq[Node]) =
  let (header, payload) = unpackMessage(data)
  if header == nil: return
  if fromId == 0:
    if pageHandler != nil: pageHandler(header, payload, handles)
  else:
    let h = workerHandlers.getOrDefault(fromId, nil)
    if h != nil: h(header, payload, handles)

proc startWorker*(kind: int32, handler: WorkerHandler, onError: proc() = nil): int32 =
  ## Spawns a Nim worker; returns 0 when workers are unavailable.
  result = spawnWorker(kind)
  if result == 0: return
  workerHandlers[result] = handler
  if onError != nil: workerErrors[result] = onError
  onMessage = dispatchMessage
  onWorkerError = proc(id: int32) =
    let e = workerErrors.getOrDefault(id, nil)
    if e != nil: e()

proc onPageMessage*(handler: WorkerHandler) =
  ## Inside a worker: messages from the page.
  pageHandler = handler
  onMessage = dispatchMessage

proc send*(target: int32, header: Val, payload = "", handles: openArray[Node] = []) =
  postMessage(target, packMessage(header, payload), handles)

proc obj2s*(k1, v1, k2, v2: string): Val =
  result = newObj()
  result.put(k1, jstr(v1))
  result.put(k2, jstr(v2))

proc typeMsg*(kind: string): Val =
  result = newObj()
  result.put("type", jstr(kind))
