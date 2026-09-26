# Included from editorui.nim: the document facade (Editor.js).

proc newEditor(container: Node): Editor =
  let v = newView(container)
  Editor(graph: v, overlay: newMediaOverlay(v), filename: "pixel-diagram.json")

proc newDocument*(ed: Editor) =
  discard ed.graph.call("loadItems", newArr(), jtrue)

proc demoItems(): Val =
  const shapes = """[
    {"id":"title","type":"node","kind":"shape","shape":"rect","x":72,"y":52,"width":340,"height":52,"rotation":0,"fill":"transparent","stroke":"transparent","strokeWidth":0,"text":"Life OS Dashboard","textColor":"#111111","fontSize":26,"fontWeight":700,"textAlign":"left","z":1,"visible":true},
    {"id":"add","type":"node","kind":"shape","shape":"rect","x":82,"y":118,"width":88,"height":40,"rotation":0,"fill":"#780000","stroke":"#310000","strokeWidth":2,"text":"Add","textColor":"#ffffff","fontSize":13,"fontWeight":700,"radius":5,"z":4,"visible":true},
    {"id":"add-fixed","type":"node","kind":"shape","shape":"rect","x":180,"y":118,"width":104,"height":40,"rotation":0,"fill":"#780000","stroke":"#310000","strokeWidth":2,"text":"Add Fixed","textColor":"#ffffff","fontSize":13,"fontWeight":700,"radius":5,"z":4,"visible":true},
    null,
    {"id":"panel-a","type":"node","kind":"shape","shape":"rect","x":355,"y":118,"width":285,"height":255,"rotation":0,"fill":"rgba(255,255,255,0.55)","stroke":"#3e454e","strokeWidth":1,"text":"","radius":0,"z":1,"visible":true},
    {"id":"panel-b","type":"node","kind":"shape","shape":"rect","x":640,"y":118,"width":470,"height":430,"rotation":0,"fill":"rgba(255,255,255,0.55)","stroke":"#3e454e","strokeWidth":1,"text":"","radius":0,"z":1,"visible":true},
    {"id":"test","type":"node","kind":"shape","shape":"rect","x":365,"y":120,"width":145,"height":66,"rotation":0,"fill":"#780000","stroke":"#250000","strokeWidth":3,"text":"Test","textColor":"#ffffff","fontSize":13,"fontWeight":700,"radius":11,"z":5,"visible":true,"shadow":true},
    {"id":"docs","type":"node","kind":"shape","shape":"rect","x":545,"y":120,"width":145,"height":66,"rotation":0,"fill":"#780000","stroke":"#250000","strokeWidth":3,"text":"Important Docs for Tokyo Tech COE","textColor":"#ffffff","fontSize":12,"fontWeight":700,"radius":11,"z":5,"visible":true,"shadow":true},
    {"id":"admission","type":"node","kind":"shape","shape":"rect","x":715,"y":120,"width":158,"height":66,"rotation":0,"fill":"#780000","stroke":"#250000","strokeWidth":3,"text":"Important Document for Admission Result","textColor":"#ffffff","fontSize":12,"fontWeight":700,"radius":11,"z":5,"visible":true,"shadow":true}
  ]"""
  result = parseJson(shapes)
  # Object.assign({id, type, x, y, rotation, z, visible}, taskList template)
  let tasks = newObj()
  tasks["id"] = jstr("tasks")
  tasks["type"] = jstr("node")
  tasks["x"] = jnum(82)
  tasks["y"] = jnum(164)
  tasks["rotation"] = jnum(0)
  tasks["z"] = jnum(3)
  tasks["visible"] = jtrue
  for (k, x) in nodeTemplate("taskList").pairs: tasks.put(k, x)
  result[3] = tasks

proc loadDemo*(ed: Editor) =
  discard ed.graph.call("loadItems", demoItems(), jtrue)
  discard ed.graph.call("setSelection", idsVal(["tasks"]))

proc addTemplateAtCenter*(ed: Editor, templ: Val): Val =
  ## Drops a literal shape definition (scratchpad entry) in the viewport.
  let g = ed.graph
  let view = g.g.getViewState()
  let width = if truthy(templ["width"]): num(templ["width"]) else: 160.0
  let height = if truthy(templ["height"]): num(templ["height"]) else: 80.0
  let before = g.snapshot()
  let position = newObj()
  position["x"] = jnum((num(view["scrollX"]) + num(view["width"]) / 2) / g.zoom - width / 2)
  position["y"] = jnum((num(view["scrollY"]) + num(view["height"]) / 2) / g.zoom - height / 2)
  result = g.call("addTemplate", templ, position)
  g.commit(before, "Add Shape")

proc addAtCenter*(ed: Editor, templateName: string): Val =
  var t = nodeTemplate(templateName)
  if t == nil: t = nodeTemplate("process")
  ed.addTemplateAtCenter(t)

proc downloadText*(ed: Editor, text, filename, mime: string) =
  let blob = newBlob(text, if mime.len > 0: mime else: "text/plain")
  downloadBlob(blob, if filename.len > 0: filename else: ed.filename)
  release(blob)

proc download*(ed: Editor) =
  var name = ed.filename
  if name.toLowerAscii().endsWith(".qochart"): name = name[0 ..< name.len - 8] & ".json"
  ed.downloadText(ed.graph.toJSON(), name, "application/json")

proc looksLikeMarkup(text: string): bool =
  for c in text:
    if c in {' ', '\t', '\n', '\r', '\f', '\v'}: continue
    return c == '<'
  false

proc openFile*(ed: Editor, file: Node) =
  let name = file.getStr("name")
  readBlob(file, brText, proc(ok: bool, text: string) =
    if not ok:
      ed.graph.emit("toast", jstr("Could not read " & (if name.len > 0: name else: "the selected file")))
      return
    try:
      # The format module adds round-trip metadata on top of the importer,
      # so a local .qochart can be saved back cleanly.
      let markup = looksLikeMarkup(text)
      let doc = if markup: mxformat.parse(text) else: parseJson(text)
      ed.graph.fromJSON(doc)
      if name.len > 0: ed.filename = name
      ed.graph.emit("toast", jstr(if markup:
        "Imported legacy qochart (" & $doc["items"].len & " objects)" else: "Diagram loaded"))
    except CatchableError as error:
      log("Could not load diagram: " & error.msg)
      ed.graph.emit("toast", jstr("Could not load diagram: " & error.msg)))
