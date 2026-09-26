## Classic mxGraph XML -> the retained canvas scene (Editor.importLegacyGraph).
##
## Geometry becomes absolute because the canvas scene is flat, but every
## vertex keeps its legacy parent as containerId. Named widgets are not
## recognised: a swimlane containing rows, ellipses and text remains those
## same independently selectable cells after import. Classic titled tables
## (table -> row -> cell vertices) and HTML tables in labels become the
## retained table model.

import std/[tables, strutils]
import ../jsval, ../geometry
import xml, htmltree, jsutil, data

proc obj2(x, y: float64): Val =
  result = newObj()
  result["x"] = jnum(x)
  result["y"] = jnum(y)

proc looksLikeTag(s: string): bool =
  ## /<[^>]+>/.test(s)
  var i = s.find('<')
  while i >= 0:
    let gt = s.find('>', i + 1)
    if gt < 0: return false
    if gt > i + 1: return true
    i = s.find('<', i + 1)
  false

type
  LegacyError* = object of CatchableError

  Record = ref object
    id: string
    wrapper, cell, geometry: XNode
    parent: string
    style: Table[string, string]

  Geo = object
    x, y, width, height: float64

proc numberAttribute(node: XNode, name: string, fallback: float64): float64 =
  ## Number(node.getAttribute(name)), fallback when that is not finite (a
  ## missing attribute reads as Number(null) = 0).
  if node == nil: return fallback
  let value = jsNumberOrNull(node.hasAttr(name), node.attr(name))
  if isFiniteJs(value): value else: fallback

proc parseLegacyStyle*(text: string): Table[string, string] =
  for part in text.split(';'):
    if part.len == 0: continue
    let equals = part.find('=')
    if equals < 0: result["shape"] = part
    else: result[part[0 ..< equals]] = part[equals + 1 .. ^1]

proc sget(style: Table[string, string], key: string): (bool, string) =
  if style.hasKey(key): (true, style[key]) else: (false, "")

template has(style: Table[string, string], key: string): bool = style.hasKey(key)
template sv(style: Table[string, string], key: string): string = style.getOrDefault(key, "")

proc legacyShape(style: Table[string, string]): string =
  let shape = if style.has("shape") and style["shape"].len > 0: style["shape"] else: "rect"
  case shape
  of "rectangle", "label", "process", "internalStorage", "ext": "rect"
  of "rhombus": "diamond"
  of "umlActor": "actor"
  of "cylinder2", "cylinder3": "cylinder"
  of "doubleEllipse": "ellipse"
  of "icon": "image"
  else: shape

proc hasMarkup(value: string): bool = '<' in value or '&' in value

proc textFromHtml*(value: string): string =
  ## Plain text of a label; <br> becomes a line break.
  if not hasMarkup(value): return value
  let tree = parseHtml(value)
  jsTrim(tree.textWithBreaks().replace("\xC2\xA0", " "))

proc numericSize(value: string): float64 =
  let parsed = jsParseFloat(value)
  if isFiniteJs(parsed) and parsed > 0: parsed else: 1.0

# -------------------------------------------------------------- HTML tables --

proc tableRows(table: HNode): seq[HNode] =
  ## HTMLTableElement.rows order: thead rows, then table/tbody rows, then
  ## tfoot rows, each in tree order.
  var head, bodyRows, foot: seq[HNode]
  for child in table.elements:
    case child.local
    of "tr": bodyRows.add child
    of "thead":
      for r in child.elements:
        if r.local == "tr": head.add r
    of "tbody":
      for r in child.elements:
        if r.local == "tr": bodyRows.add r
    of "tfoot":
      for r in child.elements:
        if r.local == "tr": foot.add r
    else: discard
  head & bodyRows & foot

proc rowCells(row: HNode): seq[HNode] =
  for c in row.elements:
    if c.local in ["td", "th"]: result.add c

proc inlineColor(element: HNode, property: string, attribute = ""): string =
  let fromStyle = element.styleProp(property)
  if fromStyle.len > 0: return fromStyle
  element.attr(if attribute.len > 0: attribute else: property)

proc tableFromHtml*(value: string): Val =
  ## An HTML <table> label as retained table data, or nil.
  if not value.toLowerAscii().contains("<table") : return nil
  var found = false
  let lower = value.toLowerAscii()
  var p = lower.find("<table")
  while p >= 0:
    let after = p + 6
    if after >= lower.len or lower[after] notin {'a'..'z', '0'..'9', '_'}:
      found = true
      break
    p = lower.find("<table", p + 1)
  if not found: return nil
  let host = parseHtml(value, withMarkup = true)
  let table = host.findFirst("table")
  if table == nil: return nil
  let rows = tableRows(table)
  if rows.len == 0: return nil

  type Placement = object
    row, column, colspan, rowspan: int
    cell: HNode
  var columns = 0
  var placements: seq[Placement]
  var occupied = initTable[(int, int), bool]()
  for rowIndex, row in rows:
    var column = 0
    for cell in rowCells(row):
      while occupied.hasKey((rowIndex, column)): inc column
      let colspan = max(1, cell.colSpan)
      let rowspan = max(1, min(rows.len - rowIndex, (if cell.rowSpan == 0: 1 else: cell.rowSpan)))
      placements.add Placement(row: rowIndex, column: column, colspan: colspan,
                               rowspan: rowspan, cell: cell)
      for rr in rowIndex ..< rowIndex + rowspan:
        for cc in column ..< column + colspan:
          occupied[(rr, cc)] = true
      column += colspan
      columns = max(columns, column)
    for key in occupied.keys:
      if key[0] == rowIndex: columns = max(columns, key[1] + 1)
  if columns == 0: return nil

  let cells = newObj()
  let rowWeights = newArr()
  var columnWeights = newSeq[float64](columns)
  for i in 0 ..< columns: columnWeights[i] = 1
  var authored: seq[HNode]
  for colgroup in table.findAll("colgroup"):
    for col in colgroup.findAll("col"): authored.add col
  let hasAuthoredColumns = authored.len == columns
  if hasAuthoredColumns:
    for index, column in authored:
      let w = column.styleProp("width")
      columnWeights[index] = numericSize(if w.len > 0: w else: column.attr("width"))

  for rowIndex, row in rows:
    let h = row.styleProp("height")
    rowWeights.push jnum(numericSize(if h.len > 0: h else: row.attr("height")))
    for placement in placements:
      if placement.row != rowIndex: continue
      let sourceCell = placement.cell
      let column = placement.column
      let span = placement.colspan
      var fill = inlineColor(sourceCell, "backgroundColor", "bgcolor")
      if fill.len == 0: fill = inlineColor(row, "backgroundColor", "bgcolor")
      var color = inlineColor(sourceCell, "color")
      if color.len == 0: color = inlineColor(row, "color")
      var align = sourceCell.attr("align")
      if align.len == 0: align = sourceCell.styleProp("textAlign")
      if align.len == 0: align = row.attr("align")
      if align.len == 0: align = row.styleProp("textAlign")
      let cell = newObj()
      cell["text"] = jstr(textFromHtml(sourceCell.inner))
      cell["html"] = jstr(sourceCell.inner)
      cell["tag"] = jstr(sourceCell.tag.toLowerAscii())
      cell["colspan"] = jnum(span)
      cell["rowspan"] = jnum(placement.rowspan)
      if span == 1: cell.del("colspan")
      if placement.rowspan == 1: cell.del("rowspan")
      if fill.len > 0: cell["fill"] = jstr(fill)
      if color.len > 0: cell["textColor"] = jstr(color)
      if align.len > 0: cell["align"] = jstr(align)
      let fw = sourceCell.styleProp("fontWeight")
      let fwl = fw.toLowerAscii()
      if cell.eqs("tag", "th") or fwl.contains("bold") or
          (fwl.len >= 3 and (fwl.contains("600") or fwl.contains("700") or
                             fwl.contains("800") or fwl.contains("900"))):
        cell["fontWeight"] = jnum(700)
      elif fw.len > 0:
        let n = jsNumber(fw)
        cell["fontWeight"] = jnum(if n == 0 or n != n: 400.0 else: n)
      let ff = sourceCell.styleProp("fontFamily")
      if ff.len > 0: cell["fontFamily"] = jstr(ff)
      let fs = sourceCell.styleProp("fontSize")
      if fs.len > 0: cell["fontSize"] = jnum(numericSize(fs))
      if sourceCell.styleProp("fontStyle") == "italic": cell["italic"] = jtrue
      var decoration = sourceCell.styleProp("textDecoration")
      if decoration.len == 0: decoration = sourceCell.styleProp("textDecorationLine")
      if decoration.contains("underline"): cell["underline"] = jtrue
      if decoration.contains("line-through"): cell["strikethrough"] = jtrue
      let va = sourceCell.styleProp("verticalAlign")
      if va.len > 0: cell["verticalAlign"] = jstr(va)
      let op = sourceCell.styleProp("opacity")
      if op.len > 0: cell["opacity"] = jnum(jsNumber(op))
      if sourceCell.styleProp("whiteSpace") == "nowrap": cell["wordWrap"] = jfalse
      let pad = sourceCell.styleProp("padding")
      if pad.len > 0: cell["textPadding"] = jnum(numericSize(pad))
      let bc = sourceCell.styleProp("borderColor")
      if bc.len > 0: cell["stroke"] = jstr(bc)
      let bw = sourceCell.styleProp("borderWidth")
      if bw.len > 0: cell["strokeWidth"] = jnum(numericSize(bw))
      if sourceCell.styleProp("borderStyle") == "dashed": cell["dashed"] = jtrue
      let link = sourceCell.findFirstWhere(proc(x: HNode): bool = x.local == "a" and x.hasAttr("href"))
      if link != nil: cell["link"] = jstr(link.attr("href"))
      cells.put($rowIndex & "," & $column, cell)
      if rowIndex == 0 and not hasAuthoredColumns:
        var width = sourceCell.styleProp("width")
        if width.len == 0: width = sourceCell.attr("width")
        if width.len > 0:
          let each = numericSize(width) / float64(span)
          var s = 0
          while s < span and column + s < columns:
            columnWeights[column + s] = each
            inc s

  let firstCells = rowCells(rows[0])
  var firstRowIsHeader = firstCells.len > 0
  for c in firstCells:
    if c.tag.toLowerAscii() != "th": firstRowIsHeader = false
  let border = block:
    let n = jsNumberOrNull(table.hasAttr("border"), table.attr("border"))
    if n != n or n == 0: 0.0 else: n
  var gridStroke = "#000000"
  for r in rows:
    let bc = r.styleProp("borderColor")
    if bc.len > 0:
      gridStroke = bc
      break
  let caption = table.findFirst("caption")
  var titleHeight = 0.0
  if caption != nil:
    var h = caption.attr("data-pixel-height")
    if h.len == 0: h = caption.styleProp("height")
    titleHeight = if h.len == 0: numericSize("30") else: numericSize(h)
  let fixedRows = table.attr("data-pixel-fixed-rows") == "1"
  let reorderRows = table.attr("data-pixel-reorder-rows") != "0" or not table.hasAttr("data-pixel-reorder-rows")
  let cellPadding = block:
    let n = jsNumberOrNull(table.hasAttr("cellpadding"), table.attr("cellpadding"))
    if n != n or n == 0: 0.0 else: n

  result = newObj()
  result["rows"] = jnum(rows.len)
  result["columns"] = jnum(columns)
  result["cells"] = cells
  result["rowWeights"] = rowWeights
  let cw = newArr()
  for w in columnWeights: cw.push jnum(w)
  result["columnWeights"] = cw
  result["headerRow"] = jbool(firstRowIsHeader)
  result["tableBorder"] = jnum(border)
  result["tableCellPadding"] = jnum(cellPadding)
  result["gridStroke"] = jstr(gridStroke)
  result["html"] = jstr(table.outer)
  result["sourceType"] = jstr("htmlTable")
  result["tableTitle"] = if caption != nil: jstr(jsTrim(caption.textContent())) else: jnull
  result["tableTitleHeight"] = jnum(titleHeight)
  result["fixedRows"] = jbool(fixedRows)
  result["reorderRows"] = jbool(reorderRows)
  result["rowIndexColumn"] = if table.hasAttr("data-pixel-row-index-column"):
      jnum(jsNumber(table.attr("data-pixel-row-index-column"))) else: jnull
  result["rowLines"] = jbool(table.attr("data-pixel-row-lines") != "0")
  result["firstRowLine"] = jbool(table.attr("data-pixel-first-row-line") == "1")

# ---------------------------------------------------------------- import --

proc legacyLabel(r: Record): string =
  if r.wrapper == r.cell: r.cell.attr("value") else: r.wrapper.attr("label")

proc isVertex(r: Record): bool = r.cell.attr("vertex") == "1"

proc importLegacyGraph*(text: string): Val =
  ## Raises LegacyError (or XmlError) for documents it cannot read.
  var model: XNode
  try:
    model = parseXml(text)
  except XmlError as e:
    raise newException(LegacyError, "Invalid mxGraph XML: " & e.msg)
  if model.name == "mxfile":
    let diagram = model.firstByTag("diagram")
    if diagram == nil or diagram.elementChildren().len == 0:
      raise newException(LegacyError, "Compressed mxfile diagrams are not supported by this importer")
    model = diagram.elementChildren()[0]
  if model == nil or model.name != "mxGraphModel":
    raise newException(LegacyError, "This file is not an mxGraphModel document")

  let rootNode = model.firstByTag("root")
  if rootNode == nil: raise newException(LegacyError, "The mxGraphModel has no root")
  var records: seq[Record]
  var byId = initTable[string, Record]()
  var childrenByParent = initTable[string, seq[Record]]()

  var i = 0
  for wrapper in rootNode.elements:
    var cell: XNode = nil
    if wrapper.name == "mxCell": cell = wrapper
    else:
      for child in wrapper.elements:
        if child.name == "mxCell":
          cell = child
          break
    if cell == nil:
      inc i
      continue
    var id = cell.attr("id")
    if id.len == 0: id = wrapper.attr("id")
    if id.len == 0: id = "legacy-" & $i
    var geometry: XNode = nil
    for child in cell.elements:
      if child.name == "mxGeometry":
        geometry = child
        break
    let record = Record(id: id, wrapper: wrapper, cell: cell, parent: cell.attr("parent"),
                        style: parseLegacyStyle(cell.attr("style")), geometry: geometry)
    records.add record
    byId[id] = record
    childrenByParent.mgetOrPut(record.parent, @[]).add record
    inc i

  var absoluteCache = initTable[string, Geo]()
  proc absoluteGeometry(record: Record, visiting: var Table[string, bool]): Geo =
    if absoluteCache.hasKey(record.id): return absoluteCache[record.id]
    let geometry = record.geometry
    var r = Geo(x: numberAttribute(geometry, "x", 0), y: numberAttribute(geometry, "y", 0),
                width: max(1.0, numberAttribute(geometry, "width", 80)),
                height: max(1.0, numberAttribute(geometry, "height", 40)))
    let parent = byId.getOrDefault(record.parent, nil)
    if parent != nil and parent != record and not visiting.hasKey(record.id):
      visiting[record.id] = true
      let pg = absoluteGeometry(parent, visiting)
      if geometry != nil and geometry.attr("relative") == "1":
        r.x = pg.x + r.x * pg.width
        r.y = pg.y + r.y * pg.height
      else:
        r.x += pg.x
        r.y += pg.y
      visiting.del(record.id)
    absoluteCache[record.id] = r
    r

  proc geometryOf(record: Record): Geo =
    var visiting = initTable[string, bool]()
    absoluteGeometry(record, visiting)

  # Classic titled tables: collapse table -> row -> cell into one model.
  var structuralTables = initTable[string, Val]()
  var structuralDescendants = initTable[string, bool]()
  for tableRecord in records:
    if not tableRecord.isVertex or tableRecord.style.sv("childLayout") != "tableLayout": continue
    var rowRecords: seq[Record]
    for row in childrenByParent.getOrDefault(tableRecord.id, @[]):
      if row.isVertex: rowRecords.add row
    if rowRecords.len == 0: continue
    var columnCount = 0
    for row in rowRecords:
      var n = 0
      for c in childrenByParent.getOrDefault(row.id, @[]):
        if c.isVertex: inc n
      columnCount = max(columnCount, n)
    if columnCount == 0: continue

    let d = newObj()
    d["rows"] = jnum(rowRecords.len)
    d["columns"] = jnum(columnCount)
    let dcells = newObj()
    d["cells"] = dcells
    let rw = newArr()
    let cw = newArr()
    d["rowWeights"] = rw
    d["columnWeights"] = cw
    d["tableTitle"] = jstr(textFromHtml(legacyLabel(tableRecord)))
    let startSize = jsNumber(tableRecord.style.sv("startSize"))
    d["tableTitleHeight"] = jnum(if tableRecord.style.has("startSize") and startSize == startSize and startSize != 0: startSize else: 30.0)
    d["fixedRows"] = jbool(tableRecord.style.sv("fixedRows") == "1")
    d["rowLines"] = jbool(tableRecord.style.sv("rowLines") != "0" or not tableRecord.style.has("rowLines"))
    d["firstRowLine"] = jfalse
    d["sourceType"] = jstr("htmlTable")
    d["tableBorder"] = jnum(1)
    d["gridStroke"] = jstr(if tableRecord.style.has("strokeColor") and tableRecord.style["strokeColor"].len > 0:
                             tableRecord.style["strokeColor"] else: "#4a5564")

    for rowIndex, rowRecord in rowRecords:
      rw.push jnum(max(1.0, numberAttribute(rowRecord.geometry, "height", 30)))
      if rowIndex == 0 and rowRecord.style.sv("bottom") == "1": d["firstRowLine"] = jtrue
      structuralDescendants[rowRecord.id] = true
      var cellRecords: seq[Record]
      for c in childrenByParent.getOrDefault(rowRecord.id, @[]):
        if c.isVertex: cellRecords.add c
      for columnIndex, cellRecord in cellRecords:
        structuralDescendants[cellRecord.id] = true
        let cellData = newObj()
        cellData["text"] = jstr(textFromHtml(legacyLabel(cellRecord)))
        cellData["align"] = jstr(if cellRecord.style.has("align") and cellRecord.style["align"].len > 0:
                                   cellRecord.style["align"] else: "center")
        let fontStyle = jsNumber(cellRecord.style.sv("fontStyle"))
        if fontStyle == fontStyle and (int(fontStyle) and 1) != 0: cellData["fontWeight"] = jnum(700)
        dcells.put($rowIndex & "," & $columnIndex, cellData)
        if rowIndex == 0:
          cw.push jnum(max(1.0, numberAttribute(cellRecord.geometry, "width", 60)))

    var indexed = true
    for rowIndex in 0 ..< rowRecords.len:
      let c = dcells.get($rowIndex & ",0")
      let t = if c != nil and c["text"] != nil and truthy(c["text"]): str(c["text"]) else: ""
      if jsTrim(t) != $(rowIndex + 1):
        indexed = false
        break
    if indexed:
      d["rowIndexColumn"] = jnum(0)
      d["reorderRows"] = jtrue
    structuralTables[tableRecord.id] = d

  var items: seq[Val]
  var importedIds = initTable[string, bool]()
  var z = 0

  proc styleNum(style: Table[string, string], key: string): float64 =
    ## Number(style[key]) with undefined -> NaN.
    if style.has(key): jsNumber(style[key]) else: NaN

  proc orDefault(x, d: float64): float64 = (if x != x or x == 0: d else: x)

  for record in records:
    if not record.isVertex: continue
    if structuralDescendants.hasKey(record.id): continue
    let geometry = geometryOf(record)
    let style = record.style
    let rawLabel = legacyLabel(record)
    let shape = legacyShape(style)
    let item = newObj()
    item["id"] = jstr(record.id)
    item["type"] = jstr("node")
    item["kind"] = jstr("shape")
    item["shape"] = jstr(shape)
    item["x"] = jnum(geometry.x)
    item["y"] = jnum(geometry.y)
    item["width"] = jnum(geometry.width)
    item["height"] = jnum(geometry.height)
    item["rotation"] = jnum(orDefault(styleNum(style, "rotation"), 0))
    item["fill"] = jstr(if style.sv("fillColor") == "none": "transparent"
                        elif style.sv("fillColor").len > 0: style["fillColor"] else: "#ffffff")
    item["stroke"] = jstr(if style.sv("strokeColor") == "none": "transparent"
                          elif style.sv("strokeColor").len > 0: style["strokeColor"] else: "#4a5564")
    item["strokeWidth"] = jnum(max(0.0, orDefault(styleNum(style, "strokeWidth"), 1)))
    item["text"] = jstr(textFromHtml(rawLabel))
    item["textColor"] = jstr(if style.sv("fontColor").len > 0: style["fontColor"] else: "#172033")
    item["fontSize"] = jnum(orDefault(styleNum(style, "fontSize"), 11))
    item["fontFamily"] = jstr(if style.sv("fontFamily").len > 0: style["fontFamily"] else: "Arial, Helvetica, sans-serif")
    item["fontWeight"] = jnum(400)
    item["textPadding"] = jnum(if not style.has("spacing"): 2.0
                               else: max(0.0, orDefault(styleNum(style, "spacing"), 0)))
    item["textAlign"] = jstr(if style.sv("align").len > 0: style["align"] else: "center")
    item["verticalAlign"] = jstr(if style.sv("verticalAlign").len > 0: style["verticalAlign"] else: "middle")
    item["radius"] = jnum(if style.sv("rounded") == "1": 10 else: 0)
    item["shadow"] = jbool(style.sv("shadow") == "1")
    item["dashed"] = jbool(style.sv("dashed") == "1")
    item["opacity"] = jnum(if not style.has("opacity"): 1.0
                           else: jsMax(0.0, jsMin(1.0, jsNumber(style["opacity"]) / 100)))
    item["visible"] = jbool(style.sv("visible") != "0" or not style.has("visible"))
    item["locked"] = jbool(style.has("movable") and style["movable"] == "0" and
                           style.has("resizable") and style["resizable"] == "0")
    for (key, name) in [("editable", "editable"), ("movable", "movable"), ("resizable", "resizable"),
                        ("deletable", "deletable"), ("connectable", "connectable"),
                        ("rotatable", "rotatable"), ("dropTarget", "dropTarget")]:
      item.put(key, jbool(not (style.has(name) and style[name] == "0")))
    item["part"] = jbool(style.sv("part") == "1")
    inc z
    item["z"] = jnum(z)
    let fontStyle = int(orDefault(styleNum(style, "fontStyle"), 0))
    if style.sv("double") == "1" or style.sv("shape") == "doubleEllipse": item["double"] = jtrue
    if style.has("isoAngle"): item["isoAngle"] = jnum(orDefault(styleNum(style, "isoAngle"), 15))
    if (fontStyle and 1) != 0: item["fontWeight"] = jnum(700)
    if (fontStyle and 2) != 0: item["italic"] = jtrue
    if (fontStyle and 4) != 0: item["underline"] = jtrue
    if style.sv("whiteSpace") != "wrap": item["wordWrap"] = jfalse
    let labelHasTag = looksLikeTag(rawLabel)
    if style.sv("html") == "1" and labelHasTag: item["html"] = jstr(rawLabel)
    let htmlTable = if style.sv("html") == "1": tableFromHtml(rawLabel) else: nil
    if htmlTable != nil:
      item["shape"] = jstr("table")
      for k in ["sourceType", "rows", "columns", "cells", "rowWeights", "columnWeights",
                "headerRow", "tableBorder", "tableCellPadding", "gridStroke", "html",
                "tableTitle", "tableTitleHeight", "fixedRows", "rowLines", "firstRowLine",
                "reorderRows", "rowIndexColumn"]:
        item.put(k, htmlTable.get(k))
      item["text"] = jstr("")
    let structuralTable = structuralTables.getOrDefault(record.id, nil)
    if structuralTable != nil:
      item["kind"] = jstr("table")
      item["shape"] = jstr("table")
      for k in ["sourceType", "rows", "columns", "cells", "rowWeights", "columnWeights",
                "tableTitle", "tableTitleHeight", "fixedRows", "rowLines", "firstRowLine",
                "rowIndexColumn", "reorderRows", "tableBorder", "gridStroke"]:
        item.put(k, structuralTable.get(k))
      item["container"] = jfalse
      item["childLayout"] = jnull
      item["text"] = jstr("")
    if shape == "text":
      if style.sv("fillColor").len == 0: item["fill"] = jstr("transparent")
      if style.sv("strokeColor").len == 0:
        item["stroke"] = jstr("transparent")
        item["strokeWidth"] = jnum(0)
    if shape == "image" and style.sv("image").len > 0:
      item["src"] = jstr(tryDecodeURIComponent(style["image"]))
      item["imageFit"] = jstr(if style.sv("imageAspect") == "0": "stretch" else: "contain")
      if style.sv("mediaType").len > 0: item["mediaType"] = jstr(style["mediaType"])
      if style.has("mediaLoop"): item["mediaLoop"] = jbool(style["mediaLoop"] != "0")
      if style.has("mediaVolume"):
        item["mediaVolume"] = jnum(jsMax(0.0, jsMin(1.0, jsNumber(style["mediaVolume"]) / 100)))
    if shape == "swimlane": item["headerHeight"] = jnum(orDefault(styleNum(style, "startSize"), 26))
    if style.has("size") and shape in ["trapezoid", "parallelogram", "hexagon", "chevron",
                                        "step", "cube", "cylinder", "note"]:
      var legacySize = jsNumber(style["size"])
      if legacySize > 1:
        legacySize = legacySize / (if shape == "cylinder": geometry.height
                                   elif shape in ["cube", "note"]: min(geometry.width, geometry.height)
                                   else: geometry.width)
      item["shapeSize"] = jnum(legacySize)
    if shape in ["blockArrow", "singleArrow", "doubleArrow"]:
      if style.has("arrowSize"): item["arrowSize"] = jnum(jsNumber(style["arrowSize"]))
      if style.has("arrowWidth"): item["arrowWidth"] = jnum(jsNumber(style["arrowWidth"]))
    if style.sv("direction").len > 0: item["direction"] = jstr(style["direction"])
    if style.sv("line").len > 0: item["line"] = jstr(style["line"])
    for side in ["top", "right", "bottom", "left"]:
      if style.has(side): item.put(side, jbool(style[side] != "0"))
    if style.has("size") and shape in ["manualInput", "loopLimit", "offPageConnector",
                                        "display", "cross", "corner", "tee", "datastore"]:
      item["shapeSize"] = jnum(jsNumber(style["size"]))

    # A VisualScript wrapper carries the card's data as attributes.
    if record.wrapper != record.cell and record.wrapper.name.toLowerAscii() == "visualscript":
      let visualAttrs = newObj()
      for (k, v) in record.wrapper.attrs: visualAttrs.put(k, jstr(v))
      item["kind"] = jstr("visualScript")
      let vsType = if truthy(visualAttrs.get("vsType")): str(visualAttrs.get("vsType"))
                   elif style.sv("vsType").len > 0: style["vsType"] else: "process"
      item["vsType"] = jstr(vsType)
      item["visualScript"] = visualAttrs
      item["text"] = if truthy(visualAttrs.get("label")): visualAttrs.get("label")
                     elif truthy(item["text"]): item["text"] else: jstr(vsType)
      item["shape"] = jstr("rect")
      item["fill"] = jstr(if style.sv("fillColor") == "none": "transparent"
                          elif style.sv("fillColor").len > 0: style["fillColor"] else: "#ffffff")
      item["radius"] = jnum(if style.sv("rounded") == "1": orDefault(styleNum(style, "arcSize"), 6) else: 0)
      item["editable"] = jfalse
      for definition in visualScriptDefinitions():
        if not definition.eqs("type", vsType): continue
        let vt = visualScriptTemplate(definition)
        item["visualRows"] = vt["visualRows"]
        item["visualSummary"] = vt["visualSummary"]
        if style.sv("strokeColor").len == 0: item["stroke"] = vt["stroke"]
        if style.sv("strokeWidth").len == 0: item["strokeWidth"] = vt["strokeWidth"]
        break
    if style.sv("childLayout").len > 0 and structuralTable == nil:
      item["childLayout"] = jstr(style["childLayout"])
    if style.has("horizontal"): item["horizontal"] = jbool(style["horizontal"] != "0")
    if style.has("horizontalStack"): item["stackHorizontal"] = jbool(style["horizontalStack"] != "0")
    if style.has("resizeParent"): item["resizeParent"] = jbool(style["resizeParent"] != "0")
    if style.has("resizeParentMax"): item["resizeParentMax"] = jbool(style["resizeParentMax"] != "0")
    elif style.sv("childLayout") == "stackLayout": item["resizeParentMax"] = jtrue
    if style.has("resizeLast"): item["resizeLast"] = jbool(style["resizeLast"] != "0")
    for (styleKey, itemKey) in [("stackSpacing", "stackSpacing"), ("stackBorder", "stackBorder"),
                                ("marginLeft", "marginLeft"), ("marginRight", "marginRight"),
                                ("marginTop", "marginTop"), ("marginBottom", "marginBottom")]:
      if style.has(styleKey): item.put(itemKey, jnum(orDefault(styleNum(style, styleKey), 0)))
    if style.has("allowGaps"): item["allowStackGaps"] = jbool(style["allowGaps"] != "0")
    if style.has("collapsible"): item["collapsible"] = jbool(style["collapsible"] != "0")
    let parentRecord = byId.getOrDefault(record.parent, nil)
    if parentRecord != nil and parentRecord.isVertex: item["containerId"] = jstr(parentRecord.id)
    items.add item
    importedIds[record.id] = true

  var itemsById = initTable[string, Val]()
  for item in items:
    if not itemsById.hasKey(idOf(item)): itemsById[idOf(item)] = item
  for item in items:
    if not truthy(item["containerId"]): continue
    let parent = itemsById.getOrDefault(str(item["containerId"]), nil)
    if parent != nil: parent["container"] = jtrue
    else: item.del("containerId")
  for item in items:
    let record = byId.getOrDefault(idOf(item), nil)
    if record != nil and record.style.sv("container") == "1": item["container"] = jtrue

  for record in records:
    if record.cell.attr("edge") != "1": continue
    let style = record.style
    let sourceId = record.cell.attr("source")
    let targetId = record.cell.attr("target")
    let legacyEdgeStyle = style.sv("edgeStyle")
    let les = legacyEdgeStyle.toLowerAscii()
    let lineStyle = if style.sv("curved") == "1": "curved"
                    elif les == "none" or les == "straight": "straight"
                    elif les.len == 0 or les.contains("orthogonal") or les.contains("elbow") or
                         les.contains("segment") or les.contains("isometric"): "orthogonal"
                    else: "straight"
    let edge = newObj()
    edge["id"] = jstr(record.id)
    edge["type"] = jstr("edge")
    edge["sourceId"] = if record.cell.hasAttr("source") and importedIds.hasKey(sourceId): jstr(sourceId) else: jnull
    edge["targetId"] = if record.cell.hasAttr("target") and importedIds.hasKey(targetId): jstr(targetId) else: jnull
    edge["sourceSide"] = jstr("east")
    edge["targetSide"] = jstr("west")
    edge["route"] = jnull
    edge["stroke"] = jstr(if style.sv("strokeColor").len > 0: style["strokeColor"] else: "#4f5968")
    edge["strokeWidth"] = jnum(orDefault(styleNum(style, "strokeWidth"), 2))
    edge["lineStyle"] = jstr(lineStyle)
    edge["startArrow"] = jstr(if style.sv("startArrow").len > 0: style["startArrow"] else: "none")
    edge["endArrow"] = jstr(if style.sv("endArrow").len > 0: style["endArrow"] else: "classic")
    edge["dashed"] = jbool(style.sv("dashed") == "1")
    inc z
    edge["z"] = jnum(z)
    edge["visible"] = jtrue
    edge["previewPoints"] = newArr()
    if style.has("exitX") and style.has("exitY"):
      edge["sourceAnchor"] = obj2(jsNumber(style["exitX"]), jsNumber(style["exitY"]))
    if style.has("entryX") and style.has("entryY"):
      edge["targetAnchor"] = obj2(jsNumber(style["entryX"]), jsNumber(style["entryY"]))
    if record.geometry != nil:
      var sourcePoint, targetPoint: Val = nil
      let route = newArr()
      for p in record.geometry.getElementsByTagName("mxPoint"):
        let point = obj2(numberAttribute(p, "x", 0), numberAttribute(p, "y", 0))
        let role = p.attr("as")
        if p.hasAttr("as") and role == "sourcePoint": sourcePoint = point
        elif p.hasAttr("as") and role == "targetPoint": targetPoint = point
        else: route.push point
      if sourcePoint != nil: edge["sourcePoint"] = sourcePoint
      if targetPoint != nil: edge["targetPoint"] = targetPoint
      if route.len > 0: edge["route"] = route
      if not truthy(edge["sourceId"]) and not truthy(edge["targetId"]):
        let points = newArr()
        if sourcePoint != nil: points.push sourcePoint
        for p in route: points.push p
        if targetPoint != nil: points.push targetPoint
        edge["previewPoints"] = points
    if (truthy(edge["sourceId"]) or edge["sourcePoint"] != nil) and
        (truthy(edge["targetId"]) or edge["targetPoint"] != nil):
      items.add edge

  if items.len == 0:
    raise newException(LegacyError, "No drawable cells were found in this mxGraph document")

  result = newObj()
  result["format"] = jstr("pixel-graph-v2")
  let viewport = newObj()
  viewport["zoom"] = jnum(1)
  result["viewport"] = viewport
  let diagram = newObj()
  diagram["gridEnabled"] = jbool(model.attr("grid") != "0" or not model.hasAttr("grid"))
  diagram["gridSize"] = jnum(orDefault(jsNumberOrNull(model.hasAttr("gridSize"), model.attr("gridSize")), 10))
  diagram["pageView"] = jbool(model.attr("page") == "1")
  diagram["pageWidth"] = jnum(orDefault(jsNumberOrNull(model.hasAttr("pageWidth"), model.attr("pageWidth")), 850))
  diagram["pageHeight"] = jnum(orDefault(jsNumberOrNull(model.hasAttr("pageHeight"), model.attr("pageHeight")), 1100))
  diagram["pageScale"] = jnum(orDefault(jsNumberOrNull(model.hasAttr("pageScale"), model.attr("pageScale")), 1))
  result["diagram"] = diagram
  result["items"] = newArr(items)
