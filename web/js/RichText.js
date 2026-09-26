/*
 * Rich text model, canvas layout engine, and HTML bridge.
 *
 * The classic editor leans on the browser to lay out formatted labels inside
 * foreignObjects. There is no DOM in the canvas viewport, so formatted text is
 * kept as a small block/run model and measured and drawn directly on the 2D
 * context. The same engine backs three things: node labels, individual table
 * cells, and HTML blocks.
 *
 * Model
 *   { blocks: [ { type, indent, align, runs: [ { text, ...marks } ] } ] }
 *   type   'p' | 'h1' | 'h2' | 'h3' | 'ul' | 'ol' | 'pre'
 *   marks  bold, italic, underline, strike, script ('sub'|'sup'),
 *          color, size, family, link
 *
 * The model is plain JSON so it survives structuredClone into the render
 * worker and round-trips through the document format unchanged.
 */
(function(root) {
    'use strict';

    var BLOCK_SCALE = { h1: 1.7, h2: 1.4, h3: 1.2, p: 1, ul: 1, ol: 1, pre: 1 };
    var INDENT_STEP = 22;
    var MARKER_GAP = 8;

    function isBlank(value) {
        return value == null || value === '';
    }

    /* ------------------------------------------------------------------ */
    /* Model helpers                                                       */
    /* ------------------------------------------------------------------ */

    function emptyModel() {
        return { blocks: [{ type: 'p', indent: 0, runs: [] }] };
    }

    /* Plain text keeps working everywhere: it becomes one paragraph a line. */
    function fromPlain(text) {
        var lines = String(text == null ? '' : text).split('\n');
        return {
            blocks: lines.map(function(line) {
                return { type: 'p', indent: 0, runs: line ? [{ text: line }] : [] };
            })
        };
    }

    function toPlain(model) {
        if (!model || !Array.isArray(model.blocks)) return '';
        return model.blocks.map(function(block) {
            return (block.runs || []).map(function(run) { return run.text || ''; }).join('');
        }).join('\n');
    }

    function isEmpty(model) {
        return toPlain(model).trim() === '';
    }

    /* True when nothing in the model needs more than the plain text path. */
    function isPlain(model) {
        if (!model || !Array.isArray(model.blocks)) return true;

        for (var b = 0; b < model.blocks.length; b++) {
            var block = model.blocks[b];
            if (block.type && block.type !== 'p') return false;
            if (block.indent) return false;
            if (block.align) return false;
            var runs = block.runs || [];
            for (var r = 0; r < runs.length; r++) {
                var run = runs[r];
                if (run.bold || run.italic || run.underline || run.strike || run.script ||
                    run.color || run.size || run.family || run.link) return false;
            }
        }

        return true;
    }

    /* ------------------------------------------------------------------ */
    /* Layout                                                              */
    /* ------------------------------------------------------------------ */

    function runStyle(run, block, base) {
        var scale = BLOCK_SCALE[block.type] || 1;
        var size = (Number(run.size) || base.fontSize || 14) * scale;
        if (run.script) size = size * 0.72;
        var weight = run.bold || block.type === 'h1' || block.type === 'h2' || block.type === 'h3' ?
            700 : (base.fontWeight || 500);
        var family = run.family || (block.type === 'pre' ? 'Consolas, monospace' : null) ||
            base.fontFamily || 'Arial, sans-serif';

        return {
            size: size,
            font: (run.italic || base.italic ? 'italic ' : '') + weight + ' ' + size + 'px ' + family,
            color: run.color || base.color || '#172033',
            underline: run.underline === true || base.underline === true || run.link != null,
            strike: run.strike === true || base.strike === true,
            shift: run.script === 'sup' ? -size * 0.42 : run.script === 'sub' ? size * 0.22 : 0
        };
    }

    /* Breaks the model into drawable lines. maxWidth <= 0 disables wrapping. */
    function layout(ctx, model, base, maxWidth) {
        var lineHeightFactor = base.lineHeight || 1.28;
        var wrap = maxWidth > 0;
        var lines = [];
        var widest = 0;
        var counters = {};

        (model.blocks || []).forEach(function(block, blockIndex) {
            var indent = (block.indent || 0) * INDENT_STEP;
            var marker = null;

            if (block.type === 'ul' || block.type === 'ol') {
                var key = block.type + ':' + (block.indent || 0);
                // A gap in the list restarts the numbering, as in a document.
                var previous = model.blocks[blockIndex - 1];
                if (!previous || previous.type !== block.type ||
                    (previous.indent || 0) !== (block.indent || 0)) counters[key] = 0;
                counters[key] = (counters[key] || 0) + 1;
                marker = block.type === 'ul' ? '•' : counters[key] + '.';
            }

            var current = null;
            var first = true;

            function open() {
                current = {
                    segments: [], width: 0, size: base.fontSize || 14,
                    indent: indent, align: block.align || base.align || 'center',
                    marker: first ? marker : null, block: block
                };
                first = false;
            }

            function close() {
                if (current == null) return;
                // Trailing whitespace must not shift a centred line.
                while (current.segments.length > 0 &&
                    /^\s+$/.test(current.segments[current.segments.length - 1].text)) {
                    current.width -= current.segments.pop().width;
                }
                current.height = current.size * lineHeightFactor;
                var full = current.width + current.indent +
                    (current.marker ? measureMarker(ctx, current, base) : 0);
                widest = Math.max(widest, full);
                lines.push(current);
                current = null;
            }

            open();
            var runs = block.runs || [];

            if (runs.length === 0) {
                close();
                return;
            }

            for (var r = 0; r < runs.length; r++) {
                var run = runs[r];
                var style = runStyle(run, block, base);
                ctx.font = style.font;
                var pieces = String(run.text == null ? '' : run.text).split('\n');

                for (var p = 0; p < pieces.length; p++) {
                    if (p > 0) { close(); open(); }
                    var tokens = pieces[p].split(/(\s+)/);

                    for (var t = 0; t < tokens.length; t++) {
                        var token = tokens[t];
                        if (token === '') continue;
                        var width = ctx.measureText(token).width;
                        var space = /^\s+$/.test(token);

                        if (wrap && !space && current.segments.length > 0 &&
                            current.indent + current.width + width > maxWidth) {
                            close();
                            open();
                            // A wrapped line never starts with the pending space.
                        }

                        if (space && current.segments.length === 0) continue;
                        current.segments.push({
                            text: token, style: style, width: width, x: current.width
                        });
                        current.width += width;
                        current.size = Math.max(current.size, style.size);
                    }
                }
            }

            close();
        });

        var height = lines.reduce(function(sum, line) { return sum + line.height; }, 0);
        return { lines: lines, width: widest, height: height };
    }

    function measureMarker(ctx, line, base) {
        ctx.font = (base.fontWeight || 500) + ' ' + line.size + 'px ' +
            (base.fontFamily || 'Arial, sans-serif');
        return ctx.measureText(line.marker).width + MARKER_GAP;
    }

    /* Draws a laid-out model inside box {x, y, width, height}. */
    function draw(ctx, model, box, base) {
        var padding = base.padding == null ? 9 : base.padding;
        var maxWidth = base.wrap === false ? 0 : Math.max(10, box.width - padding * 2);
        var result = layout(ctx, model, base, maxWidth);
        var vertical = base.verticalAlign || 'middle';
        var y = box.y + (box.height - result.height) / 2;
        if (vertical === 'top') y = box.y + padding;
        if (vertical === 'bottom') y = box.y + box.height - result.height - padding;

        ctx.textBaseline = 'alphabetic';
        ctx.textAlign = 'left';

        for (var i = 0; i < result.lines.length; i++) {
            var line = result.lines[i];
            var markerWidth = line.marker ? measureMarker(ctx, line, base) : 0;
            var content = line.width + markerWidth;
            var left = box.x + padding + line.indent;

            if (line.align === 'center') left = box.x + (box.width - content) / 2 + line.indent / 2;
            else if (line.align === 'right') left = box.x + box.width - padding - content;

            var baseline = y + line.height * 0.78;

            // Keeps layout stable while the corresponding HTML block is being
            // edited over the canvas, but does not paint a duplicate marker or
            // text behind the contenteditable element.
            if (line.block.hidden === true) {
                y += line.height;
                continue;
            }

            if (line.marker) {
                ctx.font = (base.fontWeight || 500) + ' ' + line.size + 'px ' +
                    (base.fontFamily || 'Arial, sans-serif');
                ctx.fillStyle = base.color || '#172033';
                ctx.fillText(line.marker, left, baseline);
            }

            for (var s = 0; s < line.segments.length; s++) {
                var segment = line.segments[s];
                var x = left + markerWidth + segment.x;
                ctx.font = segment.style.font;
                ctx.fillStyle = segment.style.color;
                ctx.fillText(segment.text, x, baseline + segment.style.shift);

                if (segment.style.underline || segment.style.strike) {
                    var rule = baseline + segment.style.shift +
                        (segment.style.strike ? -segment.style.size * 0.3 : segment.style.size * 0.16);
                    ctx.beginPath();
                    ctx.moveTo(x, rule);
                    ctx.lineTo(x + segment.width, rule);
                    ctx.strokeStyle = segment.style.color;
                    ctx.lineWidth = Math.max(1, segment.style.size / 14);
                    ctx.stroke();
                }
            }

            y += line.height;
        }

        return result;
    }

    /* Natural size of the content, for autosize and HTML blocks. */
    function measure(ctx, model, base, maxWidth) {
        return layout(ctx, model, base, maxWidth == null ? 0 : maxWidth);
    }

    /* ------------------------------------------------------------------ */
    /* HTML bridge (main thread only)                                      */
    /* ------------------------------------------------------------------ */

    var BLOCK_TAGS = { P: 'p', DIV: 'p', H1: 'h1', H2: 'h2', H3: 'h3', PRE: 'pre', LI: 'li' };
    var MARK_TAGS = {
        B: 'bold', STRONG: 'bold', I: 'italic', EM: 'italic',
        U: 'underline', INS: 'underline', S: 'strike', STRIKE: 'strike', DEL: 'strike',
        SUB: 'sub', SUP: 'sup', CODE: 'code'
    };

    function styleMarks(element, marks) {
        var style = element.style;
        if (!style) return marks;
        if (style.fontWeight === 'bold' || Number(style.fontWeight) >= 600) marks.bold = true;
        if (style.fontStyle === 'italic') marks.italic = true;
        if (style.textDecorationLine || style.textDecoration) {
            var decoration = style.textDecorationLine || style.textDecoration;
            if (decoration.indexOf('underline') >= 0) marks.underline = true;
            if (decoration.indexOf('line-through') >= 0) marks.strike = true;
        }
        if (style.color) marks.color = style.color;
        if (style.fontSize && /px$/.test(style.fontSize)) marks.size = parseFloat(style.fontSize);
        if (style.fontFamily) marks.family = style.fontFamily;
        return marks;
    }

    /* Parses a safe subset of HTML into the model. Scripts, styles, iframes
       and event attributes are dropped: the canvas cannot execute them and we
       do not want them reaching the document either. */
    function fromHtml(html) {
        if (typeof document === 'undefined') return fromPlain(html);
        var host = document.createElement('div');
        host.innerHTML = String(html == null ? '' : html);
        host.querySelectorAll('script,style,iframe,object,embed,link,meta').forEach(function(node) {
            node.remove();
        });

        var blocks = [];
        var current = null;

        function open(type, indent, align) {
            current = { type: type || 'p', indent: indent || 0, runs: [] };
            if (align) current.align = align;
            blocks.push(current);
            return current;
        }

        function push(text, marks) {
            if (text === '') return;
            if (current == null) open('p', 0);
            var run = { text: text };
            Object.keys(marks).forEach(function(key) {
                if (key === 'sub' || key === 'sup') run.script = key;
                else if (key === 'code') run.family = 'Consolas, monospace';
                else if (marks[key] != null && marks[key] !== false) run[key] = marks[key];
            });
            current.runs.push(run);
        }

        function walk(node, marks, listType, indent, align) {
            for (var i = 0; i < node.childNodes.length; i++) {
                var child = node.childNodes[i];

                if (child.nodeType === 3) {
                    push(child.nodeValue.replace(/\s+/g, ' '), marks);
                    continue;
                }
                if (child.nodeType !== 1) continue;

                var tag = child.tagName;

                if (tag === 'BR') {
                    open(current ? current.type : 'p', indent, align);
                    continue;
                }

                if (tag === 'UL' || tag === 'OL') {
                    walk(child, marks, tag === 'UL' ? 'ul' : 'ol', indent + (listType ? 1 : 0), align);
                    current = null;
                    continue;
                }

                if (tag === 'BLOCKQUOTE') {
                    walk(child, marks, listType, indent + 1, align);
                    current = null;
                    continue;
                }

                if (BLOCK_TAGS[tag]) {
                    var type = BLOCK_TAGS[tag] === 'li' ? (listType || 'ul') : BLOCK_TAGS[tag];
                    var blockAlign = (child.style && child.style.textAlign) || align;
                    open(type, indent, blockAlign);
                    walk(child, styleMarks(child, Object.assign({}, marks)), listType, indent, blockAlign);
                    current = null;
                    continue;
                }

                var next = Object.assign({}, marks);
                if (MARK_TAGS[tag]) next[MARK_TAGS[tag]] = true;
                if (tag === 'FONT') {
                    if (child.getAttribute('color')) next.color = child.getAttribute('color');
                    if (child.getAttribute('face')) next.family = child.getAttribute('face');
                }
                if (tag === 'A' && child.getAttribute('href')) next.link = child.getAttribute('href');
                walk(child, styleMarks(child, next), listType, indent, align);
            }
        }

        walk(host, {}, null, 0, null);
        if (blocks.length === 0) blocks.push({ type: 'p', indent: 0, runs: [] });

        // Drop blocks that exist only because of layout whitespace.
        blocks = blocks.filter(function(block, index) {
            if (block.runs.length > 0) return true;
            return index === 0 || index === blocks.length - 1 ? blocks.length === 1 : false;
        });

        return { blocks: blocks.length ? blocks : [{ type: 'p', indent: 0, runs: [] }] };
    }

    function escapeHtml(value) {
        return String(value == null ? '' : value)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    function runToHtml(run) {
        var html = escapeHtml(run.text).replace(/ {2}/g, ' &nbsp;');
        if (run.bold) html = '<b>' + html + '</b>';
        if (run.italic) html = '<i>' + html + '</i>';
        if (run.underline) html = '<u>' + html + '</u>';
        if (run.strike) html = '<s>' + html + '</s>';
        if (run.script === 'sub') html = '<sub>' + html + '</sub>';
        if (run.script === 'sup') html = '<sup>' + html + '</sup>';

        var style = '';
        if (run.color) style += 'color:' + run.color + ';';
        if (run.size) style += 'font-size:' + run.size + 'px;';
        if (run.family) style += 'font-family:' + run.family + ';';
        if (style) html = '<span style="' + style + '">' + html + '</span>';
        return html;
    }

    function toHtml(model) {
        if (!model || !Array.isArray(model.blocks)) return '';
        var html = '';
        var openList = null;

        model.blocks.forEach(function(block) {
            var inner = (block.runs || []).map(runToHtml).join('') || '<br>';
            var align = block.align ? ' style="text-align:' + block.align + '"' : '';
            var pad = block.indent ? ' style="margin-left:' + (block.indent * 22) + 'px"' : '';

            if (block.type === 'ul' || block.type === 'ol') {
                if (openList !== block.type) {
                    if (openList) html += '</' + openList + '>';
                    html += '<' + block.type + '>';
                    openList = block.type;
                }
                html += '<li>' + inner + '</li>';
                return;
            }

            if (openList) { html += '</' + openList + '>'; openList = null; }
            var tag = block.type === 'p' ? 'div' : block.type;
            html += '<' + tag + (align || pad) + '>' + inner + '</' + tag + '>';
        });

        if (openList) html += '</' + openList + '>';
        return html;
    }

    root.PixelRichText = {
        emptyModel: emptyModel,
        fromPlain: fromPlain,
        toPlain: toPlain,
        isEmpty: isEmpty,
        isPlain: isPlain,
        layout: layout,
        measure: measure,
        draw: draw,
        fromHtml: fromHtml,
        toHtml: toHtml,
        INDENT_STEP: INDENT_STEP
    };
})(typeof self !== 'undefined' ? self : this);
