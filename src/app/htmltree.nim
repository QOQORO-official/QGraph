## HTML seen through the browser's own parser.
##
## Markup (labels, table cells, pasted HTML) is parsed by the page's HTML
## parser once and handed to Nim as a tree, so entities, implied tags and the
## CSSOM's normalised inline styles are exactly what the browser produces.
## Everything done with the tree afterwards -- rich text import, table
## import, sanitising, serialising -- is Nim.

import std/strutils
import ../jsval
import ../web/qweb

type
  HKind* = enum hText, hElement, hComment, hFragment

  HNode* = ref object
    kind*: HKind
    tag*: string            ## tagName (upper case for HTML elements)
    local*: string          ## localName
    attrs*: seq[(string, string)]
    style*: seq[(string, string)]   ## non-empty inline style properties
    css*: seq[(string, string)]     ## SVG: style.getPropertyValue(name) values
    children*: seq[HNode]
    text*: string           ## text/comment data
    inner*, outer*: string  ## innerHTML of cells, outerHTML of tables
    colSpan*, rowSpan*: int

proc strOrEmptyV(v: Val): string = (if v == nil or v.kind == vNull: "" else: str(v))

proc fromVal(v: Val): HNode =
  if v == nil: return nil
  if v.isStr: return HNode(kind: hText, text: v.s)
  if v.hasKey("m"): return HNode(kind: hComment, text: strOrEmptyV(v["m"]))
  result = HNode(kind: if v.hasKey("t"): hElement else: hFragment)
  if result.kind == hElement:
    result.tag = str(v["t"])
    result.local = str(v["l"])
    for (k, x) in v["a"].pairs: result.attrs.add (k, str(x))
    if v["s"].isObj:
      for (k, x) in v["s"].pairs: result.style.add (k, str(x))
    if v["p"].isObj:
      for (k, x) in v["p"].pairs: result.css.add (k, str(x))
    if v.hasKey("h"): result.inner = str(v["h"])
    if v.hasKey("o"): result.outer = str(v["o"])
    result.colSpan = int(v.fo("cs", 1))
    result.rowSpan = int(v.fo("rs", 1))
  for c in v["c"]:
    let child = fromVal(c)
    if child != nil: result.children.add child

proc parseHtml*(markup: string, withMarkup = false): HNode =
  ## The fragment a <template> would hold after `innerHTML = markup`.
  let json = domSnapshot(markup, false, withMarkup)
  try:
    fromVal(parseJson(json))
  except JsonError:
    HNode(kind: hFragment)

proc parseSvg*(markup: string): (HNode, string) =
  ## The document element DOMParser('image/svg+xml') produces, or the
  ## parser error text.
  let json = domSnapshot(markup, true)
  var v: Val = nil
  try: v = parseJson(json)
  except JsonError: return (nil, "Invalid SVG")
  if v.isObj and v.hasKey("error"): return (nil, str(v["error"]))
  (fromVal(v), "")

# ------------------------------------------------------------ accessors --

proc hasAttr*(n: HNode, name: string): bool =
  if n == nil: return false
  for (k, _) in n.attrs:
    if k == name: return true
  false

proc attr*(n: HNode, name: string): string =
  if n == nil: return ""
  for (k, v) in n.attrs:
    if k == name: return v
  ""

proc cssProp*(n: HNode, name: string): string =
  ## element.style.getPropertyValue(name) (SVG documents).
  if n == nil: return ""
  for (k, v) in n.css:
    if k == name: return v
  ""

proc styleProp*(n: HNode, prop: string): string =
  ## element.style[prop] ("" when unset).
  if n == nil: return ""
  for (k, v) in n.style:
    if k == prop: return v
  ""

iterator elements*(n: HNode): HNode =
  if n != nil:
    for c in n.children:
      if c.kind == hElement: yield c

proc textContent*(n: HNode): string =
  if n == nil: return ""
  case n.kind
  of hText: n.text
  of hComment: ""
  else:
    var s = ""
    for c in n.children: s.add textContent(c)
    s

proc textWithBreaks*(n: HNode): string =
  ## textContent with every <br> read as a line break.
  if n == nil: return ""
  case n.kind
  of hText: n.text
  of hComment: ""
  else:
    if n.kind == hElement and n.local == "br": return "\n"
    var s = ""
    for c in n.children: s.add textWithBreaks(c)
    s

proc walkFind(n: HNode, pred: proc(x: HNode): bool, acc: var seq[HNode], first: bool) =
  for c in n.children:
    if c.kind != hElement: continue
    if pred(c):
      acc.add c
      if first: return
    walkFind(c, pred, acc, first)
    if first and acc.len > 0: return

proc findFirst*(n: HNode, localName: string): HNode =
  ## querySelector(localName) over descendants.
  var acc: seq[HNode]
  walkFind(n, proc(x: HNode): bool = x.local == localName, acc, true)
  if acc.len > 0: acc[0] else: nil

proc findAll*(n: HNode, localName: string): seq[HNode] =
  walkFind(n, proc(x: HNode): bool = x.local == localName, result, false)

proc findFirstWhere*(n: HNode, pred: proc(x: HNode): bool): HNode =
  var acc: seq[HNode]
  walkFind(n, pred, acc, true)
  if acc.len > 0: acc[0] else: nil

# --------------------------------------------------------- serialisation --

const VoidElements = ["area", "base", "br", "col", "embed", "hr", "img", "input",
                      "link", "meta", "source", "track", "wbr", "param", "keygen"]
const RawTextElements = ["style", "script", "xmp", "iframe", "noembed", "noframes",
                         "plaintext"]

proc escapeText(s: string, attribute: bool): string =
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '&': result.add "&amp;"
    elif c == '\xC2' and i + 1 < s.len and s[i + 1] == '\xA0':
      result.add "&nbsp;"
      inc i
    elif attribute and c == '"': result.add "&quot;"
    elif not attribute and c == '<': result.add "&lt;"
    elif not attribute and c == '>': result.add "&gt;"
    else: result.add c
    inc i

proc serializeChildren*(n: HNode): string

proc serialize*(n: HNode, parentLocal = ""): string =
  ## The HTML fragment serialisation algorithm (outerHTML of `n`).
  case n.kind
  of hText:
    if parentLocal in RawTextElements or parentLocal == "noscript": n.text
    else: escapeText(n.text, false)
  of hComment: "<!--" & n.text & "-->"
  of hFragment: serializeChildren(n)
  of hElement:
    var s = "<" & n.local
    for (k, v) in n.attrs: s.add " " & k & "=\"" & escapeText(v, true) & "\""
    s.add ">"
    if n.local in VoidElements: return s
    s.add serializeChildren(n)
    s.add "</" & n.local & ">"
    s

proc serializeChildren*(n: HNode): string =
  let local = if n.kind == hElement: n.local else: ""
  for c in n.children: result.add serialize(c, local)

proc sanitized*(n: HNode, dropTags: openArray[string]): HNode =
  ## Copy without the listed elements and without event-handler attributes
  ## or javascript: URLs.
  if n.kind != hElement and n.kind != hFragment: return n
  result = HNode(kind: n.kind, tag: n.tag, local: n.local, style: n.style,
                 inner: n.inner, outer: n.outer, colSpan: n.colSpan, rowSpan: n.rowSpan)
  for (k, v) in n.attrs:
    let name = k.toLowerAscii()
    let value = v.strip().toLowerAscii()
    if name.startsWith("on"): continue
    if name in ["href", "src", "xlink:href"] and value.startsWith("javascript:"): continue
    result.attrs.add (k, v)
  for c in n.children:
    if c.kind == hElement and c.local in dropTags: continue
    result.children.add sanitized(c, dropTags)
