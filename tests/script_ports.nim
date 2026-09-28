## Regression: legacy input/output labels must render one shared script dot.
import ../src/[geometry, jsval]
import std/sets

{.emit: """
#include <stdlib.h>
#include <stdio.h>
void qg_intern(int id, char *p, int len) {}
double qg_parse_num(char *p, int len) { return p ? strtod(p, NULL) : 0; }
int qg_fmt_num(double x, char *dst, int cap) { return snprintf(dst, cap, "%g", x); }
""".}

proc check(kind, inputName, outputName, code: string) =
  let n = newObj()
  n["kind"] = jstr("visualScript")
  n["vsType"] = jstr(kind)
  n["x"] = jnum(0)
  n["y"] = jnum(0)
  n["width"] = jnum(250)
  n["height"] = jnum(150)
  n["portsEnabled"] = jtrue
  n["inputPorts"] = jstr(inputName)
  n["outputPorts"] = jstr(outputName)
  n["visualScript"] = newObj()
  n["visualScript"]["name"] = jstr("count")
  n["visualScript"]["value"] = jstr("(4)")
  n["visualScript"]["code"] = jstr(code)
  let ports = variablePorts(n)
  doAssert ports.len == 2, "keep both logical anchors"
  doAssert ports[0].point == ports[1].point, "both gestures use the same point"
  var dots: HashSet[string]
  for port in ports: dots.incl scriptPortKey(n, port.name)
  doAssert dots.len == 1, "paint only one circle"
  doAssert ports[0].direction == "input" and ports[1].direction == "output"

check("set", "value", "value", "")
check("start", "In", "next", "")
check("start", "In", "Out", "")
check("set", "In", "Out", "")
check("set", "value", "count", "")
check("output", "In", "Out", "")
check("luau", "in", "result", "-- comment\ncount = (count or 0) + 1")
check("qnoteOpen", "path", "next", "")
check("qnoteHeading", "text", "next", "")
check("qnoteType", "text", "next", "")
check("qnoteRun", "next", "result", "")
echo "PASS: shared script dots, including legacy socket names"

let wire = newObj()
wire["type"] = jstr("edge")
doAssert not isSocketWire(wire)
wire["sourceAnchor"] = newObj()
wire["sourceAnchor"]["portKind"] = jstr("output")
doAssert isSocketWire(wire)
wire["sourceAnchor"] = jnull
wire["targetAnchor"] = newObj()
wire["targetAnchor"]["portKind"] = jstr("input")
doAssert isSocketWire(wire)
echo "PASS: socket-wire protection recognizes either endpoint"
