## GIF87a/89a decoder.
##
## The parse pass only records where each frame's LZW data lives; frames are
## decoded one at a time, on demand, into a single composited RGBA canvas.
## A 12 MB animation therefore costs one frame of work per step instead of
## hundreds of megabytes of decoded pixels held at once. Runs in a worker.

import std/strutils

const
  DisposalBackground = 2
  DisposalPrevious = 3

type
  GifFrame = object
    x, y, width, height: int
    delay, disposal, transparent: int
    palette: seq[byte]
    interlaced: bool
    minCodeSize: int
    ranges: seq[(int, int)]

  GifInfo = object
    width*, height*: int
    frames: seq[GifFrame]
    loopCount*: int
    backgroundIndex: int

  GifSequence* = ref object
    bytes: string
    info*: GifInfo
    valid*: bool
    index: int
    rgba*: seq[byte]
    previous: seq[byte]

  GifFrameOut* = object
    index*, delay*, width*, height*: int

template b(s: string, i: int): int = (if i < s.len: int(s[i]) else: 0)

proc readSubBlocks(bytes: string, offset0: int): (seq[(int, int)], int) =
  var offset = offset0
  var ranges: seq[(int, int)]
  while offset < bytes.len:
    let size = b(bytes, offset)
    inc offset
    if size == 0: break
    ranges.add (offset, offset + size)
    offset += size
  (ranges, offset)

proc readPalette(bytes: string, offset, count: int): seq[byte] =
  result = newSeq[byte](count * 3)
  for i in 0 ..< count * 3: result[i] = byte(b(bytes, offset + i))

proc parse(bytes: string): (bool, GifInfo) =
  if bytes.len < 13: return (false, GifInfo())
  if not (bytes[0] == 'G' and bytes[1] == 'I' and bytes[2] == 'F'): return (false, GifInfo())
  var info = GifInfo(width: b(bytes, 6) or (b(bytes, 7) shl 8),
                     height: b(bytes, 8) or (b(bytes, 9) shl 8),
                     backgroundIndex: b(bytes, 11))
  let flags = b(bytes, 10)
  var offset = 13
  var globalPalette: seq[byte]
  if (flags and 0x80) != 0:
    let size = 1 shl ((flags and 0x07) + 1)
    globalPalette = readPalette(bytes, offset, size)
    offset += size * 3

  var pendingDelay = 100
  var pendingDisposal = 0
  var pendingTransparent = -1

  while offset < bytes.len:
    let blk = b(bytes, offset)
    if blk == 0x3B: break
    if blk == 0x21:
      let label = b(bytes, offset + 1)
      offset += 2
      if label == 0xF9:
        let size = b(bytes, offset)
        let packed = b(bytes, offset + 1)
        let delay = (b(bytes, offset + 2) or (b(bytes, offset + 3) shl 8)) * 10
        pendingDisposal = (packed shr 2) and 0x07
        pendingTransparent = if (packed and 0x01) != 0: b(bytes, offset + 4) else: -1
        # Browsers clamp absurdly fast GIFs the same way.
        pendingDelay = if delay < 20: 100 else: delay
        offset += size + 1
        offset = readSubBlocks(bytes, offset)[1]
      elif label == 0xFF:
        let appBlockSize = b(bytes, offset)
        var appName = ""
        var a = 1
        while a <= 11 and a <= appBlockSize:
          appName.add char(b(bytes, offset + a))
          inc a
        let (ranges, e) = readSubBlocks(bytes, offset + appBlockSize + 1)
        if appName.len >= 8 and appName[0 ..< 8] == "NETSCAPE" and ranges.len > 0:
          let start = ranges[0][0]
          info.loopCount = b(bytes, start + 1) or (b(bytes, start + 2) shl 8)
        offset = e
      else:
        offset = readSubBlocks(bytes, offset)[1]
      continue
    if blk == 0x2C:
      var frame = GifFrame(
        x: b(bytes, offset + 1) or (b(bytes, offset + 2) shl 8),
        y: b(bytes, offset + 3) or (b(bytes, offset + 4) shl 8),
        width: b(bytes, offset + 5) or (b(bytes, offset + 6) shl 8),
        height: b(bytes, offset + 7) or (b(bytes, offset + 8) shl 8),
        delay: pendingDelay, disposal: pendingDisposal, transparent: pendingTransparent,
        palette: globalPalette)
      let localFlags = b(bytes, offset + 9)
      frame.interlaced = (localFlags and 0x40) != 0
      offset += 10
      if (localFlags and 0x80) != 0:
        let size = 1 shl ((localFlags and 0x07) + 1)
        frame.palette = readPalette(bytes, offset, size)
        offset += size * 3
      frame.minCodeSize = b(bytes, offset)
      inc offset
      let (ranges, e) = readSubBlocks(bytes, offset)
      frame.ranges = ranges
      offset = e
      info.frames.add frame
      pendingDelay = 100
      pendingDisposal = 0
      pendingTransparent = -1
      continue
    inc offset                                   # skip junk

  (info.frames.len > 0, info)

proc decodeIndices(bytes: string, frame: GifFrame): seq[byte] =
  ## GIF variable-width LZW.
  var data: seq[byte]
  for (a, e) in frame.ranges:
    for i in a ..< min(e, bytes.len): data.add byte(bytes[i])
  let pixelCount = frame.width * frame.height
  result = newSeq[byte](pixelCount)
  let minCodeSize = frame.minCodeSize
  let clearCode = 1 shl minCodeSize
  let endCode = clearCode + 1
  var codeSize = minCodeSize + 1
  var nextCode = endCode + 1
  const maxEntries = 4096
  var prefix: array[maxEntries, int32]
  var suffix: array[maxEntries, byte]
  var pixelStack: array[maxEntries + 1, byte]
  for i in 0 ..< min(clearCode, maxEntries):
    prefix[i] = -1
    suffix[i] = byte(i and 0xFF)
  var bitBuffer = 0
  var bitCount = 0
  var position = 0
  var outPos = 0
  var previous = -1
  var top = 0
  while outPos < pixelCount:
    if bitCount < codeSize:
      if position >= data.len: break
      bitBuffer = bitBuffer or (int(data[position]) shl bitCount)
      bitCount += 8
      inc position
      continue
    let code = bitBuffer and ((1 shl codeSize) - 1)
    bitBuffer = bitBuffer shr codeSize
    bitCount -= codeSize
    if code == clearCode:
      codeSize = minCodeSize + 1
      nextCode = endCode + 1
      previous = -1
      continue
    if code == endCode: break
    var current = code
    if code >= nextCode:
      if previous < 0: break
      pixelStack[top] = suffix[previous]
      inc top
      current = previous
    while current >= clearCode:
      pixelStack[top] = suffix[current]
      inc top
      current = prefix[current]
      if current < 0 or top > maxEntries:
        current = 0
        break
    pixelStack[top] = suffix[current]
    inc top
    while top > 0 and outPos < pixelCount:
      dec top
      result[outPos] = pixelStack[top]
      inc outPos
    if previous >= 0 and nextCode < maxEntries:
      prefix[nextCode] = int32(previous)
      suffix[nextCode] = suffix[current]
      inc nextCode
      if (nextCode and (nextCode - 1)) == 0 and nextCode < maxEntries: inc codeSize
    previous = code

proc composite(rgba: var seq[byte], canvasWidth: int, frame: GifFrame, indices: seq[byte]) =
  if frame.palette.len == 0: return
  var rows: seq[int]
  if frame.interlaced:
    for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)]:
      var y = start
      while y < frame.height:
        rows.add y
        y += step
  else:
    for y in 0 ..< frame.height: rows.add y
  for r, targetRow in rows:
    for x in 0 ..< frame.width:
      let idx = r * frame.width + x
      if idx >= indices.len: continue
      let index = int(indices[idx])
      if index == frame.transparent: continue
      let target = ((frame.y + targetRow) * canvasWidth + (frame.x + x)) * 4
      if target < 0 or target + 3 >= rgba.len: continue
      if index * 3 + 2 >= frame.palette.len: continue
      rgba[target] = frame.palette[index * 3]
      rgba[target + 1] = frame.palette[index * 3 + 1]
      rgba[target + 2] = frame.palette[index * 3 + 2]
      rgba[target + 3] = 255

proc clearRect(rgba: var seq[byte], canvasWidth: int, frame: GifFrame) =
  for y in 0 ..< frame.height:
    for x in 0 ..< frame.width:
      let target = ((frame.y + y) * canvasWidth + (frame.x + x)) * 4
      if target < 0 or target + 3 >= rgba.len: continue
      rgba[target] = 0
      rgba[target + 1] = 0
      rgba[target + 2] = 0
      rgba[target + 3] = 0

proc newGifSequence*(bytes: string): GifSequence =
  result = GifSequence(bytes: bytes, index: -1)
  let (ok, info) = parse(bytes)
  result.valid = ok
  result.info = info
  if ok: result.rgba = newSeq[byte](info.width * info.height * 4)

proc frameCount*(s: GifSequence): int = (if s.valid: s.info.frames.len else: 0)

proc next*(s: GifSequence): (GifFrameOut, seq[byte]) =
  ## Advances to the next frame and returns it with a copy of its pixels.
  let count = s.info.frames.len
  let nextIndex = (s.index + 1) mod count
  let frame = s.info.frames[nextIndex]
  # Looping restarts from a clean canvas.
  if nextIndex == 0:
    for i in 0 ..< s.rgba.len: s.rgba[i] = 0
  if frame.disposal == DisposalPrevious: s.previous = s.rgba
  composite(s.rgba, s.info.width, frame, decodeIndices(s.bytes, frame))
  let pixels = s.rgba
  # Apply the disposal for the frame just shown, ready for the next.
  if frame.disposal == DisposalBackground: clearRect(s.rgba, s.info.width, frame)
  elif frame.disposal == DisposalPrevious and s.previous.len == s.rgba.len:
    s.rgba = s.previous
  s.index = nextIndex
  (GifFrameOut(index: nextIndex, delay: frame.delay, width: s.info.width,
               height: s.info.height), pixels)

proc bytesAreAnimated*(bytes: string): bool =
  ## GIF with more than one frame, APNG (acTL before IDAT), animated WebP.
  if bytes.len < 16: return false
  if bytes[0] == 'G' and bytes[1] == 'I' and bytes[2] == 'F':
    var frames = 0
    for i in 0 ..< bytes.len - 3:
      if bytes[i] == '\x21' and bytes[i + 1] == '\xF9' and bytes[i + 2] == '\x04':
        inc frames
        if frames > 1: return true
    return false
  let head = bytes[0 ..< min(bytes.len, 4096)]
  if bytes[0] == '\x89' and bytes[1] == 'P':
    let actl = head.find("acTL")
    let idat = head.find("IDAT")
    return actl >= 0 and (idat < 0 or actl < idat)
  if head.find("RIFF") == 0 and head.find("WEBP") == 8:
    return head.find("ANIM") > 0
  false

