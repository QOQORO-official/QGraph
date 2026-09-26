## .qochart (mxGraphModel XML) support: the importer plus round-trip
## metadata (every imported item keeps its original cell under `mx`,
## including custom wrapper elements), and a writer.

import std/[tables, strutils, math]
import ../jsval, ../geometry
from ../richtext import toHtml
import xml, legacy, jsutil

const FontBold = 1
const FontItalic = 2
const FontUnderline = 4
const FontStrike = 8

proc shapeOut(shape: string): string =
  case shape
  of "rect": "rectangle"
  of "ellipse": "ellipse"
  of "diamond": "rhombus"
  of "triangle": "triangle"
  of "hexagon": "hexagon"
  of "parallelogram": "parallelogram"
  of "trapezoid": "trapezoid"
  of "cylinder": "cylinder3"
  of "cloud": "cloud"
  of "document": "document"
  of "note": "note"
  of "cube": "cube"
  of "actor": "actor"
  of "step", "chevron": "step"
  of "delay": "delay"
  of "swimlane": "swimlane"
  of "table": "table"
  of "image": "image"
  of "text": "text"
  of "speech": "callout"
  of "plus": "plus"
  of "blockArrow", "singleArrow": "singleArrow"
  of "html": "rectangle"
  of "isoCube2", "isoRectangle", "manualInput", "loopLimit", "offPageConnector", "display",
     "doubleArrow", "cross", "corner", "tee", "datastore", "tapeData", "orEllipse",
     "sumEllipse", "lineEllipse", "sortShape", "collate", "switch", "card", "tape",
     "process", "internalStorage", "dataStorage", "xor", "or", "line", "curlyBracket",
     "crossbar", "partialRectangle", "umlBoundary", "umlEntity", "umlControl",
     "umlDestroy", "umlLifeline", "umlFrame", "umlState", "module", "component", "folder",
     "providedRequiredInterface", "requiredInterface", "endState", "startState",
     "message", "parallelMarker": shape
  else: ""

proc isShapeToken(name: string): bool =
  name in ["rectangle", "ellipse", "rhombus", "triangle", "text", "line", "swimlane", "image"]

proc arrowOut(name: string): string =
  if name in ["none", "classic", "block", "open", "oval", "diamond"]: name else: ""

type Style* = object
  shapeTokens*: seq[string]
  keys*: seq[string]
  values*: Table[string, string]
  nulls*: Table[string, bool]

proc decodeStyle*(style: string): Style =
  for part in style.split(';'):
    if part.len == 0: continue
    let index = part.find('=')
    if index < 0: result.shapeTokens.add part
    else:
      let key = part[0 ..< index]
      if key notin result.values: result.keys.add key
      result.values[key] = part[index + 1 .. ^1]

proc has(s: Style, key: string): bool = s.values.hasKey(key)
proc get(s: Style, key: string): string = s.values.getOrDefault(key, "")

proc set(s: var Style, key: string, value: string) =
  ## style[key] = value (a string).
  if key notin s.values and key notin s.nulls: s.keys.add key
  s.values[key] = value
  s.nulls.del(key)

proc setNull(s: var Style, key: string) =
  ## style[key] = null/undefined: keeps the key's slot, writes nothing.
  if key notin s.values and key notin s.nulls: s.keys.add key
  s.values.del(key)
  s.nulls[key] = true

proc setNum(s: var Style, key: string, v: float64) = s.set(key, jsStr(v))

proc setVal(s: var Style, key: string, v: Val) =
  ## Assigns a JS value the way `style[key] = value` then String(value) would.
  if nullish(v): s.setNull(key)
  elif v.isStr:
    if v.s.len == 0: s.setNull(key) else: s.set(key, v.s)
  else: s.set(key, str(v))

proc encodeStyle*(s: Style): string =
  var parts = s.shapeTokens
  for key in s.keys:
    if key in s.values:
      let v = s.values[key]
      if v.len > 0: parts.add key & "=" & v
  parts.join(";") & (if parts.len > 0: ";" else: "")

proc colorOut(v: Val): Val =
  if nullish(v): return jnull
  let s = str(v)
  if s == "transparent" or s == "rgba(0,0,0,0)": jstr("none") else: v

proc numberOut(value: float64): string =
  let v = if value != value: 0.0 else: value
  jsStr(jsRound(v * 1000) / 1000)

proc looksLikeXml*(text: string): bool =
  let t = text.strip(trailing = false).toLowerAscii()
  t.startsWith("<?xml") or t.startsWith("<mxgraphmodel") or t.startsWith("<mxfile") or
    t.startsWith("<!--") or t.startsWith("<!doctype")

proc encodedJson(v: Val): string = encodeURIComponent(toJson(v))

proc decodedJson(present: bool, value: string): Val =
  if not present or value.len == 0: return nil
  try: parseJson(decodeURIComponent(value))
  except CatchableError: nil

proc writeRuntimeStyle(style: var Style, item: Val) =
  var groups: seq[Val]
  if item["groups"].isArr:
    for g in item["groups"]: groups.add g
  elif truthy(item["groupId"]): groups.add item["groupId"]
  if groups.len > 0: style.set("qochartGroups", encodedJson(newArr(groups)))
  else: style.setNull("qochartGroups")
  let z = num(item["z"])
  style.setNum("qochartZ", if isFiniteNum(z): z else: 0)
  if nullish(item["layer"]): style.setNull("qochartLayer")
  else: style.set("qochartLayer", encodeURIComponent(str(item["layer"])))
  if truthy(item["containerRole"]): style.set("qochartContainerRole", str(item["containerRole"]))
  else: style.setNull("qochartContainerRole")
  let kind = if item["kind"].isStr: item["kind"].s else: ""
  if kind in ["container", "list", "listItem", "taskList"]: style.set("qochartKind", kind)
  else: style.setNull("qochartKind")

proc readRuntimeStyle(item: Val, style: Style) =
  let groups = decodedJson(style.has("qochartGroups"), style.get("qochartGroups"))
  if groups.isArr and groups.len > 0:
    let arr = newArr()
    for g in groups: arr.push jstr(str(g))
    item["groups"] = arr
    item["groupId"] = arr[0]
  else:
    item.del("groups")
    item.del("groupId")
  if style.has("qochartZ") and isFiniteNum(jsNumber(style.get("qochartZ"))):
    item["z"] = jnum(jsNumber(style.get("qochartZ")))
  if style.get("qochartLayer").len > 0:
    item["layer"] = jstr(tryDecodeURIComponent(style.get("qochartLayer")))
  if style.get("qochartContainerRole").len > 0:
    item["containerRole"] = jstr(style.get("qochartContainerRole"))
  if style.get("qochartKind").len > 0: item["kind"] = jstr(style.get("qochartKind"))

# ---------------------------------------------------------------- reading --

proc collectCells(text: string): Table[string, Val] =
  var root: XNode
  try: root = parseXml(text)
  except XmlError: return
  var cells: seq[XNode]
  if root.name == "mxCell": cells.add root
  cells.add root.getElementsByTagName("mxCell")
  for cell in cells:
    if cell.attr("vertex") != "1" and cell.attr("edge") != "1": continue
    let wrapper = cell.parent
    let wrapped = wrapper != nil and wrapper.name != "root" and wrapper.name != "mxGraphModel"
    var id = if wrapped: wrapper.attr("id") else: ""
    if id.len == 0: id = cell.attr("id")
    if id.len == 0: continue
    let record = newObj()
    record["id"] = jstr(id)
    record["parent"] = jstr(if cell.attr("parent").len > 0: cell.attr("parent") else: "1")
    record["style"] = jstr(cell.attr("style"))
    record["wrapperTag"] = if wrapped: jstr(wrapper.name) else: jnull
    record["wrapperAttrs"] = jnull
    let linkOwner = if wrapped: wrapper else: cell
    record["link"] = if linkOwner.hasAttr("link"): jstr(linkOwner.attr("link")) else: jnull
    if wrapped:
      let attrs = newObj()
      for (k, v) in wrapper.attrs: attrs.put(k, jstr(v))
      record["wrapperAttrs"] = attrs
    result[id] = record

proc cleanLayer(layer: Val): Val =
  result = newObj()
  result["src"] = layer["src"]
  result["mediaType"] = jstr(if truthy(layer["mediaType"]): str(layer["mediaType"]) else: "")
  result["depth"] = jnum(jsMax(0.0, jsMin(1.0, jsNumOr(layer["depth"], 0))))
  let opacity = if nullish(layer["opacity"]): 1.0
                else: jsNumOr(layer["opacity"], 0.0)
  result["opacity"] = jnum(jsMax(0.0, jsMin(1.0, opacity)))
  result["scrollX"] = jnum(jsNumOr(layer["scrollX"], 0))
  result["scrollY"] = jnum(jsNumOr(layer["scrollY"], 0))

proc parse*(text: string): Val =
  ## Parses a .qochart into a pixel document, keeping round-trip metadata.
  result = importLegacyGraph(text)
  let records = collectCells(text)
  for item in result["items"]:
    let record = records.getOrDefault(idOf(item), nil)
    if record == nil: continue
    item["mx"] = record
    let style = decodeStyle(str(record["style"]))
    if style.get("qochartShape").len > 0 and not item.eqs("shape", "table") and
        not item.eqs("shape", "stencil") and not item.eqs("sourceType", "htmlTable") and
        not item.eqs("kind", "table"):
      item["shape"] = jstr(style.get("qochartShape"))
    if style.get("cscript").len > 0:
      try: item["cscript"] = jstr(decodeURIComponent(style.get("cscript")))
      except URIError: discard
    if style.get("bookmark") == "1": item["bookmark"] = jtrue
    if truthy(record["link"]): item["link"] = record["link"]
    if style.get("imageFit").len > 0: item["imageFit"] = jstr(style.get("imageFit"))
    if style.get("imageAlign").len > 0: item["imageAlign"] = jstr(style.get("imageAlign"))
    if style.get("imageVerticalAlign").len > 0:
      item["imageVerticalAlign"] = jstr(style.get("imageVerticalAlign"))
    if style.has("imageOpacity"): item["imageOpacity"] = jnum(jsParseFloat(style.get("imageOpacity")) / 100)
    if style.get("mediaType").len > 0: item["mediaType"] = jstr(style.get("mediaType"))
    if style.has("mediaLoop"): item["mediaLoop"] = jbool(style.get("mediaLoop") != "0")
    if style.has("mediaVolume"):
      item["mediaVolume"] = jnum(jsMax(0.0, jsMin(1.0, jsNumber(style.get("mediaVolume")) / 100)))
    let mediaLayers = decodedJson(style.has("mediaLayers"), style.get("mediaLayers"))
    if mediaLayers.isArr and mediaLayers.len > 0:
      let layers = newArr()
      for layer in mediaLayers:
        if layer.isObj and layer["src"].isStr and layer["src"].s.len > 0: layers.push cleanLayer(layer)
      item["mediaLayers"] = layers
      if layers.len == 0: item.del("mediaLayers")
    readRuntimeStyle(item, style)
    if item.eqs("type", "edge"):
      if style.get("qochartSourceLabel").len > 0:
        item["sourceLabel"] = jstr(tryDecodeURIComponent(style.get("qochartSourceLabel")))
      if style.get("qochartTargetLabel").len > 0:
        item["targetLabel"] = jstr(tryDecodeURIComponent(style.get("qochartTargetLabel")))
      if style.get("qochartEdgeSymbol").len > 0:
        item["edgeSymbol"] = jstr(style.get("qochartEdgeSymbol"))
    if item.eqs("type", "edge") and style.get("qochartRoute") == "circular":
      item["lineStyle"] = jstr("circular")
      item["route"] = jnull
      let sweep = jsNumber(style.get("arcSweep"))
      item["arcSweep"] = jnum(jsMax(1.0, jsMin(360.0, if sweep != sweep or sweep == 0 or not style.has("arcSweep"): 180.0 else: sweep)))
      item["arcSide"] = jnum(if style.has("arcSide") and jsNumber(style.get("arcSide")) < 0: -1 else: 1)
      let radius = jsNumber(style.get("circleRadius"))
      item["circleRadius"] = jnum(jsMax(5.0, if radius != radius or radius == 0 or not style.has("circleRadius"): 60.0 else: radius))

  var root: XNode = nil
  try: root = parseXml(text)
  except XmlError: discard
  if root != nil:
    let model = if root.name == "mxGraphModel": root else: root.firstByTag("mxGraphModel")
    if model != nil:
      let saved = decodedJson(model.hasAttr("qochartLayers"), model.attr("qochartLayers"))
      if saved.isArr and saved.len > 0: result["layers"] = saved

# ---------------------------------------------------------------- writing --

proc nodeToStyle(node: Val): string =
  var style = if node["mx"].isObj: decodeStyle(str(node["mx"]["style"])) else: Style()
  let shape = if node["shape"].isStr: node["shape"].s else: ""
  if shape == "stencil" and truthy(node["stencil"]):
    style.set("shape", str(node["stencil"]))
  elif not node.eqs("sourceType", "htmlTable") and shapeOut(shape).len > 0:
    let classic = shapeOut(shape)
    style.shapeTokens = @[]
    if isShapeToken(classic):
      style.shapeTokens.add classic
      style.values.del("shape")
      style.nulls.del("shape")
      let at = style.keys.find("shape")
      if at >= 0: style.keys.delete(at)
    else: style.set("shape", classic)
  if shape.len > 0 and shape != "stencil" and shape != "table" and not node.eqs("sourceType", "htmlTable"):
    style.set("qochartShape", shape)
  else: style.setNull("qochartShape")
  style.setVal("fillColor", colorOut(node["fill"]))
  style.setVal("strokeColor", colorOut(node["stroke"]))
  style.setVal("strokeWidth", node["strokeWidth"])
  style.setVal("fontColor", colorOut(node["textColor"]))
  style.setVal("fontSize", node["fontSize"])
  style.setVal("fontFamily", node["fontFamily"])
  style.setVal("align", node["textAlign"])
  style.setVal("verticalAlign", node["verticalAlign"])
  if nullish(node["opacity"]): style.setNull("opacity")
  else: style.setNum("opacity", jsRound(num(node["opacity"]) * 100))
  if truthy(node["shadow"]): style.set("shadow", "1") else: style.setNull("shadow")
  if truthy(node["dashed"]): style.set("dashed", "1") else: style.setNull("dashed")
  if truthy(node["dashed"]) and truthy(node["dashPattern"]): style.set("dashPattern", arrJoin(node["dashPattern"], " "))
  else: style.setNull("dashPattern")
  let radius = num(node["radius"])
  style.set("rounded", if radius > 0: "1" else: "0")
  if radius > 0: style.setVal("arcSize", node["radius"]) else: style.setNull("arcSize")
  if truthy(node["gradient"]): style.setVal("gradientColor", colorOut(node["gradient"]))
  else: style.setNull("gradientColor")
  style.set("whiteSpace", if node["wordWrap"].isFalse: "nowrap" else: "wrap")
  if truthy(node["flipH"]): style.set("flipH", "1") else: style.setNull("flipH")
  if truthy(node["flipV"]): style.set("flipV", "1") else: style.setNull("flipV")
  if truthy(node["rotation"]): style.setVal("rotation", node["rotation"]) else: style.setNull("rotation")
  if shape == "swimlane" or node.eqs("kind", "taskList"): style.setVal("startSize", node["headerHeight"])
  if not nullish(node["shapeSize"]):
    let size = num(node["shapeSize"])
    style.setNum("size", if shape == "cylinder": size * num(node["height"])
                         elif shape in ["cube", "note"]: size * jsMin(num(node["width"]), num(node["height"]))
                         else: size)
  if shape == "isoCube2":
    if nullish(node["isoAngle"]): style.setNum("isoAngle", 15) else: style.setVal("isoAngle", node["isoAngle"])
  if shape in ["blockArrow", "singleArrow", "doubleArrow"]:
    style.setVal("arrowSize", node["arrowSize"])
    style.setVal("arrowWidth", node["arrowWidth"])
  style.setVal("direction", node["direction"])
  style.setVal("line", node["line"])
  if truthy(node["double"]): style.set("double", "1") else: style.setNull("double")
  style.setVal("dx", node["dx"])
  style.setVal("dy", node["dy"])
  for side in ["top", "right", "bottom", "left"]:
    let v = node.get(side)
    if v.isFalse: style.set(side, "0")
    elif v.isTrue: style.set(side, "1")
    else: style.setNull(side)
  for key in ["jettyWidth", "jettyHeight", "tabWidth", "tabHeight"]:
    style.setVal(key, node.get(key))
  style.setVal("tabPosition", node["tabPosition"])
  style.setVal("inset", node["inset"])
  style.setVal("umlStateSymbol", node["umlStateSymbol"])
  style.setVal("participant", node["participant"])
  if shape == "umlFrame":
    style.setVal("width", node["frameWidth"])
    style.setVal("height", node["frameHeight"])
  if shape == "image" and truthy(node["src"]):
    style.set("image", encodeURIComponent(str(node["src"])))
    style.setVal("imageFit", node["imageFit"])
    style.setVal("imageAlign", node["imageAlign"])
    style.setVal("imageVerticalAlign", node["imageVerticalAlign"])
    if nullish(node["imageOpacity"]): style.setNull("imageOpacity")
    else: style.setNum("imageOpacity", jsRound(num(node["imageOpacity"]) * 100))
    style.setVal("mediaType", node["mediaType"])
    let video = truthy(node["mediaType"]) and str(node["mediaType"]).startsWith("video/")
    if video: style.set("mediaLoop", if node["mediaLoop"].isFalse: "0" else: "1")
    else: style.setNull("mediaLoop")
    if video: style.setNum("mediaVolume", jsRound((if nullish(node["mediaVolume"]): 1.0 else: num(node["mediaVolume"])) * 100))
    else: style.setNull("mediaVolume")
    if node["mediaLayers"].isArr and node["mediaLayers"].len > 0:
      let layers = newArr()
      for layer in node["mediaLayers"]:
        if layer.isObj and layer["src"].isStr and layer["src"].s.len > 0: layers.push cleanLayer(layer)
      style.set("mediaLayers", encodedJson(layers))
    else: style.setNull("mediaLayers")
  if node["richText"] != nil or node["html"] != nil or node.eqs("sourceType", "htmlTable") or
      shape == "table": style.set("html", "1")
  if truthy(node["cscript"]): style.set("cscript", encodeURIComponent(str(node["cscript"])))
  else: style.setNull("cscript")
  if truthy(node["bookmark"]): style.set("bookmark", "1") else: style.setNull("bookmark")
  if truthy(node["container"]): style.set("container", "1") else: style.setNull("container")
  style.setVal("childLayout", node["childLayout"])
  let stack = node["stackHorizontal"]
  if stack.isTrue: style.set("horizontalStack", "1")
  elif stack.isFalse: style.set("horizontalStack", "0")
  else: style.setNull("horizontalStack")
  style.setVal("stackSpacing", node["stackSpacing"])
  style.setVal("stackBorder", node["stackBorder"])
  for (key, styleKey) in [("resizeParent", "resizeParent"), ("resizeParentMax", "resizeParentMax"),
                          ("resizeLast", "resizeLast")]:
    if node.get(key).isTrue: style.set(styleKey, "1") else: style.setNull(styleKey)
  let gaps = node["allowStackGaps"]
  if gaps.isFalse: style.set("allowGaps", "0")
  elif gaps.isTrue: style.set("allowGaps", "1")
  else: style.setNull("allowGaps")
  let collapsible = node["collapsible"]
  if collapsible.isFalse: style.set("collapsible", "0")
  elif collapsible.isTrue: style.set("collapsible", "1")
  else: style.setNull("collapsible")
  writeRuntimeStyle(style, node)
  if node.eqs("kind", "visualScript"):
    style.set("html", "1")
    let vsType = if truthy(node["vsType"]): str(node["vsType"])
                 elif node["visualScript"].isObj and truthy(node["visualScript"]["vsType"]): str(node["visualScript"]["vsType"])
                 else: "process"
    style.set("vsType", vsType)
    style.set("align", "left")
    style.set("verticalAlign", "top")
    style.set("overflow", "hidden")
    style.set("spacing", "0")
    style.set("editable", "0")
    style.set("rounded", "1")
    if nullish(node["radius"]): style.setNum("arcSize", 6) else: style.setVal("arcSize", node["radius"])
  var fontStyle = 0
  if num(node["fontWeight"]) >= 700 or truthy(node["bold"]): fontStyle = fontStyle or FontBold
  if truthy(node["italic"]): fontStyle = fontStyle or FontItalic
  if truthy(node["underline"]): fontStyle = fontStyle or FontUnderline
  if truthy(node["strikethrough"]): fontStyle = fontStyle or FontStrike
  if fontStyle > 0: style.setNum("fontStyle", float64(fontStyle)) else: style.setNull("fontStyle")
  encodeStyle(style)

proc edgeToStyle(edge: Val): string =
  var style = if edge["mx"].isObj: decodeStyle(str(edge["mx"]["style"])) else: Style()
  let ls = if edge["lineStyle"].isStr: edge["lineStyle"].s else: ""
  style.set("edgeStyle", if ls == "straight" or ls == "circular": "none" else: "orthogonalEdgeStyle")
  if ls == "curved": style.set("curved", "1") else: style.setNull("curved")
  if ls == "circular":
    style.set("qochartRoute", "circular")
    style.setVal("arcSweep", edge["arcSweep"])
    style.setVal("arcSide", edge["arcSide"])
    style.setVal("circleRadius", edge["circleRadius"])
  else:
    for k in ["qochartRoute", "arcSweep", "arcSide", "circleRadius"]: style.setNull(k)
  style.setVal("strokeColor", colorOut(edge["stroke"]))
  style.setVal("strokeWidth", edge["strokeWidth"])
  if truthy(edge["dashed"]): style.set("dashed", "1") else: style.setNull("dashed")
  if nullish(edge["opacity"]): style.setNull("opacity")
  else: style.setNum("opacity", jsRound(num(edge["opacity"]) * 100))
  let sa = arrowOut(if edge["startArrow"].isStr: edge["startArrow"].s else: "")
  style.set("startArrow", if sa.len > 0: sa else: "none")
  let ea = arrowOut(if edge["endArrow"].isStr: edge["endArrow"].s else: "")
  style.set("endArrow", if ea.len > 0: ea else: "block")
  style.setVal("endSize", edge["arrowSize"])
  style.setVal("fontColor", colorOut(edge["textColor"]))
  style.setVal("fontSize", edge["fontSize"])
  writeRuntimeStyle(style, edge)
  if truthy(edge["sourceLabel"]): style.set("qochartSourceLabel", encodeURIComponent(str(edge["sourceLabel"])))
  else: style.setNull("qochartSourceLabel")
  if truthy(edge["targetLabel"]): style.set("qochartTargetLabel", encodeURIComponent(str(edge["targetLabel"])))
  else: style.setNull("qochartTargetLabel")
  style.setVal("qochartEdgeSymbol", edge["edgeSymbol"])
  if truthy(edge["sourceAnchor"]):
    style.setVal("exitX", edge["sourceAnchor"]["x"])
    style.setVal("exitY", edge["sourceAnchor"]["y"])
  if truthy(edge["targetAnchor"]):
    style.setVal("entryX", edge["targetAnchor"]["x"])
    style.setVal("entryY", edge["targetAnchor"]["y"])
  encodeStyle(style)

proc textCell(raw: Val): Val =
  result = newObj()
  result["text"] = raw

proc tableHtmlFor(item: Val): string =
  let rows = max(1, int(jsNumOr(item["rows"], 1)))
  let columns = max(1, int(jsNumOr(item["columns"], 1)))
  var rowWeights, columnWeights: seq[float64]
  if item["rowWeights"].isArr and item["rowWeights"].len == rows:
    for w in item["rowWeights"]: rowWeights.add num(w)
  else: rowWeights = newSeq[float64](rows).mapOnes()
  if item["columnWeights"].isArr and item["columnWeights"].len == columns:
    for w in item["columnWeights"]: columnWeights.add num(w)
  else: columnWeights = newSeq[float64](columns).mapOnes()
  var rowTotal = 0.0
  for w in rowWeights: rowTotal += (if w != w: 0.0 else: w)
  if rowTotal == 0: rowTotal = float64(rows)
  var columnTotal = 0.0
  for w in columnWeights: columnTotal += (if w != w: 0.0 else: w)
  if columnTotal == 0: columnTotal = float64(columns)
  let border = if nullish(item["tableBorder"]): 1.0 else: max(0.0, jsNumOr(item["tableBorder"], 0))
  let padding = if nullish(item["tableCellPadding"]): 0.0 else: max(0.0, jsNumOr(item["tableCellPadding"], 0))
  var tableAttrs = ""
  if truthy(item["fixedRows"]): tableAttrs.add " data-pixel-fixed-rows=\"1\""
  tableAttrs.add " data-pixel-reorder-rows=\"" & (if item["reorderRows"].isFalse: "0" else: "1") & "\""
  if not nullish(item["rowIndexColumn"]):
    tableAttrs.add " data-pixel-row-index-column=\"" & jsStr(max(0.0, jsNumOr(item["rowIndexColumn"], 0))) & "\""
  if item["rowLines"].isFalse: tableAttrs.add " data-pixel-row-lines=\"0\""
  if truthy(item["firstRowLine"]): tableAttrs.add " data-pixel-first-row-line=\"1\""
  var html = "<table border=\"" & jsStr(border) & "\" width=\"100%\" height=\"100%\" cellpadding=\"" &
    jsStr(padding) & "\"" & tableAttrs & " style=\"width:100%;height:100%;border-collapse:collapse;\">"
  if not nullish(item["tableTitle"]):
    html.add "<caption data-pixel-height=\"" & jsStr(max(1.0, jsNumOr(item["tableTitleHeight"], 30))) &
      "\" style=\"caption-side:top;font-weight:bold;text-align:center;\">" &
      escapeHtml(str(item["tableTitle"])) & "</caption>"
  html.add "<colgroup>"
  for c in 0 ..< columns:
    html.add "<col style=\"width:" & jsStr(jsRound(columnWeights[c] / columnTotal * 10000) / 100) & "%\">"
  html.add "</colgroup>"
  let cells = item["cells"]
  proc cellOriginAt(row, column: int): (int, int, Val, int, int) =
    if cells.isObj:
      for (key, raw) in cells.pairs:
        let parts = key.split(',')
        let originRow = int(jsNumber(parts[0]))
        let originColumn = int(jsNumber(if parts.len > 1: parts[1] else: ""))
        let cell = if raw.isStr: textCell(raw) elif raw.isObj: raw else: newObj()
        let rowspan = max(1, min(rows - originRow, int(jsNumOr(cell["rowspan"], 1))))
        let colspan = max(1, min(columns - originColumn, int(jsNumOr(cell["colspan"], 1))))
        if row >= originRow and row < originRow + rowspan and
            column >= originColumn and column < originColumn + colspan:
          return (originRow, originColumn, cell, rowspan, colspan)
    (row, column, newObj(), 1, 1)
  for r in 0 ..< rows:
    html.add "<tr style=\"height:" & (if truthy(item["fixedRows"]):
      jsStr(max(1.0, (if rowWeights[r] != rowWeights[r] or rowWeights[r] == 0: 1.0 else: rowWeights[r]))) & "px"
      else: jsStr(jsRound(rowWeights[r] / rowTotal * 10000) / 100) & "%") & "\">"
    var column = 0
    while column < columns:
      let (orow, ocol, cell, rowSpan, span) = cellOriginAt(r, column)
      if orow != r or ocol != column:
        inc column
        continue
      let tag = if cell.eqs("tag", "th") or (truthy(item["headerRow"]) and r == 0): "th" else: "td"
      var styles: seq[string]
      if truthy(cell["fill"]): styles.add "background-color:" & str(cell["fill"])
      if truthy(cell["textColor"]): styles.add "color:" & str(cell["textColor"])
      if truthy(cell["align"]): styles.add "text-align:" & str(cell["align"])
      if truthy(cell["fontWeight"]): styles.add "font-weight:" & str(cell["fontWeight"])
      if truthy(cell["fontFamily"]): styles.add "font-family:" & str(cell["fontFamily"])
      if truthy(cell["fontSize"]): styles.add "font-size:" & str(cell["fontSize"]) & "px"
      if truthy(cell["italic"]): styles.add "font-style:italic"
      if truthy(cell["underline"]) or truthy(cell["strikethrough"]):
        styles.add "text-decoration:" & (if truthy(cell["underline"]): "underline " else: "") &
          (if truthy(cell["strikethrough"]): "line-through" else: "")
      if truthy(cell["verticalAlign"]): styles.add "vertical-align:" & str(cell["verticalAlign"])
      if not nullish(cell["opacity"]): styles.add "opacity:" & str(cell["opacity"])
      if cell["wordWrap"].isFalse: styles.add "white-space:nowrap"
      if not nullish(cell["textPadding"]): styles.add "padding:" & str(cell["textPadding"]) & "px"
      if border != 0 and truthy(item["gridStroke"]): styles.add "border:1px solid " & str(item["gridStroke"])
      if truthy(cell["stroke"]):
        styles.add "border:" & (if truthy(cell["strokeWidth"]): str(cell["strokeWidth"]) else: "1") & "px " &
          (if truthy(cell["dashed"]): "dashed " else: "solid ") & str(cell["stroke"])
      var content: string
      if not nullish(cell["richText"]): content = toHtml(cell["richText"])
      elif not nullish(cell["html"]): content = str(cell["html"])
      else: content = escapeHtml(if truthy(cell["text"]): str(cell["text"]) else: "").replace("\n", "<br>")
      if truthy(cell["link"]): content = "<a href=\"" & escapeAttrXml(str(cell["link"])) & "\">" & content & "</a>"
      html.add "<" & tag & (if span > 1: " colspan=\"" & $span & "\"" else: "") &
        (if rowSpan > 1: " rowspan=\"" & $rowSpan & "\"" else: "") &
        (if truthy(cell["align"]): " align=\"" & escapeAttrXml(str(cell["align"])) & "\"" else: "") &
        (if styles.len > 0: " style=\"" & escapeAttrXml(styles.join(";")) & "\"" else: "") & ">" &
        content & "</" & tag & ">"
      column += span
    html.add "</tr>"
  html & "</table>"

proc labelFor(item: Val): string =
  if item.eqs("shape", "table"): return tableHtmlFor(item)
  if not nullish(item["richText"]): return toHtml(item["richText"])
  if not nullish(item["html"]): return str(item["html"])
  if truthy(item["text"]): str(item["text"]) else: ""

proc serialize*(scene: Val): string =
  let diagram = if scene["diagram"].isObj: scene["diagram"] else: newObj()
  var items: seq[Val]
  for item in scene["items"]:
    if not truthy(item["foldedAway"]): items.add item
  var known = initTable[string, Val]()
  for item in items: known[idOf(item)] = item
  proc isKnown(v: Val): bool = not nullish(v) and known.hasKey(str(v))
  var lines: seq[string]
  lines.add "<mxGraphModel dx=\"1200\" dy=\"800\"" &
    " grid=\"" & (if diagram["gridEnabled"].isFalse: "0" else: "1") & "\"" &
    " gridSize=\"" & (if truthy(diagram["gridSize"]): str(diagram["gridSize"]) else: "10") & "\"" &
    " guides=\"" & (if diagram["guidesEnabled"].isFalse: "0" else: "1") & "\"" &
    " tooltips=\"" & (if diagram["tooltipsEnabled"].isFalse: "0" else: "1") & "\"" &
    " connect=\"1\" arrows=\"1\" fold=\"1\"" &
    " page=\"" & (if truthy(diagram["pageView"]): "1" else: "0") & "\"" &
    " pageScale=\"" & (if truthy(diagram["pageScale"]): str(diagram["pageScale"]) else: "1") & "\"" &
    " pageWidth=\"" & jsStr(jsRound(if truthy(diagram["pageWidth"]): num(diagram["pageWidth"]) else: 850)) & "\"" &
    " pageHeight=\"" & jsStr(jsRound(if truthy(diagram["pageHeight"]): num(diagram["pageHeight"]) else: 1100)) & "\"" &
    " background=\"" & (if truthy(diagram["backgroundColor"]): str(diagram["backgroundColor"]) else: "#ffffff") & "\"" &
    (if scene["layers"].isArr and scene["layers"].len > 0:
      " qochartLayers=\"" & escapeAttrXml(encodedJson(scene["layers"])) & "\"" else: "") & ">"
  lines.add "  <root>"
  lines.add "    <mxCell id=\"0\" />"
  lines.add "    <mxCell id=\"1\" parent=\"0\" />"
  for item in items:
    let isEdge = item.eqs("type", "edge")
    if isEdge and ((not isKnown(item["sourceId"]) and not truthy(item["sourcePoint"])) or
                   (not isKnown(item["targetId"]) and not truthy(item["targetPoint"]))): continue
    let mx = if item["mx"].isObj: item["mx"] else: newObj()
    let style = if isEdge: edgeToStyle(item) else: nodeToStyle(item)
    let label = labelFor(item)
    let parentId = if not isEdge and isKnown(item["containerId"]): str(item["containerId"]) else: "1"
    let parentItem = known.getOrDefault(parentId, nil)
    var geometry: string
    if isEdge:
      geometry = "<mxGeometry relative=\"1\" as=\"geometry\">"
      if not isKnown(item["sourceId"]) and truthy(item["sourcePoint"]):
        geometry.add "<mxPoint x=\"" & numberOut(num(item["sourcePoint"]["x"])) & "\" y=\"" &
          numberOut(num(item["sourcePoint"]["y"])) & "\" as=\"sourcePoint\" />"
      if not isKnown(item["targetId"]) and truthy(item["targetPoint"]):
        geometry.add "<mxPoint x=\"" & numberOut(num(item["targetPoint"]["x"])) & "\" y=\"" &
          numberOut(num(item["targetPoint"]["y"])) & "\" as=\"targetPoint\" />"
      if item["route"].isArr and item["route"].len > 0:
        geometry.add "<Array as=\"points\">"
        for p in item["route"]:
          geometry.add "<mxPoint x=\"" & numberOut(num(p["x"])) & "\" y=\"" & numberOut(num(p["y"])) & "\" />"
        geometry.add "</Array>"
      geometry.add "</mxGeometry>"
    else:
      let localX = num(item["x"]) - (if parentItem != nil: num(parentItem["x"]) else: 0.0)
      let localY = num(item["y"]) - (if parentItem != nil: num(parentItem["y"]) else: 0.0)
      geometry = "<mxGeometry x=\"" & numberOut(localX) & "\" y=\"" & numberOut(localY) &
        "\" width=\"" & numberOut(num(item["width"])) & "\" height=\"" & numberOut(num(item["height"])) &
        "\" as=\"geometry\" />"
    var attrs = " style=\"" & escapeAttrXml(style) & "\"" & (if isEdge: " edge=\"1\"" else: " vertex=\"1\"") &
      " parent=\"" & escapeAttrXml(parentId) & "\""
    if isEdge and isKnown(item["sourceId"]): attrs.add " source=\"" & escapeAttrXml(str(item["sourceId"])) & "\""
    if isEdge and isKnown(item["targetId"]): attrs.add " target=\"" & escapeAttrXml(str(item["targetId"])) & "\""
    if item["visible"].isFalse: attrs.add " visible=\"0\""
    let wrapperTag = if truthy(mx["wrapperTag"]): str(mx["wrapperTag"])
                     elif item.eqs("kind", "visualScript"): "VisualScript"
                     elif truthy(item["link"]): "UserObject" else: ""
    if wrapperTag.len > 0:
      let sourceAttrs = newObj()
      if mx["wrapperAttrs"].isObj:
        for (k, v) in mx["wrapperAttrs"].pairs: sourceAttrs.put(k, v)
      if item.eqs("kind", "visualScript") and item["visualScript"].isObj:
        for (k, v) in item["visualScript"].pairs: sourceAttrs.put(k, v)
      if item.eqs("kind", "visualScript"):
        sourceAttrs["vsType"] = if truthy(item["vsType"]): item["vsType"]
                                elif truthy(sourceAttrs["vsType"]): sourceAttrs["vsType"] else: jstr("process")
        sourceAttrs["label"] = if truthy(item["text"]): item["text"]
                               elif truthy(sourceAttrs["label"]): sourceAttrs["label"] else: sourceAttrs["vsType"]
      if not truthy(sourceAttrs["label"]) and not truthy(sourceAttrs["value"]): sourceAttrs["label"] = jstr(label)
      if not truthy(sourceAttrs["id"]): sourceAttrs["id"] = item["id"]
      if truthy(item["link"]): sourceAttrs["link"] = item["link"]
      else: sourceAttrs.del("link")
      var wrapperAttrs = ""
      var seenId = false
      for (name, value) in sourceAttrs.pairs:
        var v = if nullish(value): "" else: str(value)
        if name == "label" or name == "value": v = label
        if name == "id": seenId = true
        wrapperAttrs.add " " & name & "=\"" & escapeAttrXml(v) & "\""
      if not seenId: wrapperAttrs.add " id=\"" & escapeAttrXml(idOf(item)) & "\""
      lines.add "    <" & wrapperTag & wrapperAttrs & ">"
      lines.add "      <mxCell" & attrs & ">"
      lines.add "        " & geometry
      lines.add "      </mxCell>"
      lines.add "    </" & wrapperTag & ">"
    else:
      lines.add "    <mxCell id=\"" & escapeAttrXml(idOf(item)) & "\" value=\"" & escapeAttrXml(label) & "\"" &
        attrs & ">"
      lines.add "      " & geometry
      lines.add "    </mxCell>"
  lines.add "  </root>"
  lines.add "</mxGraphModel>"
  lines.join("\n")
