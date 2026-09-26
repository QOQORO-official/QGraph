## QGraph -- application entry points (the whole editor runs from here).
##
## The page loads web/js/qweb.js, which instantiates this module and calls
## qw_main(); each worker it spawns runs the same module and calls
## qw_worker_main(kind). Scripts and tests reach the editor through the
## automation surface: window.graph and window.editorUi are proxies whose
## every property read and call is answered by `automation` below.

import std/[strutils, tables]
import ../jsval, ../graph
import ../web/qweb
import view, editorui, worker, mxformat, data

{.pragma: wexport, exportc,
  codegenDecl: "__attribute__((export_name(\"$2\"))) $1 $2$3".}

proc NimMain() {.importc, cdecl.}

var started = false
var ui: EditorUi

proc boot() =
  if not started:
    started = true
    NimMain()

# ------------------------------------------------------------- automation --

const graphProperties = ["zoom", "gridSize", "gridEnabled", "gridColor", "backgroundColor", "pageView",
  "pageWidth", "pageHeight", "pageMargin", "pageColumns", "pageRows", "pageStartColumn",
  "pageStartRow", "infiniteWorldWidth", "infiniteWorldHeight", "worldOriginX",
  "worldOriginY", "connectionArrows", "connectionPoints", "allowLoops",
  "defaultEdgeLength", "guidesEnabled", "portMode", "pageScale", "tooltipsEnabled",
  "layers", "activeLayer", "readOnly", "defaultNodeStyle", "defaultEdgeStyle",
  "styleClipboard", "spacePressed", "enteredGroups", "hoverId", "action"]

const UndefinedMarker = "\x01undefined"

proc value(v: Val): ApiReply = ApiReply(kind: apiValue, json: if v == nil: "null" else: toJson(v))
proc fn(): ApiReply = ApiReply(kind: apiFunction)
proc obj(): ApiReply = ApiReply(kind: apiObject)
proc node(n: Node): ApiReply = ApiReply(kind: apiNode, node: n)
proc err(msg: string): ApiReply = ApiReply(kind: apiError, json: msg)

proc valStrOr(v: Val): string = (if v == nil or v.kind == vNull: "" else: str(v))
proc arg(a: Val, i: int): Val = (if a != nil and i < a.len: a[i] else: nil)
proc argNum(a: Val, i: int, d: float64): float64 =
  let x = arg(a, i)
  if x == nil or x.kind == vNull: d else: num(x)

proc graphApi(member: string, op: int, a: Val): ApiReply =
  let v = ui.editor.graph
  let g = v.g
  if op == 0:
    case member
    of "container": return node(v.container)
    of "items": return value(newArr(g.items))
    of "selection": return value(idsVal(v.selectionIds))
    of "stats": return value(v.stats)
    else:
      if member in graphProperties: return value(g.getProp(member))
      return fn()
  if op == 2:
    if member in graphProperties:
      g.setProp(member, arg(a, 0))
      return value(nil)
    return err("read-only: " & member)
  case member
  of "renderToCanvas": node(v.renderToCanvas(argNum(a, 0, 1), argNum(a, 1, 20)))
  of "saveLocal": (v.saveLocal(); value(nil))
  of "loadLocal": (v.loadLocal(); value(nil))
  of "exportPng": (v.exportPng(); value(nil))
  of "print": (v.print(); value(nil))
  of "render": (v.render(truthy(arg(a, 0))); value(nil))
  of "loadStencils": value(nil)
  of "applyStyle":
    v.applyStyle(arg(a, 0), if arg(a, 1) == nil: "" else: str(arg(a, 1)))
    value(nil)
  of "insertImage": value(v.insertMedia(str(arg(a, 0)), valStrOr(arg(a, 1)), arg(a, 2), "image"))
  of "insertMedia":
    value(v.insertMedia(str(arg(a, 0)), valStrOr(arg(a, 1)), arg(a, 2), valStrOr(arg(a, 3))))
  of "on", "emit": err("events are not scriptable")
  else:
    value(dispatch(g, member, if a == nil: newArr() else: a))

proc automation(path: string, op: int, argsJson: string): ApiReply =
  if ui == nil: return err("the editor is not ready")
  var args: Val = nil
  if op != 0:
    try:
      args = mapStrings(parseJson(argsJson), proc(s: string): Val =
        if s == UndefinedMarker: nil else: jstr(s))
    except JsonError as e: return err(e.msg)
  let parts = path.split('.')
  try:
    case parts[0]
    of "graph":
      if parts.len == 2: return graphApi(parts[1], op, args)
    of "editorUi":
      if parts.len == 2:
        case parts[1]
        of "editor", "actions": return obj()
        of "container": return node(ui.container)
        of "ready": return value(jbool(ui.ready))
        else: return fn()
      if parts.len == 3 and parts[1] == "actions":
        if op == 0: return fn()
        case parts[2]
        of "run":
          ui.run(str(arg(args, 0)))
          return value(nil)
        of "get":
          let action = ui.actions.getOrDefault(str(arg(args, 0)), nil)
          if action == nil: return value(jnull)
          let info = newObj()
          info["name"] = jstr(action.name)
          info["label"] = jstr(action.label)
          info["shortcut"] = jstr(action.shortcut)
          return value(info)
        else: discard
      if parts.len == 3 and parts[1] == "editor":
        if op == 0:
          if parts[2] == "filename": return value(jstr(ui.editor.filename))
          return fn()
        case parts[2]
        of "loadDemo": (ui.editor.loadDemo(); return value(nil))
        of "newDocument": (ui.editor.newDocument(); return value(nil))
        of "addAtCenter": return value(ui.editor.addAtCenter(str(arg(args, 0))))
        of "addTemplateAtCenter": return value(ui.editor.addTemplateAtCenter(arg(args, 0)))
        of "download": (ui.editor.download(); return value(nil))
        else: discard
    of "PixelMxGraphFormat":
      if parts.len == 2:
        if op == 0: return fn()
        case parts[1]
        of "parse": return value(mxformat.parse(str(arg(args, 0))))
        of "serialize": return value(jstr(mxformat.serialize(arg(args, 0))))
        else: discard
    of "PixelNodeTemplates":
      if parts.len == 2:
        let t = nodeTemplate(parts[1])
        return value(if t == nil: nil else: t)
    else: discard
  except CatchableError as e:
    return err(e.msg)
  err("unknown member: " & path)

# ----------------------------------------------------------------- exports --

proc qw_main() {.wexport.} =
  boot()
  apiHandler = automation
  ui = newEditorUi(body)
  for name in ["graph", "editorUi", "PixelMxGraphFormat", "PixelNodeTemplates"]: expose(name)
  flush()

proc qw_worker_main(kind: int32) {.wexport.} =
  boot()
  startWorkerKind(kind)
  flush()
