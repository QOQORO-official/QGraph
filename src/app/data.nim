## Built-in data: node templates, the classic palette inventory and the
## Visual Script card descriptions (kept so documents that contain such
## cards still import with their layout).

import ../jsval

const templatesJson = staticRead("data/templates.json")
const paletteJson = staticRead("data/palette.json")
const visualScriptJson = staticRead("data/visualscript.json")

var templatesVal, paletteVal, visualScriptVal: Val

proc nodeTemplates*(): Val =
  if templatesVal == nil: templatesVal = parseJson(templatesJson)
  templatesVal

proc nodeTemplate*(name: string): Val =
  ## A fresh copy of a named template (nil when unknown).
  let t = nodeTemplates().get(name)
  if t == nil: nil else: clone(t)

proc classicPalette*(): Val =
  if paletteVal == nil: paletteVal = parseJson(paletteJson)
  paletteVal

proc visualScriptDefinitions*(): Val =
  if visualScriptVal == nil: visualScriptVal = parseJson(visualScriptJson)
  visualScriptVal

proc visualScriptTemplate*(definition: Val): Val =
  ## Editor.js visualScriptTemplate(definition).
  result = newObj()
  result["kind"] = jstr("visualScript")
  result["vsType"] = definition["type"]
  result["shape"] = jstr("rect")
  result["width"] = definition["width"]
  result["height"] = definition["height"]
  result["text"] = definition["label"]
  result["fill"] = jstr("#ffffff")
  result["stroke"] = definition["stroke"]
  result["strokeWidth"] = jnum(2)
  result["radius"] = jnum(6)
  result["textColor"] = jstr("#222222")
  result["fontSize"] = jnum(12)
  result["fontFamily"] = jstr("Arial, Helvetica, sans-serif")
  result["textAlign"] = jstr("left")
  result["verticalAlign"] = jstr("top")
  result["textPadding"] = jnum(0)
  result["editable"] = jfalse
  result["visualRows"] = if definition.hasKey("rows"): definition["rows"] else: jnull
  result["visualSummary"] = if definition.hasKey("summary"): definition["summary"] else: jnull
  let vs = newObj()
  vs["label"] = definition["label"]
  vs["vsType"] = definition["type"]
  vs["lastResult"] = jstr("")
  vs["lastError"] = jstr("")
  if definition.eqs("type", "input"):
    vs["inputVars"] = jstr("""[{"name":"message","type":"string","value":"Hello from Input"},{"name":"value","type":"number","value":"5"}]""")
    vs["exports"] = jstr("message,value")
  result["visualScript"] = vs
