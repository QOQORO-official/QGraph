## QGraph's icon set: 24px line icons drawn for this project, rendered as
## inline SVG so they follow `currentColor` and stay sharp at any density.

import std/tables
import ../web/qweb

const Solid = " fill=\"currentColor\" stroke=\"none\""

const iconData = {
  "logo": "<circle cx=\"6\" cy=\"6\" r=\"2.6\"/><circle cx=\"18\" cy=\"12\" r=\"2.6\"/>" &
    "<circle cx=\"6\" cy=\"18\" r=\"2.6\"/><path d=\"M8.4 7.3l7.2 3.4M8.4 16.7l7.2-3.4\"/>",
  "menu": "<path d=\"M4 6.5h16M4 12h16M4 17.5h16\"/>",
  "more": "<circle cx=\"5.5\" cy=\"12\" r=\"1.4\"" & Solid & "/><circle cx=\"12\" cy=\"12\" r=\"1.4\"" & Solid &
    "/><circle cx=\"18.5\" cy=\"12\" r=\"1.4\"" & Solid & "/>",
  "undo": "<path d=\"M9 14L4 9l5-5\"/><path d=\"M4 9h11a5 5 0 0 1 0 10h-4\"/>",
  "redo": "<path d=\"M15 14l5-5-5-5\"/><path d=\"M20 9H9a5 5 0 0 0 0 10h4\"/>",
  "zoomIn": "<circle cx=\"10.5\" cy=\"10.5\" r=\"6.5\"/><path d=\"M15.5 15.5l5 5M10.5 8v5M8 10.5h5\"/>",
  "zoomOut": "<circle cx=\"10.5\" cy=\"10.5\" r=\"6.5\"/><path d=\"M15.5 15.5l5 5M8 10.5h5\"/>",
  "fit": "<path d=\"M4 9V5a1 1 0 0 1 1-1h4M15 4h4a1 1 0 0 1 1 1v4M20 15v4a1 1 0 0 1-1 1h-4M9 20H5a1 1 0 0 1-1-1v-4\"/>" &
    "<rect x=\"8.5\" y=\"8.5\" width=\"7\" height=\"7\" rx=\"1.5\"/>",
  "shapes": "<rect x=\"3.5\" y=\"3.5\" width=\"7.5\" height=\"7.5\" rx=\"1.6\"/><circle cx=\"17\" cy=\"7.25\" r=\"3.75\"/>" &
    "<path d=\"M7.25 13.5l4 7h-8z\"/><path d=\"M17 13l3.5 3.75L17 20.5l-3.5-3.75z\"/>",
  "text": "<path d=\"M5 6.5V5h14v1.5M12 5v14M9.5 19h5\"/>",
  "table": "<rect x=\"3.5\" y=\"4.5\" width=\"17\" height=\"15\" rx=\"2\"/><path d=\"M3.5 9.5h17M3.5 14.5h17M10 9.5v10\"/>",
  "image": "<rect x=\"3.5\" y=\"4.5\" width=\"17\" height=\"15\" rx=\"2\"/><circle cx=\"8.5\" cy=\"9.5\" r=\"1.6\"/>" &
    "<path d=\"M20.5 15l-4.5-4.5-8.5 9\"/>",
  "code": "<path d=\"M8 8l-4 4 4 4M16 8l4 4-4 4M13.5 5.5l-3 13\"/>",
  "layers": "<path d=\"M12 3.5l8.5 4.5-8.5 4.5L3.5 8z\"/><path d=\"M3.5 12l8.5 4.5 8.5-4.5\"/><path d=\"M3.5 16l8.5 4.5 8.5-4.5\"/>",
  "map": "<rect x=\"3.5\" y=\"4.5\" width=\"17\" height=\"15\" rx=\"2\"/><rect x=\"6.5\" y=\"8\" width=\"7\" height=\"6\" rx=\"1\"/>",
  "search": "<circle cx=\"10.5\" cy=\"10.5\" r=\"6\"/><path d=\"M15 15l5 5\"/>",
  "star": "<path d=\"M12 3.8l2.5 5.2 5.7.7-4.2 3.9 1.1 5.6L12 16.4l-5.1 2.8L8 13.6 3.8 9.7l5.7-.7z\"/>",
  "plus": "<path d=\"M12 5v14M5 12h14\"/>",
  "minus": "<path d=\"M5 12h14\"/>",
  "close": "<path d=\"M6.5 6.5l11 11M17.5 6.5l-11 11\"/>",
  "chevronDown": "<path d=\"M6 9.5l6 6 6-6\"/>",
  "chevronLeft": "<path d=\"M14.5 6l-6 6 6 6\"/>",
  "chevronRight": "<path d=\"M9.5 6l6 6-6 6\"/>",
  "sun": "<circle cx=\"12\" cy=\"12\" r=\"4\"/><path d=\"M12 2.5v2M12 19.5v2M4.6 4.6L6 6M18 18l1.4 1.4M2.5 12h2M19.5 12h2M4.6 19.4L6 18M18 6l1.4-1.4\"/>",
  "moon": "<path d=\"M19.5 14.5A8 8 0 1 1 9.5 4.5a6.5 6.5 0 0 0 10 10z\"/>",
  "download": "<path d=\"M12 4v11M7.5 10.5L12 15l4.5-4.5M5 19.5h14\"/>",
  "folder": "<path d=\"M3.5 7a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v8.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z\"/>",
  "save": "<path d=\"M5.5 4.5h10.5l3.5 3.5v10.5a1 1 0 0 1-1 1h-13a1 1 0 0 1-1-1v-13a1 1 0 0 1 1-1z\"/>" &
    "<path d=\"M8 4.5v4h7v-4\"/><rect x=\"7.5\" y=\"13\" width=\"9\" height=\"6.5\" rx=\"1\"/>",
  "fill": "<path d=\"M5 11l6.5-6.5 7 7L12.3 17.7a2 2 0 0 1-2.8 0L5 13.2a1.6 1.6 0 0 1 0-2.2z\"/><path d=\"M5 12h13\"/>" &
    "<path d=\"M20.5 16.2c0 1.1-.7 1.8-1.4 1.8s-1.4-.7-1.4-1.8 1.4-2.9 1.4-2.9 1.4 1.8 1.4 2.9z\"" & Solid & "/>",
  "pen": "<path d=\"M4 20l1-4.5L15.5 5a2.1 2.1 0 0 1 3 3L8 18.5z\"/><path d=\"M13.5 7l3 3\"/>",
  "fontColor": "<path d=\"M7 16l5-12 5 12M8.7 12h6.6\"/>",
  "bold": "<path d=\"M7 5h5.5a3.5 3.5 0 0 1 0 7H7zM7 12h6.5a3.5 3.5 0 0 1 0 7H7z\" stroke-width=\"2.3\"/>",
  "italic": "<path d=\"M10 5h8M6 19h8M14 5l-4 14\"/>",
  "underline": "<path d=\"M7 4.5v6a5 5 0 0 0 10 0v-6M5.5 20h13\"/>",
  "strike": "<path d=\"M5 12h14M16.5 7.5C15.7 5.8 14 5 12 5 9.5 5 7.5 6.3 7.5 8.3c0 1.2.6 2 1.8 2.6M7.5 16.2c.8 1.9 2.5 2.8 4.5 2.8 2.7 0 4.5-1.3 4.5-3.3 0-.6-.2-1.2-.5-1.7\"/>",
  "textLeft": "<path d=\"M4 6h16M4 10.5h10M4 15h16M4 19.5h10\"/>",
  "textCenter": "<path d=\"M4 6h16M7 10.5h10M4 15h16M7 19.5h10\"/>",
  "textRight": "<path d=\"M4 6h16M10 10.5h10M4 15h16M10 19.5h10\"/>",
  "listBullet": "<path d=\"M9.5 7h10.5M9.5 12h10.5M9.5 17h10.5\"/><circle cx=\"5\" cy=\"7\" r=\"1.2\"" & Solid &
    "/><circle cx=\"5\" cy=\"12\" r=\"1.2\"" & Solid & "/><circle cx=\"5\" cy=\"17\" r=\"1.2\"" & Solid & "/>",
  "listNumber": "<path d=\"M10 7h10M10 12h10M10 17h10M4 5l1.5-1v4.5M3.8 11.2a1.3 1.3 0 1 1 2.2 1l-2.2 2.3h2.6\"/>",
  "indent": "<path d=\"M4 5.5h16M11 10h9M11 14h9M4 18.5h16M4 9l3 3-3 3\"/>",
  "outdent": "<path d=\"M4 5.5h16M11 10h9M11 14h9M4 18.5h16M7 9l-3 3 3 3\"/>",
  "eraser": "<path d=\"M8.5 19.5L4 15a1.5 1.5 0 0 1 0-2.1l8.9-8.9a1.5 1.5 0 0 1 2.1 0l4.9 4.9a1.5 1.5 0 0 1 0 2.1l-7.9 8.5zM9 10l6 6M13 19.5h7\"/>",
  "superscript": "<path d=\"M4 8l7 10M11 8l-7 10M15 5.3a1.4 1.4 0 1 1 2.4 1L15 8.8h3\"/>",
  "subscript": "<path d=\"M4 6l7 10M11 6l-7 10M15 16.3a1.4 1.4 0 1 1 2.4 1L15 19.8h3\"/>",
  "alignLeft": "<path d=\"M4 3.5v17\"/><rect x=\"7\" y=\"6\" width=\"9\" height=\"4\" rx=\"1\"/><rect x=\"7\" y=\"14\" width=\"13\" height=\"4\" rx=\"1\"/>",
  "alignCenter": "<path d=\"M12 3.5v17\"/><rect x=\"7.5\" y=\"6\" width=\"9\" height=\"4\" rx=\"1\"/><rect x=\"5.5\" y=\"14\" width=\"13\" height=\"4\" rx=\"1\"/>",
  "alignRight": "<path d=\"M20 3.5v17\"/><rect x=\"8\" y=\"6\" width=\"9\" height=\"4\" rx=\"1\"/><rect x=\"4\" y=\"14\" width=\"13\" height=\"4\" rx=\"1\"/>",
  "alignTop": "<path d=\"M3.5 4h17\"/><rect x=\"6\" y=\"7\" width=\"4\" height=\"9\" rx=\"1\"/><rect x=\"14\" y=\"7\" width=\"4\" height=\"13\" rx=\"1\"/>",
  "alignMiddle": "<path d=\"M3.5 12h17\"/><rect x=\"6\" y=\"7.5\" width=\"4\" height=\"9\" rx=\"1\"/><rect x=\"14\" y=\"5.5\" width=\"4\" height=\"13\" rx=\"1\"/>",
  "alignBottom": "<path d=\"M3.5 20h17\"/><rect x=\"6\" y=\"8\" width=\"4\" height=\"9\" rx=\"1\"/><rect x=\"14\" y=\"4\" width=\"4\" height=\"13\" rx=\"1\"/>",
  "distributeH": "<path d=\"M4 4v16M20 4v16\"/><rect x=\"9.5\" y=\"7\" width=\"5\" height=\"10\" rx=\"1\"/>",
  "distributeV": "<path d=\"M4 4h16M4 20h16\"/><rect x=\"7\" y=\"9.5\" width=\"10\" height=\"5\" rx=\"1\"/>",
  "toFront": "<rect x=\"4.5\" y=\"4.5\" width=\"10\" height=\"10\" rx=\"1.5\" stroke-dasharray=\"2 2\"/>" &
    "<rect x=\"9.5\" y=\"9.5\" width=\"10\" height=\"10\" rx=\"1.5\" fill=\"currentColor\" fill-opacity=\".22\"/>",
  "toBack": "<rect x=\"9.5\" y=\"9.5\" width=\"10\" height=\"10\" rx=\"1.5\" stroke-dasharray=\"2 2\"/>" &
    "<rect x=\"4.5\" y=\"4.5\" width=\"10\" height=\"10\" rx=\"1.5\" fill=\"currentColor\" fill-opacity=\".22\"/>",
  "duplicate": "<rect x=\"8.5\" y=\"8.5\" width=\"11.5\" height=\"11.5\" rx=\"2\"/><path d=\"M15.5 5.5v-.5a1.5 1.5 0 0 0-1.5-1.5H5a1.5 1.5 0 0 0-1.5 1.5v9A1.5 1.5 0 0 0 5 15.5h.5\"/>",
  "trash": "<path d=\"M4.5 7h15M9.5 7V5a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1v2M6.5 7l1 12a1.5 1.5 0 0 0 1.5 1.4h6a1.5 1.5 0 0 0 1.5-1.4l1-12M10 11v6M14 11v6\"/>",
  "group": "<rect x=\"3.5\" y=\"3.5\" width=\"17\" height=\"17\" rx=\"2.5\" stroke-dasharray=\"2.5 2.5\"/>" &
    "<rect x=\"7\" y=\"7\" width=\"5.5\" height=\"5.5\" rx=\"1\"/><rect x=\"11.5\" y=\"11.5\" width=\"5.5\" height=\"5.5\" rx=\"1\"/>",
  "ungroup": "<rect x=\"4\" y=\"4\" width=\"7\" height=\"7\" rx=\"1.5\"/><rect x=\"13\" y=\"13\" width=\"7\" height=\"7\" rx=\"1.5\"/>" &
    "<path d=\"M14.5 4.5h3a2 2 0 0 1 2 2v3M9.5 19.5h-3a2 2 0 0 1-2-2v-3\" stroke-dasharray=\"2 2\"/>",
  "lock": "<rect x=\"5\" y=\"10.5\" width=\"14\" height=\"9.5\" rx=\"2\"/><path d=\"M8 10.5V8a4 4 0 0 1 8 0v2.5\"/>",
  "unlock": "<rect x=\"5\" y=\"10.5\" width=\"14\" height=\"9.5\" rx=\"2\"/><path d=\"M8 10.5V8a4 4 0 0 1 7.6-1.7\"/>",
  "rotate": "<path d=\"M20 12a8 8 0 1 1-2.3-5.7M20 4.5v4h-4\"/>",
  "flipH": "<path d=\"M12 3.5v17\" stroke-dasharray=\"2 2\"/><path d=\"M9 7L4 17h5zM15 7l5 10h-5z\"/>",
  "flipV": "<path d=\"M3.5 12h17\" stroke-dasharray=\"2 2\"/><path d=\"M7 9l10-5v5zM7 15l10 5v-5z\"/>",
  "connector": "<path d=\"M5.5 18.5V11a3 3 0 0 1 3-3H19M16 5l3 3-3 3\"/><circle cx=\"5.5\" cy=\"19\" r=\"1.5\"/>",
  "waypoint": "<path d=\"M4 19l7-9 9 5\"/><circle cx=\"11\" cy=\"10\" r=\"2.2\"" & Solid & "/>",
  "reverse": "<path d=\"M4 8h13M14 5l3 3-3 3M20 16H7M10 13l-3 3 3 3\"/>",
  "shadow": "<rect x=\"4\" y=\"4\" width=\"12\" height=\"12\" rx=\"2\"/><path d=\"M8 20h10a2 2 0 0 0 2-2V8\" stroke-width=\"3\" stroke-opacity=\".45\"/>",
  "link": "<path d=\"M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1\"/>",
  "grid": "<rect x=\"3.5\" y=\"3.5\" width=\"17\" height=\"17\" rx=\"2\"/><path d=\"M3.5 9.2h17M3.5 14.8h17M9.2 3.5v17M14.8 3.5v17\"/>",
  "page": "<path d=\"M6.5 3.5h8l4 4v12.5a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1V4.5a1 1 0 0 1 1-1zM14.5 3.5v4h4\"/>",
  "panelLeft": "<rect x=\"3.5\" y=\"4.5\" width=\"17\" height=\"15\" rx=\"2\"/><path d=\"M9 4.5v15\"/>",
  "panelRight": "<rect x=\"3.5\" y=\"4.5\" width=\"17\" height=\"15\" rx=\"2\"/><path d=\"M15 4.5v15\"/>",
  "sliders": "<path d=\"M4 7h9M17 7h3M4 17h3M11 17h9\"/><circle cx=\"15\" cy=\"7\" r=\"2\"/><circle cx=\"9\" cy=\"17\" r=\"2\"/>",
  "help": "<circle cx=\"12\" cy=\"12\" r=\"8.5\"/><path d=\"M9.6 9.6a2.5 2.5 0 0 1 4.8.8c0 1.7-2.4 2.2-2.4 3.7\"/>" &
    "<circle cx=\"12\" cy=\"17\" r=\".9\"" & Solid & "/>",
  "pointer": "<path d=\"M5.5 4.5l12.5 6-5.4 1.9-2.6 5.6z\"/>",
  "print": "<path d=\"M7 9V4h10v5M7 17H5a1.5 1.5 0 0 1-1.5-1.5v-5A1.5 1.5 0 0 1 5 9h14a1.5 1.5 0 0 1 1.5 1.5v5A1.5 1.5 0 0 1 19 17h-2M7 14h10v6H7z\"/>",
  "note": "<path d=\"M5 4.5h14a.5.5 0 0 1 .5.5v9.5l-5 5H5a.5.5 0 0 1-.5-.5V5a.5.5 0 0 1 .5-.5zM19.5 14.5h-5v5\"/>",
  "palette": "<path d=\"M12 3.5a8.5 8.5 0 1 0 0 17c1 0 1.5-.7 1.5-1.4 0-1.1-.9-1.5-.9-2.5 0-.9.7-1.6 1.6-1.6h2.3a4 4 0 0 0 4-4c0-4.2-3.8-7.5-8.5-7.5z\"/>" &
    "<circle cx=\"7.6\" cy=\"11.5\" r=\"1.1\"" & Solid & "/><circle cx=\"9.6\" cy=\"7.6\" r=\"1.1\"" & Solid &
    "/><circle cx=\"14.2\" cy=\"7.2\" r=\"1.1\"" & Solid & "/>",
  "arrange": "<rect x=\"4\" y=\"11.5\" width=\"10\" height=\"8.5\" rx=\"1.5\"/><path d=\"M8 11.5V6a1.5 1.5 0 0 1 1.5-1.5h9A1.5 1.5 0 0 1 20 6v7a1.5 1.5 0 0 1-1.5 1.5H14\"/>",
  "check": "<path d=\"M5 12.5l4.5 4.5L19 7.5\"/>",
  "copy": "<rect x=\"8.5\" y=\"8.5\" width=\"11.5\" height=\"11.5\" rx=\"2\"/><path d=\"M15.5 8.5V5A1.5 1.5 0 0 0 14 3.5H5A1.5 1.5 0 0 0 3.5 5v9A1.5 1.5 0 0 0 5 15.5h3.5\"/>",
  "cut": "<circle cx=\"6.5\" cy=\"17.5\" r=\"2.5\"/><circle cx=\"17.5\" cy=\"17.5\" r=\"2.5\"/><path d=\"M8.3 15.7L18 4M15.7 15.7L6 4\"/>",
  "paste": "<rect x=\"5\" y=\"5\" width=\"14\" height=\"15.5\" rx=\"2\"/><rect x=\"9\" y=\"3.5\" width=\"6\" height=\"3.5\" rx=\"1\"/>",
  "select": "<rect x=\"4\" y=\"4\" width=\"16\" height=\"16\" rx=\"2\" stroke-dasharray=\"3 2.5\"/><path d=\"M10 10l7 3-3 1-1 3z\"/>",
  "export": "<path d=\"M12 15V4M7.5 8.5L12 4l4.5 4.5M5 13.5v5a1.5 1.5 0 0 0 1.5 1.5h11a1.5 1.5 0 0 0 1.5-1.5v-5\"/>",
  "curve": "<path d=\"M4 19c4 0 4-14 8-14s4 14 8 14\"/>",
  "straight": "<path d=\"M4.5 19.5l15-15\"/><circle cx=\"4.5\" cy=\"19.5\" r=\"1.4\"" & Solid & "/><circle cx=\"19.5\" cy=\"4.5\" r=\"1.4\"" & Solid & "/>",
  "orthogonal": "<path d=\"M4.5 19.5v-7.5h15V4.5\"/>",
  "arc": "<path d=\"M4.5 18a8 8 0 0 1 15 0\"/>",
  "edit": "<path d=\"M4 20h4.5L19 9.5a2.1 2.1 0 0 0-3-3L5.5 17z\"/><path d=\"M13.5 8.5l3 3\"/>",
}.toTable

proc iconMarkup*(name: string, size = 20): string =
  let body = iconData.getOrDefault(name, iconData["shapes"])
  "<svg class=\"qg-icon\" width=\"" & $size & "\" height=\"" & $size &
    "\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" " &
    "stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\">" & body & "</svg>"

proc icon*(name: string, size = 20): Node =
  ## A <span> holding the icon, ready to append to a button.
  result = el("span", "qg-icon-wrap")
  result.html = iconMarkup(name, size)
