## HTML -> rich text model (PixelRichText.fromHtml). A safe subset is kept:
## scripts, styles, iframes and embeds are dropped.

import std/strutils
import ../jsval, ../richtext
import htmltree, jsutil

proc collapseWs(s: string): string =
  ## text.replace(/\s+/g, ' '), including no-break and Unicode spaces.
  var i = 0
  var inWs = false
  while i < s.len:
    var width = 0
    let c = s[i]
    if c in {' ', '\t', '\n', '\r', '\f', '\v'}: width = 1
    elif c == '\xC2' and i + 1 < s.len and s[i + 1] == '\xA0': width = 2
    elif c == '\xE2' and i + 2 < s.len and s[i + 1] == '\x80' and
         (s[i + 2] in {'\x80'..'\x8A', '\xA8', '\xA9', '\xAF'}): width = 3
    elif c == '\xE2' and i + 2 < s.len and s[i + 1] == '\x81' and s[i + 2] == '\x9F': width = 3
    elif c == '\xE3' and i + 2 < s.len and s[i + 1] == '\x80' and s[i + 2] == '\x80': width = 3
    elif c == '\xEF' and i + 2 < s.len and s[i + 1] == '\xBB' and s[i + 2] == '\xBF': width = 3
    elif c == '\xE1' and i + 2 < s.len and s[i + 1] == '\x9A' and s[i + 2] == '\x80': width = 3
    if width > 0:
      if not inWs: result.add ' '
      inWs = true
      i += width
    else:
      inWs = false
      result.add c
      inc i

proc blockTag(tag: string): string =
  case tag
  of "P", "DIV": "p"
  of "H1": "h1"
  of "H2": "h2"
  of "H3": "h3"
  of "PRE": "pre"
  of "LI": "li"
  else: ""

proc markTag(tag: string): string =
  case tag
  of "B", "STRONG": "bold"
  of "I", "EM": "italic"
  of "U", "INS": "underline"
  of "S", "STRIKE", "DEL": "strike"
  of "SUB": "sub"
  of "SUP": "sup"
  of "CODE": "code"
  else: ""

proc styleMarks(element: HNode, marks: Val): Val =
  let weight = element.styleProp("fontWeight")
  if weight == "bold" or jsNumber(weight) >= 600: marks["bold"] = jtrue
  elif weight == "normal" or (weight.len > 0 and jsNumber(weight) == jsNumber(weight) and
                              jsNumber(weight) < 600):
    marks["bold"] = jfalse
  let fontStyle = element.styleProp("fontStyle")
  if fontStyle == "italic": marks["italic"] = jtrue
  elif fontStyle == "normal": marks["italic"] = jfalse
  var decoration = element.styleProp("textDecorationLine")
  if decoration.len == 0: decoration = element.styleProp("textDecoration")
  if decoration.len > 0:
    if decoration.contains("underline"): marks["underline"] = jtrue
    if decoration.contains("line-through"): marks["strike"] = jtrue
    if decoration == "none":
      marks["underline"] = jfalse
      marks["strike"] = jfalse
  let color = element.styleProp("color")
  if color.len > 0: marks["color"] = jstr(color)
  let size = element.styleProp("fontSize")
  if size.len > 0 and size.endsWith("px"): marks["size"] = jnum(jsParseFloat(size))
  let family = element.styleProp("fontFamily")
  if family.len > 0: marks["family"] = jstr(family)
  marks

proc shallow(v: Val): Val =
  result = newObj()
  for (k, x) in v.pairs: result.put(k, x)

proc htmlToRich*(html: string): Val =
  let tree = sanitized(parseHtml(html), ["script", "style", "iframe", "object", "embed", "link", "meta"])
  var blocks: seq[Val]
  var current: Val = nil

  proc open(kind: string, indent: float64, align: string): Val =
    current = newObj()
    current["type"] = jstr(if kind.len > 0: kind else: "p")
    current["indent"] = jnum(indent)
    current["runs"] = newArr()
    if align.len > 0: current["align"] = jstr(align)
    blocks.add current
    current

  proc push(text: string, marks: Val) =
    if text.len == 0: return
    if current == nil: discard open("p", 0, "")
    let run = newObj()
    run["text"] = jstr(text)
    for (key, value) in marks.pairs:
      if key == "sub" or key == "sup": run["script"] = jstr(key)
      elif key == "code": run["family"] = jstr("Consolas, monospace")
      elif not nullish(value) and not value.isFalse: run.put(key, value)
    current["runs"].push run

  proc walk(node: HNode, marks: Val, listType: string, indent: float64, align: string) =
    for child in node.children:
      if child.kind == hText:
        push(collapseWs(child.text), marks)
        continue
      if child.kind != hElement: continue
      let tag = child.tag
      if tag == "BR":
        discard open(if current != nil: str(current["type"]) else: "p", indent, align)
        continue
      if tag == "UL" or tag == "OL":
        walk(child, marks, if tag == "UL": "ul" else: "ol",
             indent + (if listType.len > 0: 1.0 else: 0.0), align)
        current = nil
        continue
      if tag == "BLOCKQUOTE":
        walk(child, marks, listType, indent + 1, align)
        current = nil
        continue
      let blockKind = blockTag(tag)
      if blockKind.len > 0:
        let kind = if blockKind == "li": (if listType.len > 0: listType else: "ul") else: blockKind
        var blockAlign = child.styleProp("textAlign")
        if blockAlign.len == 0: blockAlign = align
        discard open(kind, indent, blockAlign)
        walk(child, styleMarks(child, shallow(marks)), listType, indent, blockAlign)
        current = nil
        continue
      let next = shallow(marks)
      let mark = markTag(tag)
      if mark.len > 0: next.put(mark, jtrue)
      if tag == "FONT":
        if child.attr("color").len > 0: next["color"] = jstr(child.attr("color"))
        if child.attr("face").len > 0: next["family"] = jstr(child.attr("face"))
      if tag == "A" and child.attr("href").len > 0: next["link"] = jstr(child.attr("href"))
      walk(child, styleMarks(child, next), listType, indent, align)

  walk(tree, newObj(), "", 0, "")
  if blocks.len == 0:
    let b = newObj()
    b["type"] = jstr("p")
    b["indent"] = jnum(0)
    b["runs"] = newArr()
    blocks.add b
  var kept: seq[Val]
  for index, b in blocks:
    if b["runs"].len > 0: kept.add b
    elif (index == 0 or index == blocks.len - 1) and blocks.len == 1: kept.add b
  if kept.len == 0:
    let b = newObj()
    b["type"] = jstr("p")
    b["indent"] = jnum(0)
    b["runs"] = newArr()
    kept.add b
  result = newObj()
  result["blocks"] = newArr(kept)

proc installRichHtml*() =
  fromHtmlHook = htmlToRich
