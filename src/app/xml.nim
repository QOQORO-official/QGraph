## A small, strict XML parser for mxGraph documents and stencil libraries.
##
## It follows what DOMParser('application/xml') accepts and produces for
## these files: elements, attributes (with attribute-value normalisation),
## text, CDATA and character/entity references; comments, processing
## instructions and the DOCTYPE are skipped. Malformed input raises
## XmlError, which is where the browser would return a parsererror document.

import std/strutils

type
  XmlError* = object of CatchableError

  XKind* = enum xElement, xText

  XNode* = ref object
    kind*: XKind
    name*: string                     ## qualified element name
    attrs*: seq[(string, string)]
    children*: seq[XNode]
    parent* {.cursor.}: XNode
    text*: string                     ## text node content

proc fail(msg: string, pos: int) {.noreturn.} =
  raise newException(XmlError, msg & " at offset " & $pos)

proc utf8(code: int): string =
  if code < 0x80: result.add char(code)
  elif code < 0x800:
    result.add char(0xC0 or (code shr 6))
    result.add char(0x80 or (code and 0x3F))
  elif code < 0x10000:
    result.add char(0xE0 or (code shr 12))
    result.add char(0x80 or ((code shr 6) and 0x3F))
    result.add char(0x80 or (code and 0x3F))
  else:
    result.add char(0xF0 or (code shr 18))
    result.add char(0x80 or ((code shr 12) and 0x3F))
    result.add char(0x80 or ((code shr 6) and 0x3F))
    result.add char(0x80 or (code and 0x3F))

proc decodeEntities(s: string, start: int, attribute: bool): string =
  ## Resolves references; in attribute values literal whitespace becomes a
  ## space first (XML attribute-value normalisation).
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '&':
      let semi = s.find(';', i + 1)
      if semi < 0: fail("unterminated entity", start + i)
      let name = s[i + 1 ..< semi]
      if name.len > 1 and name[0] == '#':
        var code = 0
        try:
          code = if name[1] in {'x', 'X'}: parseHexInt(name[2 .. ^1]) else: parseInt(name[1 .. ^1])
        except ValueError: fail("bad character reference", start + i)
        result.add utf8(code)
      else:
        case name
        of "lt": result.add '<'
        of "gt": result.add '>'
        of "amp": result.add '&'
        of "quot": result.add '"'
        of "apos": result.add '\''
        else: fail("undefined entity &" & name & ";", start + i)
      i = semi + 1
    elif attribute and c in {'\t', '\n', '\r'}:
      if c == '\r' and i + 1 < s.len and s[i + 1] == '\n': inc i
      result.add ' '
      inc i
    elif c == '\r':
      # End-of-line handling: CRLF and lone CR become LF.
      if i + 1 < s.len and s[i + 1] == '\n': inc i
      result.add '\n'
      inc i
    else:
      result.add c
      inc i

const NameStart = {'A'..'Z', 'a'..'z', '_', ':', '\x80'..'\xFF'}
const NameChars = NameStart + {'0'..'9', '-', '.'}

proc parseXml*(s: string): XNode =
  ## Returns the document element.
  var i = 0
  let n = s.len
  var stack: seq[XNode]
  var root: XNode = nil

  proc skipWs() =
    while i < n and s[i] in {' ', '\t', '\n', '\r'}: inc i

  proc readName(): string =
    if i >= n or s[i] notin NameStart: fail("expected a name", i)
    let start = i
    while i < n and s[i] in NameChars: inc i
    s[start ..< i]

  # Byte order mark.
  if n >= 3 and s[0] == '\xEF' and s[1] == '\xBB' and s[2] == '\xBF': i = 3

  while i < n:
    if s[i] == '<':
      if i + 1 < n and s[i + 1] == '?':
        let e = s.find("?>", i + 2)
        if e < 0: fail("unterminated processing instruction", i)
        i = e + 2
      elif s.continuesWith("<!--", i):
        let e = s.find("-->", i + 4)
        if e < 0: fail("unterminated comment", i)
        i = e + 3
      elif s.continuesWith("<![CDATA[", i):
        let e = s.find("]]>", i + 9)
        if e < 0: fail("unterminated CDATA section", i)
        if stack.len == 0: fail("CDATA outside the document element", i)
        let t = XNode(kind: xText, text: s[i + 9 ..< e], parent: stack[^1])
        stack[^1].children.add t
        i = e + 3
      elif s.continuesWith("<!DOCTYPE", i) or s.continuesWith("<!doctype", i):
        # Skip, honouring an internal subset in brackets.
        var depth = 0
        while i < n:
          if s[i] == '[': inc depth
          elif s[i] == ']': dec depth
          elif s[i] == '>' and depth <= 0: break
          inc i
        inc i
      elif i + 1 < n and s[i + 1] == '/':
        i += 2
        let name = readName()
        skipWs()
        if i >= n or s[i] != '>': fail("expected '>'", i)
        inc i
        if stack.len == 0 or stack[^1].name != name:
          fail("mismatched end tag </" & name & ">", i)
        discard stack.pop()
      else:
        inc i
        let name = readName()
        let node = XNode(kind: xElement, name: name)
        while true:
          skipWs()
          if i >= n: fail("unterminated start tag", i)
          if s[i] == '>':
            inc i
            if stack.len > 0:
              node.parent = stack[^1]
              stack[^1].children.add node
            elif root != nil: fail("extra content after the document element", i)
            else: root = node
            stack.add node
            break
          if s[i] == '/':
            if i + 1 >= n or s[i + 1] != '>': fail("expected '/>'", i)
            i += 2
            if stack.len > 0:
              node.parent = stack[^1]
              stack[^1].children.add node
            elif root != nil: fail("extra content after the document element", i)
            else: root = node
            break
          let attrName = readName()
          skipWs()
          if i >= n or s[i] != '=': fail("expected '=' after attribute " & attrName, i)
          inc i
          skipWs()
          if i >= n or s[i] notin {'"', '\''}: fail("expected a quoted value", i)
          let quote = s[i]
          let e = s.find(quote, i + 1)
          if e < 0: fail("unterminated attribute value", i)
          let raw = s[i + 1 ..< e]
          if '<' in raw: fail("'<' in attribute value", i)
          for (k, _) in node.attrs:
            if k == attrName: fail("duplicate attribute " & attrName, i)
          node.attrs.add (attrName, decodeEntities(raw, i + 1, true))
          i = e + 1
    else:
      let e = s.find('<', i)
      let stop = if e < 0: n else: e
      let raw = s[i ..< stop]
      if stack.len == 0:
        for c in raw:
          if c notin {' ', '\t', '\n', '\r'}: fail("text outside the document element", i)
      else:
        let t = XNode(kind: xText, text: decodeEntities(raw, i, false), parent: stack[^1])
        stack[^1].children.add t
      i = stop

  if root == nil: fail("no document element", 0)
  if stack.len > 0: fail("unclosed element <" & stack[^1].name & ">", n)
  root

# ------------------------------------------------------------ accessors --

proc hasAttr*(n: XNode, name: string): bool =
  if n == nil: return false
  for (k, _) in n.attrs:
    if k == name: return true
  false

proc attr*(n: XNode, name: string): string =
  ## getAttribute; "" when absent (use hasAttr to tell the difference).
  if n == nil: return ""
  for (k, v) in n.attrs:
    if k == name: return v
  ""

proc attrOr*(n: XNode, name: string, fallback: string): string =
  if n.hasAttr(name): n.attr(name) else: fallback

proc localName*(n: XNode): string =
  let colon = n.name.find(':')
  if colon < 0: n.name else: n.name[colon + 1 .. ^1]

iterator elements*(n: XNode): XNode =
  ## The element children (DOM `children`).
  if n != nil:
    for c in n.children:
      if c.kind == xElement: yield c

proc elementChildren*(n: XNode): seq[XNode] =
  for c in n.elements: result.add c

proc descendants(n: XNode, name: string, acc: var seq[XNode]) =
  for c in n.children:
    if c.kind != xElement: continue
    if name == "*" or c.name == name: acc.add c
    descendants(c, name, acc)

proc getElementsByTagName*(n: XNode, name: string): seq[XNode] =
  ## Descendants (not the node itself) in document order.
  if n != nil: descendants(n, name, result)

proc firstByTag*(n: XNode, name: string): XNode =
  let all = n.getElementsByTagName(name)
  if all.len > 0: all[0] else: nil

proc textContent*(n: XNode): string =
  if n == nil: return ""
  if n.kind == xText: return n.text
  for c in n.children: result.add c.textContent
