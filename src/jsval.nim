## JavaScript-semantics dynamic values.
##
## The editor's document model is plain JSON: every scene item is an object
## with whatever keys its shape needs, cloned through JSON for undo, and read
## with JavaScript's coercions (`node.rotation || 0`, `x == null`, Number()).
## Porting that model faithfully means keeping those semantics, so this module
## provides a small JS value type:
##
## * `nil` is `undefined`; `jnull` is `null`.
## * Objects keep insertion order and use interned keys (atoms), so a property
##   lookup is an integer compare over a short list.
## * Objects and arrays are references, exactly like JS, so aliasing behaves
##   the same way (`node.cells[key] = cell` mutates the shared table).
## * `parseJson`/`toJson` reproduce JSON.parse / JSON.stringify, including
##   `JSON.stringify(value, null, 2)` for saved documents.

import std/[tables, math, algorithm]
import host

type
  VKind* = enum vNull, vBool, vNum, vStr, vArr, vObj
  Val* = ref ValObj
  ValObj* = object
    case kind*: VKind
    of vNull: discard
    of vBool: b*: bool
    of vNum: n*: float64
    of vStr: s*: string
    of vArr: a*: seq[Val]
    of vObj:
      ks*: seq[int32]
      vs*: seq[Val]

  JsonError* = object of CatchableError

# ---------------------------------------------------------------- atoms --

var atomNames: seq[string]
var atomIds = initTable[string, int32]()

proc atom*(name: string): int32 =
  result = atomIds.getOrDefault(name, -1)
  if result < 0:
    result = int32(atomNames.len)
    atomNames.add name
    atomIds[name] = result

proc atomName*(id: int32): lent string {.inline.} = atomNames[id]

template atomOf*(key: static string): int32 =
  ## Per-call-site cached atom for a literal key.
  block:
    var cache {.global.} = -1'i32
    if cache < 0: cache = atom(key)
    cache

# ----------------------------------------------------------- construct --

let jnull*: Val = Val(kind: vNull)
let jtrue*: Val = Val(kind: vBool, b: true)
let jfalse*: Val = Val(kind: vBool, b: false)

proc jnum*(n: float64): Val {.inline.} = Val(kind: vNum, n: n)
proc jnum*(n: int): Val {.inline.} = Val(kind: vNum, n: float64(n))
proc jstr*(s: string): Val {.inline.} = Val(kind: vStr, s: s)
proc jbool*(b: bool): Val {.inline.} = (if b: jtrue else: jfalse)
proc newObj*(): Val {.inline.} = Val(kind: vObj)
proc newArr*(): Val {.inline.} = Val(kind: vArr)
proc newArr*(items: openArray[Val]): Val =
  result = Val(kind: vArr)
  for it in items: result.a.add it

template `%`*(n: float64): Val = jnum(n)
template `%`*(n: int): Val = jnum(n)
template `%`*(s: string): Val = jstr(s)
template `%`*(b: bool): Val = jbool(b)

# --------------------------------------------------------------- kinds --

proc isUndef*(v: Val): bool {.inline.} = v == nil
proc nullish*(v: Val): bool {.inline.} = v == nil or v.kind == vNull
proc isObj*(v: Val): bool {.inline.} = v != nil and v.kind == vObj
proc isArr*(v: Val): bool {.inline.} = v != nil and v.kind == vArr
proc isStr*(v: Val): bool {.inline.} = v != nil and v.kind == vStr
proc isNum*(v: Val): bool {.inline.} = v != nil and v.kind == vNum
proc isBool*(v: Val): bool {.inline.} = v != nil and v.kind == vBool

# ------------------------------------------------------------- objects --

proc findKey(v: Val, k: int32): int {.inline.} =
  for i in 0 ..< v.ks.len:
    if v.ks[i] == k: return i
  -1

proc getA*(v: Val, k: int32): Val {.inline.} =
  if v == nil or v.kind != vObj: return nil
  let i = findKey(v, k)
  if i < 0: nil else: v.vs[i]

proc setA*(v: Val, k: int32, x: Val) =
  if v == nil or v.kind != vObj: return
  let i = findKey(v, k)
  if i < 0:
    v.ks.add k
    v.vs.add x
  else:
    v.vs[i] = x

proc delA*(v: Val, k: int32) =
  if v == nil or v.kind != vObj: return
  let i = findKey(v, k)
  if i >= 0:
    v.ks.delete(i)
    v.vs.delete(i)

proc hasA*(v: Val, k: int32): bool =
  v != nil and v.kind == vObj and findKey(v, k) >= 0

template `[]`*(v: Val, key: static string): Val = getA(v, atomOf(key))
template `[]=`*(v: Val, key: static string, x: Val) = setA(v, atomOf(key), x)
template del*(v: Val, key: static string) = delA(v, atomOf(key))
template has*(v: Val, key: static string): bool = hasA(v, atomOf(key))

proc get*(v: Val, key: string): Val = getA(v, atom(key))
proc put*(v: Val, key: string, x: Val) = setA(v, atom(key), x)
proc remove*(v: Val, key: string) = delA(v, atom(key))
proc hasKey*(v: Val, key: string): bool = hasA(v, atom(key))

iterator pairs*(v: Val): (string, Val) =
  if v != nil and v.kind == vObj:
    var i = 0
    while i < v.ks.len:
      yield (atomNames[v.ks[i]], v.vs[i])
      inc i

proc keys*(v: Val): seq[string] =
  ## Object.keys: own keys in insertion order (undefined values included).
  if v != nil and v.kind == vObj:
    for k in v.ks: result.add atomNames[k]

# -------------------------------------------------------------- arrays --

proc len*(v: Val): int {.inline.} =
  if v == nil: 0
  elif v.kind == vArr: v.a.len
  elif v.kind == vStr: v.s.len
  else: 0

proc `[]`*(v: Val, i: int): Val {.inline.} =
  if v == nil or v.kind != vArr or i < 0 or i >= v.a.len: nil else: v.a[i]

proc `[]=`*(v: Val, i: int, x: Val) =
  if v == nil or v.kind != vArr or i < 0: return
  while v.a.len <= i: v.a.add nil
  v.a[i] = x

proc push*(v: Val, x: Val) {.inline.} =
  if v != nil and v.kind == vArr: v.a.add x

iterator items*(v: Val): Val =
  if v != nil and v.kind == vArr:
    var i = 0
    while i < v.a.len:
      yield v.a[i]
      inc i

# ------------------------------------------------------------ coercion --

proc truthy*(v: Val): bool =
  if v == nil: return false
  case v.kind
  of vNull: false
  of vBool: v.b
  of vNum: v.n != 0 and v.n == v.n
  of vStr: v.s.len > 0
  of vArr, vObj: true

proc isWs(c: char): bool {.inline.} =
  c in {' ', '\t', '\n', '\r', '\f', '\v'}

proc jsTrim*(s: string): string =
  ## String.prototype.trim for the ASCII and NBSP whitespace the editor sees.
  var a = 0
  var b = s.len - 1
  while a <= b:
    if isWs(s[a]): inc a
    elif a + 1 <= b and s[a] == '\xC2' and s[a+1] == '\xA0': a += 2
    else: break
  while b >= a:
    if isWs(s[b]): dec b
    elif b - 1 >= a and s[b-1] == '\xC2' and s[b] == '\xA0': b -= 2
    else: break
  if b < a: "" else: s[a .. b]

proc parseNumStr*(s: string): float64 =
  ## Number(string): trimmed, empty -> 0, invalid -> NaN.
  let t = jsTrim(s)
  if t.len == 0: return 0.0
  # Fast path for plain decimal integers.
  var neg = false
  var i = 0
  if t[0] == '-' or t[0] == '+':
    neg = t[0] == '-'
    i = 1
  if i < t.len and t.len - i <= 15:
    var acc = 0'i64
    var ok = true
    for j in i ..< t.len:
      if t[j] in {'0'..'9'}: acc = acc * 10 + int64(ord(t[j]) - 48)
      else:
        ok = false
        break
    if ok:
      return (if neg: -float64(acc) else: float64(acc))
  hostParseNum(t)

proc num*(v: Val): float64 =
  ## Number(v).
  if v == nil: return NaN
  case v.kind
  of vNull: 0.0
  of vBool: (if v.b: 1.0 else: 0.0)
  of vNum: v.n
  of vStr: parseNumStr(v.s)
  of vArr:
    if v.a.len == 0: 0.0
    elif v.a.len == 1: num(v.a[0])
    else: NaN
  of vObj: NaN

proc jsNumStr*(n: float64): string =
  ## Number.prototype.toString().
  if n != n: return "NaN"
  if n == Inf: return "Infinity"
  if n == -Inf: return "-Infinity"
  if n == 0.0: return "0"
  if abs(n) < 1e15 and n == floor(n):
    var x = int64(abs(n))
    var buf: array[24, char]
    var p = buf.len
    while x > 0:
      dec p
      buf[p] = char(48 + int(x mod 10))
      x = x div 10
    if n < 0:
      dec p
      buf[p] = '-'
    result = newString(buf.len - p)
    for i in p ..< buf.len: result[i - p] = buf[i]
    return
  hostFormatNum(n)

proc str*(v: Val): string

proc arrJoin*(v: Val, sep: string): string =
  var first = true
  for x in v:
    if not first: result.add sep
    first = false
    if not nullish(x): result.add str(x)

proc str*(v: Val): string =
  ## String(v).
  if v == nil: return "undefined"
  case v.kind
  of vNull: "null"
  of vBool: (if v.b: "true" else: "false")
  of vNum: jsNumStr(v.n)
  of vStr: v.s
  of vArr: arrJoin(v, ",")
  of vObj: "[object Object]"

proc strictEq*(a, b: Val): bool =
  ## a === b
  if a == nil or b == nil: return a == nil and b == nil
  if a.kind != b.kind: return false
  case a.kind
  of vNull: true
  of vBool: a.b == b.b
  of vNum: a.n == b.n
  of vStr: a.s == b.s
  of vArr, vObj: a == b

proc looseEq*(a, b: Val): bool =
  ## a == b (enough of it for the editor's comparisons).
  if nullish(a) or nullish(b): return nullish(a) and nullish(b)
  if a.kind == b.kind: return strictEq(a, b)
  if a.kind in {vArr, vObj} or b.kind in {vArr, vObj}:
    return str(a) == str(b)
  num(a) == num(b)

proc isStrVal*(v: Val, s: string): bool {.inline.} =
  ## v === 'literal'
  v != nil and v.kind == vStr and v.s == s

proc isTrue*(v: Val): bool {.inline.} =
  ## v === true
  v != nil and v.kind == vBool and v.b

proc isFalse*(v: Val): bool {.inline.} =
  ## v === false
  v != nil and v.kind == vBool and not v.b

# --------------------------------------------- property access helpers --

template fo*(v: Val, key: static string, d: float64): float64 =
  ## `v.key || d` in a numeric context.
  (let tmpv = getA(v, atomOf(key)); if truthy(tmpv): num(tmpv) else: float64(d))

template nn*(v: Val, key: static string, d: float64): float64 =
  ## `v.key == null ? d : Number(v.key)`
  (let tmpv = getA(v, atomOf(key)); if nullish(tmpv): float64(d) else: num(tmpv))

template nor*(v: Val, key: static string, d: float64): float64 =
  ## `Number(v.key) || d`
  (let tmpx = num(getA(v, atomOf(key))); if tmpx == tmpx and tmpx != 0: tmpx else: float64(d))

template nm*(v: Val, key: static string): float64 =
  ## Number(v.key)
  num(getA(v, atomOf(key)))

template st*(v: Val, key: static string): string =
  ## `v.key` used as a string where it is known to be one (else "").
  (let tmpv = getA(v, atomOf(key)); if tmpv != nil and tmpv.kind == vStr: tmpv.s else: "")

template so*(v: Val, key: static string, d: string): string =
  ## `v.key || 'd'` as a string.
  (let tmpv = getA(v, atomOf(key)); if truthy(tmpv): str(tmpv) else: d)

template tr*(v: Val, key: static string): bool =
  ## truthiness of v.key
  truthy(getA(v, atomOf(key)))

template nul*(v: Val, key: static string): bool =
  ## v.key == null
  nullish(getA(v, atomOf(key)))

template eqs*(v: Val, key: static string, lit: string): bool =
  ## v.key === 'lit'
  isStrVal(getA(v, atomOf(key)), lit)

template setn*(v: Val, key: static string, x: float64) =
  setA(v, atomOf(key), jnum(x))

template sets*(v: Val, key: static string, x: string) =
  setA(v, atomOf(key), jstr(x))

template setb*(v: Val, key: static string, x: bool) =
  setA(v, atomOf(key), jbool(x))

proc idOf*(v: Val): string =
  ## String(item.id)
  let x = v["id"]
  if x == nil: "" elif x.kind == vStr: x.s else: str(x)

# ---------------------------------------------------------------- clone --

proc clone*(v: Val): Val =
  ## JSON.parse(JSON.stringify(v)): drops undefined object values, turns
  ## non-finite numbers into null.
  if v == nil: return nil
  case v.kind
  of vNull, vBool, vStr: result = v
  of vNum:
    result = if v.n != v.n or v.n == Inf or v.n == -Inf: jnull else: v
  of vArr:
    result = Val(kind: vArr)
    result.a = newSeqOfCap[Val](v.a.len)
    for x in v.a:
      result.a.add(if x == nil: jnull else: clone(x))
  of vObj:
    result = Val(kind: vObj)
    for i in 0 ..< v.ks.len:
      if v.vs[i] != nil:
        result.ks.add v.ks[i]
        result.vs.add clone(v.vs[i])

proc assign*(target, source: Val) =
  ## Object.assign(target, source)
  if target == nil or target.kind != vObj or source == nil or source.kind != vObj: return
  for i in 0 ..< source.ks.len:
    setA(target, source.ks[i], source.vs[i])

proc shallowCopy*(v: Val): Val =
  if v == nil: return nil
  case v.kind
  of vArr:
    result = Val(kind: vArr, a: v.a)
  of vObj:
    result = Val(kind: vObj, ks: v.ks, vs: v.vs)
  else: result = v

# ----------------------------------------------------------------- JSON --

proc addUtf8(s: var string, cp: int) =
  if cp < 0x80: s.add char(cp)
  elif cp < 0x800:
    s.add char(0xC0 or (cp shr 6))
    s.add char(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    s.add char(0xE0 or (cp shr 12))
    s.add char(0x80 or ((cp shr 6) and 0x3F))
    s.add char(0x80 or (cp and 0x3F))
  else:
    s.add char(0xF0 or (cp shr 18))
    s.add char(0x80 or ((cp shr 12) and 0x3F))
    s.add char(0x80 or ((cp shr 6) and 0x3F))
    s.add char(0x80 or (cp and 0x3F))

type Parser = object
  s: ptr UncheckedArray[char]
  n: int
  i: int

proc fail(p: Parser, msg: string) {.noreturn.} =
  raise newException(JsonError, msg & " at position " & $p.i)

proc skipWs(p: var Parser) {.inline.} =
  while p.i < p.n and p.s[p.i] in {' ', '\t', '\n', '\r'}: inc p.i

proc hex4(p: var Parser): int =
  if p.i + 4 > p.n: p.fail("Bad unicode escape")
  result = 0
  for k in 0 ..< 4:
    let c = p.s[p.i + k]
    result = result shl 4
    case c
    of '0'..'9': result += ord(c) - 48
    of 'a'..'f': result += ord(c) - 87
    of 'A'..'F': result += ord(c) - 55
    else: p.fail("Bad unicode escape")
  p.i += 4

proc parseString(p: var Parser): string =
  inc p.i # opening quote
  var start = p.i
  while true:
    if p.i >= p.n: p.fail("Unterminated string in JSON")
    let c = p.s[p.i]
    if c == '"':
      for k in start ..< p.i: result.add p.s[k]
      inc p.i
      return
    if c == '\\':
      for k in start ..< p.i: result.add p.s[k]
      inc p.i
      if p.i >= p.n: p.fail("Bad escaped character")
      let e = p.s[p.i]
      inc p.i
      case e
      of '"': result.add '"'
      of '\\': result.add '\\'
      of '/': result.add '/'
      of 'b': result.add '\b'
      of 'f': result.add '\f'
      of 'n': result.add '\n'
      of 'r': result.add '\r'
      of 't': result.add '\t'
      of 'u':
        var cp = p.hex4()
        if cp >= 0xD800 and cp <= 0xDBFF and p.i + 6 <= p.n and
            p.s[p.i] == '\\' and p.s[p.i+1] == 'u':
          let save = p.i
          p.i += 2
          let lo = p.hex4()
          if lo >= 0xDC00 and lo <= 0xDFFF:
            cp = 0x10000 + ((cp - 0xD800) shl 10) + (lo - 0xDC00)
          else:
            p.i = save
        result.addUtf8(cp)
      else: p.fail("Bad escaped character")
      start = p.i
    else:
      inc p.i

proc parseValue(p: var Parser): Val

proc parseNumber(p: var Parser): Val =
  let start = p.i
  if p.i < p.n and p.s[p.i] == '-': inc p.i
  var intOnly = true
  while p.i < p.n and p.s[p.i] in {'0'..'9'}: inc p.i
  if p.i < p.n and p.s[p.i] == '.':
    intOnly = false
    inc p.i
    while p.i < p.n and p.s[p.i] in {'0'..'9'}: inc p.i
  if p.i < p.n and p.s[p.i] in {'e', 'E'}:
    intOnly = false
    inc p.i
    if p.i < p.n and p.s[p.i] in {'+', '-'}: inc p.i
    while p.i < p.n and p.s[p.i] in {'0'..'9'}: inc p.i
  if p.i == start or (p.i == start + 1 and p.s[start] == '-'):
    p.fail("Unexpected token in JSON")
  let digits = p.i - start
  if intOnly and digits <= 15:
    var acc = 0'i64
    var k = start
    var neg = false
    if p.s[k] == '-':
      neg = true
      inc k
    while k < p.i:
      acc = acc * 10 + int64(ord(p.s[k]) - 48)
      inc k
    if neg and acc == 0: return jnum(-0.0)
    return jnum(if neg: -float64(acc) else: float64(acc))
  var tmp = newString(digits)
  for k in 0 ..< digits: tmp[k] = p.s[start + k]
  jnum(hostParseNum(tmp))

proc parseValue(p: var Parser): Val =
  p.skipWs()
  if p.i >= p.n: p.fail("Unexpected end of JSON input")
  let c = p.s[p.i]
  case c
  of '{':
    inc p.i
    result = Val(kind: vObj)
    p.skipWs()
    if p.i < p.n and p.s[p.i] == '}':
      inc p.i
      return
    while true:
      p.skipWs()
      if p.i >= p.n or p.s[p.i] != '"': p.fail("Expected property name in JSON")
      let key = p.parseString()
      p.skipWs()
      if p.i >= p.n or p.s[p.i] != ':': p.fail("Expected ':' in JSON")
      inc p.i
      let v = p.parseValue()
      setA(result, atom(key), v)
      p.skipWs()
      if p.i < p.n and p.s[p.i] == ',':
        inc p.i
        continue
      if p.i < p.n and p.s[p.i] == '}':
        inc p.i
        return
      p.fail("Expected ',' or '}' in JSON")
  of '[':
    inc p.i
    result = Val(kind: vArr)
    p.skipWs()
    if p.i < p.n and p.s[p.i] == ']':
      inc p.i
      return
    while true:
      result.a.add p.parseValue()
      p.skipWs()
      if p.i < p.n and p.s[p.i] == ',':
        inc p.i
        continue
      if p.i < p.n and p.s[p.i] == ']':
        inc p.i
        return
      p.fail("Expected ',' or ']' in JSON")
  of '"':
    result = jstr(p.parseString())
  of 't':
    if p.i + 4 <= p.n and p.s[p.i+1] == 'r' and p.s[p.i+2] == 'u' and p.s[p.i+3] == 'e':
      p.i += 4
      return jtrue
    p.fail("Unexpected token in JSON")
  of 'f':
    if p.i + 5 <= p.n and p.s[p.i+1] == 'a' and p.s[p.i+2] == 'l' and
        p.s[p.i+3] == 's' and p.s[p.i+4] == 'e':
      p.i += 5
      return jfalse
    p.fail("Unexpected token in JSON")
  of 'n':
    if p.i + 4 <= p.n and p.s[p.i+1] == 'u' and p.s[p.i+2] == 'l' and p.s[p.i+3] == 'l':
      p.i += 4
      return jnull
    p.fail("Unexpected token in JSON")
  else:
    result = p.parseNumber()

proc parseJson*(s: string): Val =
  if s.len == 0: raise newException(JsonError, "Unexpected end of JSON input")
  var p = Parser(s: cast[ptr UncheckedArray[char]](unsafeAddr s[0]), n: s.len, i: 0)
  result = p.parseValue()
  p.skipWs()
  if p.i != p.n: p.fail("Unexpected non-whitespace character after JSON")

proc quoteJson*(res: var string, s: string) =
  res.add '"'
  for c in s:
    case c
    of '"': res.add "\\\""
    of '\\': res.add "\\\\"
    of '\b': res.add "\\b"
    of '\f': res.add "\\f"
    of '\n': res.add "\\n"
    of '\r': res.add "\\r"
    of '\t': res.add "\\t"
    of '\0'..'\x07', '\x0B', '\x0E'..'\x1F':
      const hexd = "0123456789abcdef"
      res.add "\\u00"
      res.add hexd[ord(c) shr 4]
      res.add hexd[ord(c) and 15]
    else: res.add c

type StrHook* = proc (v: Val): string {.closure.}
  ## Rewrites a string leaf while stringifying (the value node is passed so
  ## callers can cache by identity instead of hashing large strings).

proc addNum(res: var string, n: float64) {.inline.} =
  if n != n or n == Inf or n == -Inf: res.add "null"
  else: res.add jsNumStr(n)

proc writeJson(res: var string, v: Val, hook: StrHook) =
  if v == nil:
    res.add "null"
    return
  case v.kind
  of vNull: res.add "null"
  of vBool: res.add(if v.b: "true" else: "false")
  of vNum: res.addNum(v.n)
  of vStr:
    if hook != nil: res.quoteJson(hook(v))
    else: res.quoteJson(v.s)
  of vArr:
    res.add '['
    for i, x in v.a:
      if i > 0: res.add ','
      writeJson(res, x, hook)
    res.add ']'
  of vObj:
    res.add '{'
    var first = true
    for i in 0 ..< v.ks.len:
      if v.vs[i] == nil: continue
      if not first: res.add ','
      first = false
      res.quoteJson(atomNames[v.ks[i]])
      res.add ':'
      writeJson(res, v.vs[i], hook)
    res.add '}'

proc toJson*(v: Val, hook: StrHook = nil): string =
  ## JSON.stringify(v) (undefined at top level yields "null" here; callers
  ## never stringify undefined).
  result = newStringOfCap(256)
  writeJson(result, v, hook)

proc writePretty(res: var string, v: Val, indent: int, step: int) =
  if v == nil:
    res.add "null"
    return
  case v.kind
  of vNull, vBool, vNum, vStr: writeJson(res, v, nil)
  of vArr:
    if v.a.len == 0:
      res.add "[]"
      return
    res.add "[\n"
    for i, x in v.a:
      for _ in 0 ..< indent + step: res.add ' '
      writePretty(res, x, indent + step, step)
      if i < v.a.len - 1: res.add ','
      res.add '\n'
    for _ in 0 ..< indent: res.add ' '
    res.add ']'
  of vObj:
    var count = 0
    for x in v.vs:
      if x != nil: inc count
    if count == 0:
      res.add "{}"
      return
    res.add "{\n"
    var written = 0
    for i in 0 ..< v.ks.len:
      if v.vs[i] == nil: continue
      for _ in 0 ..< indent + step: res.add ' '
      res.quoteJson(atomNames[v.ks[i]])
      res.add ": "
      writePretty(res, v.vs[i], indent + step, step)
      inc written
      if written < count: res.add ','
      res.add '\n'
    for _ in 0 ..< indent: res.add ' '
    res.add '}'

proc toJsonPretty*(v: Val, step = 2): string =
  ## JSON.stringify(v, null, step)
  result = newStringOfCap(1024)
  writePretty(result, v, 0, step)

proc mapStrings*(v: Val, fn: proc (s: string): Val): Val =
  ## JSON.parse reviver for string leaves (undo blob expansion).
  if v == nil: return nil
  case v.kind
  of vStr: fn(v.s)
  of vArr:
    for i in 0 ..< v.a.len: v.a[i] = mapStrings(v.a[i], fn)
    v
  of vObj:
    for i in 0 ..< v.vs.len: v.vs[i] = mapStrings(v.vs[i], fn)
    v
  else: v

# ------------------------------------------------------------ helpers --

proc arrOf*(xs: openArray[string]): Val =
  result = newArr()
  for x in xs: result.a.add jstr(x)

proc toStrSeq*(v: Val): seq[string] =
  for x in v:
    if x != nil and x.kind == vStr: result.add x.s
    elif not nullish(x): result.add str(x)

proc indexOfStr*(v: Val, s: string): int =
  var i = 0
  for x in v:
    if x != nil and x.kind == vStr and x.s == s: return i
    inc i
  -1

proc containsStr*(xs: openArray[string], s: string): bool =
  for x in xs:
    if x == s: return true
  false

proc jsCompareStr*(a, b: string): int =
  ## String.prototype.localeCompare, approximated: case-insensitive first,
  ## then by code units. Only used to break z-order ties between ids.
  let n = min(a.len, b.len)
  for i in 0 ..< n:
    var x = a[i]
    var y = b[i]
    if x in {'A'..'Z'}: x = char(ord(x) + 32)
    if y in {'A'..'Z'}: y = char(ord(y) + 32)
    if x != y: return (if x < y: -1 else: 1)
  if a.len != b.len: return (if a.len < b.len: -1 else: 1)
  cmp(a, b)

proc sortVals*(xs: var seq[Val], cmpFn: proc (a, b: Val): float64) =
  ## Array.prototype.sort with a numeric comparator (stable).
  xs.sort(proc (a, b: Val): int =
    let r = cmpFn(a, b)
    if r < 0: -1 elif r > 0: 1 else: 0)
