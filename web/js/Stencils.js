/*
 * mxGraph stencil libraries for the canvas engine.
 *
 * The classic editor renders stencils by translating the shape XML into SVG
 * nodes. Here the XML is parsed once on the main thread into a flat, plain
 * JSON draw program, which is then executed straight onto a 2D context. The
 * program is serialisable, so the same stencils are posted to the render
 * worker and drawn there too.
 *
 * Program ops mirror the stencil grammar: geometry ops (move/line/quad/curve/
 * arc/close/rect/roundrect/ellipse), paint ops (fill/stroke/fillstroke) and
 * state ops (strokewidth/fillcolor/strokecolor/dashed/linejoin/alpha/...).
 */
(function(root) {
    'use strict';

    var registry = Object.create(null);
    var libraries = Object.create(null);

    /* The engine paints stencils from the same programs; keep it in step. */
    function forward(shapes) {
        var engine = root.QGraphWasm && root.QGraphWasm.engine;
        if (engine && shapes && shapes.length) engine.callJson('qg_register_stencils', [], shapes);
    }

    function number(element, name, fallback) {
        var raw = element.getAttribute(name);
        if (raw == null || raw === '') return fallback;
        var value = parseFloat(raw);
        return isNaN(value) ? fallback : value;
    }

    /* ------------------------------------------------------------------ */
    /* Parsing                                                             */
    /* ------------------------------------------------------------------ */

    /* Registry keys are lower case with underscores for spaces, matching the
       shape= name mxGraph writes into a style string. */
    function normalizeKey(value) {
        return String(value == null ? '' : value).toLowerCase().replace(/\s+/g, '_');
    }

    function stencilKey(libraryName, name) {
        return normalizeKey(libraryName + '.' + name);
    }

    function parseSection(section) {
        var ops = [];
        if (section == null) return ops;

        for (var i = 0; i < section.childNodes.length; i++) {
            var node = section.childNodes[i];
            if (node.nodeType !== 1) continue;
            var tag = node.nodeName.toLowerCase();

            if (tag === 'path') {
                ops.push({ op: 'begin' });
                for (var p = 0; p < node.childNodes.length; p++) {
                    var step = node.childNodes[p];
                    if (step.nodeType !== 1) continue;
                    var name = step.nodeName.toLowerCase();

                    if (name === 'move') ops.push({ op: 'move', x: number(step, 'x', 0), y: number(step, 'y', 0) });
                    else if (name === 'line') ops.push({ op: 'line', x: number(step, 'x', 0), y: number(step, 'y', 0) });
                    else if (name === 'quad') {
                        ops.push({
                            op: 'quad', x1: number(step, 'x1', 0), y1: number(step, 'y1', 0),
                            x: number(step, 'x2', 0), y: number(step, 'y2', 0)
                        });
                    } else if (name === 'curve') {
                        ops.push({
                            op: 'curve',
                            x1: number(step, 'x1', 0), y1: number(step, 'y1', 0),
                            x2: number(step, 'x2', 0), y2: number(step, 'y2', 0),
                            x: number(step, 'x3', 0), y: number(step, 'y3', 0)
                        });
                    } else if (name === 'arc') {
                        ops.push({
                            op: 'arc',
                            rx: number(step, 'rx', 0), ry: number(step, 'ry', 0),
                            rotation: number(step, 'x-axis-rotation', 0),
                            large: number(step, 'large-arc-flag', 0),
                            sweep: number(step, 'sweep-flag', 0),
                            x: number(step, 'x', 0), y: number(step, 'y', 0)
                        });
                    } else if (name === 'close') ops.push({ op: 'close' });
                }
                continue;
            }

            if (tag === 'rect') {
                ops.push({
                    op: 'rect', x: number(node, 'x', 0), y: number(node, 'y', 0),
                    w: number(node, 'w', 0), h: number(node, 'h', 0)
                });
            } else if (tag === 'roundrect') {
                ops.push({
                    op: 'roundrect', x: number(node, 'x', 0), y: number(node, 'y', 0),
                    w: number(node, 'w', 0), h: number(node, 'h', 0),
                    arcsize: number(node, 'arcsize', 10)
                });
            } else if (tag === 'ellipse') {
                ops.push({
                    op: 'ellipse', x: number(node, 'x', 0), y: number(node, 'y', 0),
                    w: number(node, 'w', 0), h: number(node, 'h', 0)
                });
            } else if (tag === 'fill' || tag === 'stroke' || tag === 'fillstroke') {
                ops.push({ op: tag });
            } else if (tag === 'strokewidth') {
                ops.push({ op: 'strokewidth', width: node.getAttribute('width') });
            } else if (tag === 'fillcolor') {
                ops.push({ op: 'fillcolor', color: node.getAttribute('color') });
            } else if (tag === 'strokecolor') {
                ops.push({ op: 'strokecolor', color: node.getAttribute('color') });
            } else if (tag === 'fontcolor') {
                ops.push({ op: 'fontcolor', color: node.getAttribute('color') });
            } else if (tag === 'fontsize') {
                ops.push({ op: 'fontsize', size: number(node, 'size', 12) });
            } else if (tag === 'alpha') {
                ops.push({ op: 'alpha', alpha: number(node, 'alpha', 1) });
            } else if (tag === 'dashed') {
                ops.push({ op: 'dashed', on: node.getAttribute('dashed') === '1' });
            } else if (tag === 'dashpattern') {
                ops.push({ op: 'dashpattern', pattern: String(node.getAttribute('pattern') || '')
                    .split(/\s+/).map(parseFloat).filter(function(v) { return !isNaN(v); }) });
            } else if (tag === 'linejoin') {
                ops.push({ op: 'linejoin', join: node.getAttribute('join') });
            } else if (tag === 'linecap') {
                ops.push({ op: 'linecap', cap: node.getAttribute('cap') });
            } else if (tag === 'miterlimit') {
                ops.push({ op: 'miterlimit', limit: number(node, 'limit', 10) });
            } else if (tag === 'save' || tag === 'restore') {
                ops.push({ op: tag });
            } else if (tag === 'text') {
                ops.push({
                    op: 'text', str: node.getAttribute('str') || '',
                    x: number(node, 'x', 0), y: number(node, 'y', 0),
                    align: node.getAttribute('align') || 'left',
                    valign: node.getAttribute('valign') || 'top'
                });
            }
        }

        return ops;
    }

    function parseShape(element, libraryName) {
        var name = element.getAttribute('name');
        if (!name) return null;

        return {
            name: name,
            library: libraryName,
            // mxGraph style strings name a stencil with underscores for the
            // spaces in its XML name (shape=mxgraph.flowchart.annotation_2 for
            // "Annotation 2"), so the registry key has to use that spelling or
            // every multi-word stencil in a document resolves to nothing.
            key: stencilKey(libraryName, name),
            w: number(element, 'w', 100),
            h: number(element, 'h', 100),
            aspect: element.getAttribute('aspect') || 'variable',
            strokeWidth: element.getAttribute('strokewidth') || '1',
            background: parseSection(element.getElementsByTagName('background')[0]),
            foreground: parseSection(element.getElementsByTagName('foreground')[0])
        };
    }

    /* Parses a stencil XML document and registers every shape it contains. */
    function parse(xml, fallbackName) {
        if (typeof DOMParser === 'undefined') return [];
        var doc = new DOMParser().parseFromString(xml, 'text/xml');
        if (doc.getElementsByTagName('parsererror').length > 0) return [];

        var rootElement = doc.documentElement;
        var libraryName = (rootElement.getAttribute('name') || fallbackName || 'stencil');
        var shapes = rootElement.getElementsByTagName('shape');
        var added = [];

        for (var i = 0; i < shapes.length; i++) {
            var shape = parseShape(shapes[i], libraryName);
            if (shape == null) continue;
            registry[shape.key] = shape;
            added.push(shape);
        }

        libraries[libraryName] = (libraries[libraryName] || []).concat(added);
        forward(added);
        return added;
    }

    /* ------------------------------------------------------------------ */
    /* Rendering                                                           */
    /* ------------------------------------------------------------------ */

    /* SVG elliptical arc, endpoint form, converted to a canvas ellipse. */
    function svgArc(ctx, from, op) {
        var rx = Math.abs(op.rx);
        var ry = Math.abs(op.ry);

        if (rx === 0 || ry === 0) {
            ctx.lineTo(op.x, op.y);
            return;
        }

        var phi = (op.rotation || 0) * Math.PI / 180;
        var cosPhi = Math.cos(phi);
        var sinPhi = Math.sin(phi);
        var dx = (from.x - op.x) / 2;
        var dy = (from.y - op.y) / 2;
        var x1 = cosPhi * dx + sinPhi * dy;
        var y1 = -sinPhi * dx + cosPhi * dy;

        var lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lambda > 1) {
            var scale = Math.sqrt(lambda);
            rx *= scale;
            ry *= scale;
        }

        var sign = (op.large !== op.sweep) ? 1 : -1;
        var numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        var denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        var factor = denominator === 0 ? 0 : sign * Math.sqrt(Math.max(0, numerator / denominator));
        var cx1 = factor * rx * y1 / ry;
        var cy1 = -factor * ry * x1 / rx;
        var cx = cosPhi * cx1 - sinPhi * cy1 + (from.x + op.x) / 2;
        var cy = sinPhi * cx1 + cosPhi * cy1 + (from.y + op.y) / 2;

        var startAngle = Math.atan2((y1 - cy1) / ry, (x1 - cx1) / rx);
        var endAngle = Math.atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx);

        ctx.ellipse(cx, cy, rx, ry, phi, startAngle, endAngle, !op.sweep);
    }

    /* Executes a stencil program. `paint` supplies the node's own colours. */
    function run(ctx, ops, paint) {
        var cursor = { x: 0, y: 0 };
        var state = {
            fill: paint.fill, stroke: paint.stroke,
            lineWidth: paint.strokeWidth, dash: paint.dash || null,
            dashPattern: null, alpha: paint.alpha == null ? 1 : paint.alpha,
            fontSize: 12, fontColor: paint.textColor || '#172033'
        };
        var stateStack = [];

        ctx.globalAlpha = state.alpha;

        function applyStroke() {
            ctx.strokeStyle = state.stroke;
            ctx.lineWidth = state.lineWidth;
            ctx.setLineDash(state.dash || []);
        }

        for (var i = 0; i < ops.length; i++) {
            var op = ops[i];

            switch (op.op) {
                case 'begin': ctx.beginPath(); break;
                case 'move': ctx.moveTo(op.x, op.y); cursor = { x: op.x, y: op.y }; break;
                case 'line': ctx.lineTo(op.x, op.y); cursor = { x: op.x, y: op.y }; break;
                case 'quad':
                    ctx.quadraticCurveTo(op.x1, op.y1, op.x, op.y);
                    cursor = { x: op.x, y: op.y };
                    break;
                case 'curve':
                    ctx.bezierCurveTo(op.x1, op.y1, op.x2, op.y2, op.x, op.y);
                    cursor = { x: op.x, y: op.y };
                    break;
                case 'arc':
                    svgArc(ctx, cursor, op);
                    cursor = { x: op.x, y: op.y };
                    break;
                case 'close': ctx.closePath(); break;
                case 'rect':
                    ctx.beginPath();
                    ctx.rect(op.x, op.y, op.w, op.h);
                    break;
                case 'roundrect':
                    ctx.beginPath();
                    var radius = Math.min(op.w, op.h) * (op.arcsize / 100);
                    if (typeof ctx.roundRect === 'function') ctx.roundRect(op.x, op.y, op.w, op.h, radius);
                    else ctx.rect(op.x, op.y, op.w, op.h);
                    break;
                case 'ellipse':
                    ctx.beginPath();
                    ctx.ellipse(op.x + op.w / 2, op.y + op.h / 2, op.w / 2, op.h / 2, 0, 0, Math.PI * 2);
                    break;
                case 'fill':
                    ctx.fillStyle = state.fill;
                    ctx.fill();
                    break;
                case 'stroke':
                    applyStroke();
                    ctx.stroke();
                    break;
                case 'fillstroke':
                    ctx.fillStyle = state.fill;
                    ctx.fill();
                    applyStroke();
                    ctx.stroke();
                    break;
                case 'strokewidth':
                    // "inherit" keeps the node's own line width.
                    state.lineWidth = (op.width === 'inherit') ? paint.strokeWidth : parseFloat(op.width);
                    break;
                case 'fillcolor': state.fill = op.color === 'none' ? 'transparent' : op.color; break;
                case 'strokecolor': state.stroke = op.color === 'none' ? 'transparent' : op.color; break;
                case 'alpha':
                    state.alpha = (paint.alpha == null ? 1 : paint.alpha) * op.alpha;
                    ctx.globalAlpha = state.alpha;
                    break;
                case 'dashed': state.dash = op.on ? (state.dashPattern || [4, 4]) : null; break;
                case 'dashpattern':
                    state.dashPattern = op.pattern;
                    if (state.dash != null) state.dash = op.pattern;
                    break;
                case 'linejoin': ctx.lineJoin = op.join; break;
                case 'linecap': ctx.lineCap = op.cap; break;
                case 'miterlimit': ctx.miterLimit = op.limit; break;
                case 'fontsize': state.fontSize = op.size; break;
                case 'fontcolor': state.fontColor = op.color; break;
                case 'save':
                    ctx.save();
                    stateStack.push({
                        fill: state.fill, stroke: state.stroke, lineWidth: state.lineWidth,
                        dash: state.dash == null ? null : state.dash.slice(),
                        dashPattern: state.dashPattern == null ? null : state.dashPattern.slice(),
                        alpha: state.alpha, fontSize: state.fontSize, fontColor: state.fontColor
                    });
                    break;
                case 'restore':
                    ctx.restore();
                    if (stateStack.length > 0) state = stateStack.pop();
                    break;
                case 'text':
                    ctx.fillStyle = state.fontColor || paint.textColor || '#172033';
                    ctx.font = (state.fontSize || 12) + 'px Arial, sans-serif';
                    ctx.textAlign = op.align;
                    ctx.textBaseline = op.valign === 'middle' ? 'middle' :
                        op.valign === 'bottom' ? 'bottom' : 'top';
                    ctx.fillText(op.str, op.x, op.y);
                    break;
                default: break;
            }
        }
    }

    /* Draws a registered stencil scaled into the node's box. */
    function draw(ctx, key, box, paint) {
        var stencil = registry[normalizeKey(key)];
        if (stencil == null) return false;

        var scaleX = box.width / stencil.w;
        var scaleY = box.height / stencil.h;
        var offsetX = 0;
        var offsetY = 0;

        if (stencil.aspect === 'fixed') {
            var uniform = Math.min(scaleX, scaleY);
            offsetX = (box.width - stencil.w * uniform) / 2;
            offsetY = (box.height - stencil.h * uniform) / 2;
            scaleX = uniform;
            scaleY = uniform;
        }

        ctx.save();
        ctx.translate(box.x + offsetX, box.y + offsetY);
        ctx.scale(scaleX, scaleY);
        // Line widths are authored in stencil units; undo the scale for them.
        var inverse = 1 / Math.max(1e-6, Math.min(Math.abs(scaleX), Math.abs(scaleY)));
        var localPaint = {
            fill: paint.fill, stroke: paint.stroke, textColor: paint.textColor,
            strokeWidth: (paint.strokeWidth == null ? 1 : paint.strokeWidth) * inverse,
            alpha: paint.alpha == null ? 1 : paint.alpha,
            dash: paint.dash
        };
        run(ctx, stencil.background.concat(stencil.foreground), localPaint);
        ctx.restore();
        return true;
    }

    function get(key) {
        return registry[normalizeKey(key)] || null;
    }

    function all() {
        return Object.keys(registry).map(function(key) { return registry[key]; });
    }

    function byLibrary() {
        return libraries;
    }

    /* Registers already-parsed programs, used inside the render worker. */
    function register(shapes) {
        (shapes || []).forEach(function(shape) {
            registry[shape.key] = shape;
            libraries[shape.library] = (libraries[shape.library] || []).concat([shape]);
        });
        forward(shapes);
    }

    root.PixelStencils = {
        parse: parse,
        register: register,
        draw: draw,
        get: get,
        all: all,
        byLibrary: byLibrary
    };
})(typeof self !== 'undefined' ? self : this);
