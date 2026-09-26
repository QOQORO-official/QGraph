## JavaScript built-in semantics the ported code relies on, reproduced
## exactly: Number(), parseFloat(), encodeURIComponent/decodeURIComponent,
## String(number) and a few string helpers.

import std/[strutils, math]
import ../host, ../jsval

type URIError* = object of CatchableError

proc jsNumber*(s: string): float64 = hostParseNum(s)
  ## Number(s) for a string.

proc jsNumberOrNull*(present: bool, s: string): float64 =
  ## Number(getAttribute(...)): null reads as 0.
  if not present: 0.0 else: hostParseNum(s)

proc jsStr*(x: float64): string = jsNumStr(x)
  ## String(number).

proc isFiniteJs*(x: float64): bool = x == x and x != Inf and x != -Inf

proc jsParseFloat*(s: string): float64 =
  ## parseFloat(s): the longest numeric prefix after leading whitespace.
  var i = 0
  while i < s.len and s[i] in {' ', '\t', '\n', '\r', '\f', '\v'}: inc i
  let start = i
  if i < s.len and s[i] in {'+', '-'}: inc i
  if s.continuesWith("Infinity", i):
    return if start < s.len and s[start] == '-': -Inf else: Inf
  var digits = 0
  while i < s.len and s[i] in {'0'..'9'}:
    inc i
    inc digits
  if i < s.len and s[i] == '.':
    inc i
    while i < s.len and s[i] in {'0'..'9'}:
      inc i
      inc digits
  if digits == 0: return NaN
  if i < s.len and s[i] in {'e', 'E'}:
    var j = i + 1
    if j < s.len and s[j] in {'+', '-'}: inc j
    if j < s.len and s[j] in {'0'..'9'}:
      while j < s.len and s[j] in {'0'..'9'}: inc j
      i = j
  hostParseNum(s[start ..< i])

const UriUnreserved = {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')'}

proc encodeURIComponent*(s: string): string =
  const hex = "0123456789ABCDEF"
  for c in s:
    if c in UriUnreserved: result.add c
    else:
      result.add '%'
      result.add hex[ord(c) shr 4]
      result.add hex[ord(c) and 15]

proc encodeURI*(s: string): string =
  const hex = "0123456789ABCDEF"
  const keep = UriUnreserved + {';', ',', '/', '?', ':', '@', '&', '=', '+', '$', '#'}
  for c in s:
    if c in keep: result.add c
    else:
      result.add '%'
      result.add hex[ord(c) shr 4]
      result.add hex[ord(c) and 15]

proc hexVal(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc escByte(s: string, i: int): int =
  if i + 2 > s.len - 1: raise newException(URIError, "URI malformed")
  let h1 = hexVal(s[i + 1])
  let h2 = hexVal(s[i + 2])
  if h1 < 0 or h2 < 0: raise newException(URIError, "URI malformed")
  h1 * 16 + h2

proc decodeURIComponent*(s: string): string =
  ## Raises URIError on a malformed escape or invalid UTF-8, as JS does.
  var i = 0
  while i < s.len:
    let c = s[i]
    if c != '%':
      result.add c
      inc i
      continue
    let b0 = escByte(s, i)
    i += 3
    if b0 < 0x80:
      result.add char(b0)
      continue
    let need = if (b0 and 0xE0) == 0xC0: 1
               elif (b0 and 0xF0) == 0xE0: 2
               elif (b0 and 0xF8) == 0xF0: 3
               else: raise newException(URIError, "URI malformed")
    result.add char(b0)
    for t in 1 .. need:
      if i >= s.len or s[i] != '%': raise newException(URIError, "URI malformed")
      let bt = escByte(s, i)
      if (bt and 0xC0) != 0x80: raise newException(URIError, "URI malformed")
      result.add char(bt)
      i += 3

proc tryDecodeURIComponent*(s: string): string =
  ## decodeURIComponent, keeping the input when it is malformed.
  try: decodeURIComponent(s)
  except URIError: s

proc containsIgnoreCase*(s, sub: string): bool =
  s.toLowerAscii().contains(sub.toLowerAscii())

proc replaceAllLit*(s, a, b: string): string = s.replace(a, b)

proc escapeAttrXml*(value: string): string =
  ## & < > " and newline, as MxGraphFormat.escapeAttr.
  for c in value:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\n': result.add "&#10;"
    else: result.add c

proc escapeHtml*(value: string): string =
  for c in value:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    else: result.add c

proc jsonStringify*(v: Val): string = toJson(v)

proc jsNumOr*(v: Val, d: float64): float64 =
  ## Number(v) || d
  let n = num(v)
  if n != n or n == 0: d else: n

proc mapOnes*(s: seq[float64]): seq[float64] =
  result = newSeq[float64](s.len)
  for i in 0 ..< s.len: result[i] = 1

# ------------------------------------------------------------------ base64 --

const b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

proc b64val(c: char): int =
  case c
  of 'A'..'Z': ord(c) - ord('A')
  of 'a'..'z': ord(c) - ord('a') + 26
  of '0'..'9': ord(c) - ord('0') + 52
  of '+', '-': 62
  of '/', '_': 63
  else: -1

proc base64Decode*(s: string, start = 0, stop = -1): string =
  ## atob(), skipping whitespace; stops at padding.
  let e = if stop < 0: s.len else: min(stop, s.len)
  result = newStringOfCap((e - start) * 3 div 4 + 3)
  var acc = 0
  var bits = 0
  for i in start ..< e:
    let c = s[i]
    if c == '=': break
    let v = b64val(c)
    if v < 0: continue
    acc = (acc shl 6) or v
    bits += 6
    if bits >= 8:
      bits -= 8
      result.add char((acc shr bits) and 0xFF)

proc base64Encode*(data: string): string =
  result = newStringOfCap((data.len + 2) div 3 * 4)
  var i = 0
  while i + 2 < data.len:
    let n = (ord(data[i]) shl 16) or (ord(data[i + 1]) shl 8) or ord(data[i + 2])
    result.add b64chars[(n shr 18) and 63]
    result.add b64chars[(n shr 12) and 63]
    result.add b64chars[(n shr 6) and 63]
    result.add b64chars[n and 63]
    i += 3
  let rest = data.len - i
  if rest == 1:
    let n = ord(data[i]) shl 16
    result.add b64chars[(n shr 18) and 63]
    result.add b64chars[(n shr 12) and 63]
    result.add "=="
  elif rest == 2:
    let n = (ord(data[i]) shl 16) or (ord(data[i + 1]) shl 8)
    result.add b64chars[(n shr 18) and 63]
    result.add b64chars[(n shr 12) and 63]
    result.add b64chars[(n shr 6) and 63]
    result.add '='

proc decodeDataUri*(src: string): (bool, string, string) =
  ## (ok, mime, bytes) of a data: URI.
  let comma = src.find(',')
  if comma < 0: return (false, "", "")
  let meta = src[0 ..< comma]
  let lower = meta.toLowerAscii()
  let mime = block:
    let semi = meta.find(';')
    if semi > 5: meta[5 ..< semi] elif meta.len > 5: meta[5 .. ^1] else: ""
  if lower.contains(";base64"): (true, mime, base64Decode(src, comma + 1))
  else:
    try: (true, mime, decodeURIComponent(src[comma + 1 .. ^1]))
    except URIError: (false, mime, "")

# --------------------------------------------------------------------- URL --

type Url* = object
  ok*: bool
  protocol*, host*, pathname*, search*, hash*: string

proc parseAbsoluteUrl*(value: string): Url =
  ## Enough of the URL parser for absolute http(s)-like URLs.
  let v = jsTrim(value)
  var i = 0
  if i >= v.len or v[i] notin {'a'..'z', 'A'..'Z'}: return
  while i < v.len and v[i] in {'a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.'}: inc i
  if i >= v.len or v[i] != ':': return
  result.protocol = v[0 .. i].toLowerAscii()
  inc i
  var rest = v[i .. ^1]
  let hashAt = rest.find('#')
  if hashAt >= 0:
    result.hash = rest[hashAt .. ^1]
    rest = rest[0 ..< hashAt]
  let queryAt = rest.find('?')
  if queryAt >= 0:
    result.search = rest[queryAt .. ^1]
    rest = rest[0 ..< queryAt]
  if rest.startsWith("//"):
    rest = rest[2 .. ^1]
    let slash = rest.find('/')
    var authority = if slash < 0: rest else: rest[0 ..< slash]
    result.pathname = if slash < 0: "/" else: rest[slash .. ^1]
    let at = authority.rfind('@')
    if at >= 0: authority = authority[at + 1 .. ^1]
    let colon = authority.rfind(':')
    if colon >= 0 and not authority.endsWith("]"): authority = authority[0 ..< colon]
    result.host = authority.toLowerAscii()
  else:
    result.pathname = rest
  result.ok = true

proc formDecode(s: string): string =
  tryDecodeURIComponent(s.replace('+', ' '))

proc searchParam*(query: string, name: string): (bool, string) =
  ## URLSearchParams(query).get(name)
  var q = query
  if q.startsWith("?"): q = q[1 .. ^1]
  for part in q.split('&'):
    if part.len == 0: continue
    let eq = part.find('=')
    let key = formDecode(if eq < 0: part else: part[0 ..< eq])
    if key == name: return (true, if eq < 0: "" else: formDecode(part[eq + 1 .. ^1]))
  (false, "")

proc toFixed*(x: float64, digits: int): string =
  ## Number.prototype.toFixed for the small magnitudes the UI shows.
  if x != x: return "NaN"
  var scale = 1.0
  for i in 0 ..< digits: scale *= 10
  let neg = x < 0
  let scaled = floor(abs(x) * scale + 0.5)
  let whole = floor(scaled / scale)
  var frac = scaled - whole * scale
  result = (if neg and scaled != 0: "-" else: "") & jsNumStr(whole)
  if digits > 0:
    var fracDigits = jsNumStr(frac)
    while fracDigits.len < digits: fracDigits = "0" & fracDigits
    result.add "." & fracDigits
