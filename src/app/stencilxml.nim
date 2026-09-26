## mxGraph stencil libraries: XML -> flat draw programs.
##
## The programs are what the painter (src/stencils.nim) executes and what the
## palette previews are drawn from. Libraries are remembered so the sidebar
## can list their shapes.

import std/[tables, strutils]
import ../jsval
from ../stencils import normalizeKey, register
import xml, jsutil

var libraries*: OrderedTable[string, seq[Val]]
  ## Library name -> shapes, in load order.
var programs = initOrderedTable[string, Val]()
  ## Registry key -> shape (for previews).

proc number(element: XNode, name: string, fallback: float64): Val =
  if not element.hasAttr(name) or element.attr(name).len == 0: return jnum(fallback)
  let v = jsParseFloat(element.attr(name))
  jnum(if v != v: fallback else: v)

proc attrOrNull(element: XNode, name: string): Val =
  if element.hasAttr(name): jstr(element.attr(name)) else: jnull

proc op(kind: string): Val =
  result = newObj()
  result["op"] = jstr(kind)

proc parseSection(section: XNode): Val =
  result = newArr()
  if section == nil: return
  for node in section.elements:
    let tag = node.name.toLowerAscii()
    if tag == "path":
      result.push op("begin")
      for step in node.elements:
        let name = step.name.toLowerAscii()
        case name
        of "move", "line":
          let o = op(name)
          o["x"] = number(step, "x", 0)
          o["y"] = number(step, "y", 0)
          result.push o
        of "quad":
          let o = op("quad")
          o["x1"] = number(step, "x1", 0)
          o["y1"] = number(step, "y1", 0)
          o["x"] = number(step, "x2", 0)
          o["y"] = number(step, "y2", 0)
          result.push o
        of "curve":
          let o = op("curve")
          o["x1"] = number(step, "x1", 0)
          o["y1"] = number(step, "y1", 0)
          o["x2"] = number(step, "x2", 0)
          o["y2"] = number(step, "y2", 0)
          o["x"] = number(step, "x3", 0)
          o["y"] = number(step, "y3", 0)
          result.push o
        of "arc":
          let o = op("arc")
          o["rx"] = number(step, "rx", 0)
          o["ry"] = number(step, "ry", 0)
          o["rotation"] = number(step, "x-axis-rotation", 0)
          o["large"] = number(step, "large-arc-flag", 0)
          o["sweep"] = number(step, "sweep-flag", 0)
          o["x"] = number(step, "x", 0)
          o["y"] = number(step, "y", 0)
          result.push o
        of "close": result.push op("close")
        else: discard
      continue
    case tag
    of "rect", "ellipse":
      let o = op(tag)
      o["x"] = number(node, "x", 0)
      o["y"] = number(node, "y", 0)
      o["w"] = number(node, "w", 0)
      o["h"] = number(node, "h", 0)
      result.push o
    of "roundrect":
      let o = op("roundrect")
      o["x"] = number(node, "x", 0)
      o["y"] = number(node, "y", 0)
      o["w"] = number(node, "w", 0)
      o["h"] = number(node, "h", 0)
      o["arcsize"] = number(node, "arcsize", 10)
      result.push o
    of "fill", "stroke", "fillstroke", "save", "restore": result.push op(tag)
    of "strokewidth":
      let o = op(tag)
      o["width"] = attrOrNull(node, "width")
      result.push o
    of "fillcolor", "strokecolor", "fontcolor":
      let o = op(tag)
      o["color"] = attrOrNull(node, "color")
      result.push o
    of "fontsize":
      let o = op(tag)
      o["size"] = number(node, "size", 12)
      result.push o
    of "alpha":
      let o = op(tag)
      o["alpha"] = number(node, "alpha", 1)
      result.push o
    of "dashed":
      let o = op(tag)
      o["on"] = jbool(node.attr("dashed") == "1")
      result.push o
    of "dashpattern":
      let o = op(tag)
      let pattern = newArr()
      for part in node.attr("pattern").splitWhitespace():
        let v = jsParseFloat(part)
        if v == v: pattern.push jnum(v)
      o["pattern"] = pattern
      result.push o
    of "linejoin":
      let o = op(tag)
      o["join"] = attrOrNull(node, "join")
      result.push o
    of "linecap":
      let o = op(tag)
      o["cap"] = attrOrNull(node, "cap")
      result.push o
    of "miterlimit":
      let o = op(tag)
      o["limit"] = number(node, "limit", 10)
      result.push o
    of "text":
      let o = op("text")
      o["str"] = jstr(node.attr("str"))
      o["x"] = number(node, "x", 0)
      o["y"] = number(node, "y", 0)
      o["align"] = jstr(if node.attr("align").len > 0: node.attr("align") else: "left")
      o["valign"] = jstr(if node.attr("valign").len > 0: node.attr("valign") else: "top")
      result.push o
    else: discard

proc parseShape(element: XNode, libraryName: string): Val =
  let name = element.attr("name")
  if name.len == 0: return nil
  result = newObj()
  result["name"] = jstr(name)
  result["library"] = jstr(libraryName)
  result["key"] = jstr(normalizeKey(libraryName & "." & name))
  result["w"] = number(element, "w", 100)
  result["h"] = number(element, "h", 100)
  result["aspect"] = jstr(if element.attr("aspect").len > 0: element.attr("aspect") else: "variable")
  result["strokeWidth"] = jstr(if element.attr("strokewidth").len > 0: element.attr("strokewidth") else: "1")
  result["background"] = parseSection(element.firstByTag("background"))
  result["foreground"] = parseSection(element.firstByTag("foreground"))

proc parseLibrary*(text, fallbackName: string): seq[Val] =
  ## Parses a stencil library and registers every shape in it.
  var root: XNode
  try: root = parseXml(text)
  except XmlError: return
  let libraryName = if root.attr("name").len > 0: root.attr("name")
                    elif fallbackName.len > 0: fallbackName else: "stencil"
  var shapes = root.getElementsByTagName("shape")
  if root.name == "shape": shapes.insert(root, 0)
  for element in shapes:
    let shape = parseShape(element, libraryName)
    if shape == nil: continue
    programs[str(shape["key"])] = shape
    result.add shape
  libraries.mgetOrPut(libraryName, @[]).add result
  register(newArr(result))

proc registerPrograms*(shapes: Val) =
  ## Programs parsed elsewhere (the page, for a worker).
  var added: seq[Val]
  for shape in shapes:
    programs[str(shape["key"])] = shape
    libraries.mgetOrPut(str(shape["library"]), @[]).add shape
    added.add shape
  register(newArr(added))

proc program*(key: string): Val = programs.getOrDefault(normalizeKey(key), nil)

proc allPrograms*(): Val =
  result = newArr()
  for _, shape in programs: result.push shape
