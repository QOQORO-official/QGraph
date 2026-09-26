/*
 * SVG previews for the shape palette.
 *
 * The diagram itself is canvas, but the sidebar is ordinary DOM, and the
 * classic editor drew its palette entries as SVG. Canvas thumbnails have to be
 * rasterised at a fixed size, so compact entries end up soft and the outlines
 * thin out; SVG stays crisp at any zoom or device pixel ratio and matches the
 * look of the original inventory.
 *
 * Geometry here mirrors ScenePainter.traceNode so a palette entry and the
 * shape it creates have the same outline.
 */
(function(root) {
    'use strict';

    var NS = 'http://www.w3.org/2000/svg';
    var XHTML_NS = 'http://www.w3.org/1999/xhtml';

    function el(name, attrs) {
        var node = document.createElementNS(NS, name);
        Object.keys(attrs || {}).forEach(function(key) {
            node.setAttribute(key, attrs[key]);
        });
        return node;
    }

    function points(list) {
        return list.map(function(p) { return p.x + ',' + p.y; }).join(' ');
    }

    /* Removes executable markup while retaining the ordinary rich HTML that
       the original mxGraph inventory rendered in foreignObject labels. */
    function safeHtml(markup) {
        var template = document.createElement('template');
        template.innerHTML = String(markup || '')
            // Some old palette constants were assembled from adjacent quoted
            // strings. Treat those source separators as source, not content.
            .replace(/'\s*\+\s*'/g, '')
            .replace(/\\n/g, '<br>');

        Array.prototype.slice.call(template.content.querySelectorAll(
            'script,iframe,object,embed,link,meta,base')).forEach(function(node) {
            node.remove();
        });
        Array.prototype.slice.call(template.content.querySelectorAll('*')).forEach(function(node) {
            Array.prototype.slice.call(node.attributes).forEach(function(attribute) {
                var name = attribute.name.toLowerCase();
                var value = String(attribute.value || '').trim().toLowerCase();
                if (name.indexOf('on') === 0 ||
                    ((name === 'href' || name === 'src' || name === 'xlink:href') &&
                        value.indexOf('javascript:') === 0)) {
                    node.removeAttribute(attribute.name);
                }
            });
        });
        return template.innerHTML;
    }

    function htmlValue(template, source) {
        if (source && typeof source.value === 'string' && /<[^>]+>/.test(source.value)) {
            return source.value;
        }
        if (typeof template.html === 'string' && template.html !== '') return template.html;
        return null;
    }

    function addHtmlLabel(group, node, template, markup) {
        var foreign = el('foreignObject', {
            x: 0, y: 0, width: node.width, height: node.height,
            'pointer-events': 'none'
        });
        var div = document.createElementNS(XHTML_NS, 'div');
        div.setAttribute('xmlns', XHTML_NS);
        div.setAttribute('class', 'geShapeHtmlLabel');
        div.style.cssText = [
            'display:flex',
            'box-sizing:border-box',
            'width:100%',
            'height:100%',
            'overflow:hidden',
            'padding:' + Math.max(0, template.textPadding == null ? 2 : template.textPadding) + 'px',
            'align-items:' + (template.verticalAlign === 'top' ? 'flex-start' :
                (template.verticalAlign === 'bottom' ? 'flex-end' : 'center')),
            'justify-content:' + (template.textAlign === 'left' ? 'flex-start' :
                (template.textAlign === 'right' ? 'flex-end' : 'center')),
            'text-align:' + (template.textAlign || 'center'),
            'font-family:' + (template.fontFamily || 'Arial, Helvetica, sans-serif'),
            'font-size:' + Math.max(9, template.fontSize || 11) + 'px',
            'font-weight:' + (template.fontWeight || 400),
            'line-height:1.2',
            'color:' + (template.textColor || '#172033'),
            'background:transparent'
        ].join(';');

        var content = document.createElementNS(XHTML_NS, 'div');
        content.style.cssText = 'box-sizing:border-box;max-width:100%;max-height:100%;overflow:hidden;';
        content.innerHTML = safeHtml(markup);
        div.appendChild(content);
        foreign.appendChild(div);
        group.appendChild(foreign);
    }

    function escapeText(value) {
        return String(value == null ? '' : value)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    /* The old Visual Script palette was an SVG rendering of the actual HTML
       node, including its title text and the two status lamps. At thumbnail
       scale these details are intentionally tiny, but retaining them keeps
       both the DOM structure and the silhouette identical to the canvas card. */
    function addVisualScriptCard(group, node, template) {
        var indicators = {
            input: '#7b8794', process: '#7b8794', condition: '#d97706',
            for: '#ea580c', while: '#7c3aed', output: '#16a34a',
            function: '#0891b2', http: '#0d9488', delay: '#ca8a04',
            qnoteTemplate: '#7c3aed', sheetTemplate: '#0e7490',
            llm: '#e11d48', uiLLM: '#06b6d4', slack: '#611f69'
        };
        var headerHeight = Math.min(30, node.height);
        var lampY = headerHeight / 2;
        group.appendChild(el('circle', {
            cx: 12, cy: lampY, r: 4.5,
            fill: indicators[template.vsType] || '#7b8794',
            stroke: '#6b7280', 'stroke-width': 1,
            'vector-effect': 'non-scaling-stroke'
        }));
        group.appendChild(el('circle', {
            cx: Math.max(12, node.width - 12), cy: lampY, r: 4,
            fill: '#22c55e', stroke: '#6b7280', 'stroke-width': 1,
            'vector-effect': 'non-scaling-stroke'
        }));

        var htmlStyle = Object.assign({}, template, {
            textPadding: 0, textAlign: 'left', verticalAlign: 'top',
            fontSize: 12, fontWeight: 700, textColor: '#222222'
        });
        addHtmlLabel(group, node, htmlStyle,
            '<div style="box-sizing:border-box;height:' + headerHeight +
            'px;padding:7px 24px 0 25px;white-space:nowrap;overflow:hidden;' +
            'text-overflow:ellipsis;line-height:16px;">' +
            escapeText(template.text || template.vsType || 'Script') + '</div>');
    }

    /* Shapes mxGraph draws as an open stroke; filling them paints the area
       the line merely crosses. Mirrors STROKE_ONLY_SHAPES in CanvasPaint.js. */
    var STROKE_ONLY_SHAPES = {
        text: true, actor: true, umlDestroy: true, requiredInterface: true,
        curlyBracket: true, crossbar: true, line: true
    };

    /* Returns an SVG element describing the node outline in its own
       coordinate space (0,0 to width,height). */
    function outline(node) {
        var w = node.width;
        var h = node.height;
        var shape = node.shape || 'rect';
        var radius = node.radius == null ? 4 : node.radius;

        if (shape === 'ellipse') {
            return el('ellipse', { cx: w / 2, cy: h / 2, rx: w / 2, ry: h / 2 });
        }
        if (shape === 'diamond') {
            return el('polygon', { points: points([
                { x: w / 2, y: 0 }, { x: w, y: h / 2 }, { x: w / 2, y: h }, { x: 0, y: h / 2 }
            ]) });
        }
        if (shape === 'triangle') {
            return el('polygon', { points: points([
                { x: w / 2, y: 0 }, { x: w, y: h }, { x: 0, y: h }
            ]) });
        }
        if (shape === 'hexagon') {
            return el('polygon', { points: points([
                { x: w * .22, y: 0 }, { x: w * .78, y: 0 }, { x: w, y: h / 2 },
                { x: w * .78, y: h }, { x: w * .22, y: h }, { x: 0, y: h / 2 }
            ]) });
        }
        if (shape === 'parallelogram') {
            return el('polygon', { points: points([
                { x: w * .22, y: 0 }, { x: w, y: 0 }, { x: w * .78, y: h }, { x: 0, y: h }
            ]) });
        }
        if (shape === 'trapezoid') {
            return el('polygon', { points: points([
                { x: w * .2, y: 0 }, { x: w * .8, y: 0 }, { x: w, y: h }, { x: 0, y: h }
            ]) });
        }
        if (shape === 'step' || shape === 'chevron') {
            return el('polygon', { points: points([
                { x: 0, y: 0 }, { x: w * .78, y: 0 }, { x: w, y: h / 2 },
                { x: w * .78, y: h }, { x: 0, y: h }, { x: w * .22, y: h / 2 }
            ]) });
        }
        if (shape === 'isoCube2') {
            var isoAngle = Math.max(.01, Math.min(94,
                node.isoAngle == null ? 15 : Number(node.isoAngle))) * Math.PI / 200;
            var isoHeight = Math.min(w * Math.tan(isoAngle), h * .5);
            return el('polygon', { points: points([
                { x: w / 2, y: 0 }, { x: w, y: isoHeight },
                { x: w, y: h - isoHeight }, { x: w / 2, y: h },
                { x: 0, y: h - isoHeight }, { x: 0, y: isoHeight }
            ]) });
        }
        if (shape === 'isoRectangle') {
            return el('polygon', { points: points([
                { x: 0, y: h / 2 }, { x: w / 2, y: 0 },
                { x: w, y: h / 2 }, { x: w / 2, y: h }
            ]) });
        }
        if (shape === 'line') {
            return node.direction === 'south' || node.direction === 'north' ?
                el('line', { x1: w / 2, y1: 0, x2: w / 2, y2: h }) :
                el('line', { x1: 0, y1: h / 2, x2: w, y2: h / 2 });
        }
        if (shape === 'curlyBracket') {
            return el('path', { d: 'M ' + w + ' 0 C 0 0 ' + w + ' ' + (h * .38) +
                ' 0 ' + (h / 2) + ' C ' + w + ' ' + (h * .62) + ' 0 ' + h + ' ' + w + ' ' + h });
        }
        if (shape === 'crossbar') {
            return el('path', { d: 'M 0 ' + (h / 2) + ' L ' + w + ' ' + (h / 2) +
                ' M 0 0 L 0 ' + h + ' M ' + w + ' 0 L ' + w + ' ' + h });
        }
        if (shape === 'plus') {
            return el('polygon', { points: points([
                { x: w * .35, y: 0 }, { x: w * .65, y: 0 }, { x: w * .65, y: h * .35 },
                { x: w, y: h * .35 }, { x: w, y: h * .65 }, { x: w * .65, y: h * .65 },
                { x: w * .65, y: h }, { x: w * .35, y: h }, { x: w * .35, y: h * .65 },
                { x: 0, y: h * .65 }, { x: 0, y: h * .35 }, { x: w * .35, y: h * .35 }
            ]) });
        }
        if (shape === 'note') {
            var fold = Math.min(w, h) * .28;
            return el('path', { d: 'M 0 0 L ' + (w - fold) + ' 0 L ' + w + ' ' + fold +
                ' L ' + w + ' ' + h + ' L 0 ' + h + ' Z M ' + (w - fold) + ' 0 L ' +
                (w - fold) + ' ' + fold + ' L ' + w + ' ' + fold });
        }
        if (shape === 'cylinder') {
            var ry = h * Math.max(0, Math.min(.5,
                node.shapeSize == null ? .1875 : Number(node.shapeSize)));
            return el('path', { d: 'M 0 ' + ry + ' A ' + (w / 2) + ' ' + ry + ' 0 0 1 ' + w + ' ' + ry +
                ' L ' + w + ' ' + (h - ry) + ' A ' + (w / 2) + ' ' + ry + ' 0 0 1 0 ' + (h - ry) +
                ' Z M 0 ' + ry + ' A ' + (w / 2) + ' ' + ry + ' 0 0 0 ' + w + ' ' + ry });
        }
        if (shape === 'document') {
            return el('path', { d: 'M 0 0 L ' + w + ' 0 L ' + w + ' ' + (h * .82) +
                ' C ' + (w * .75) + ' ' + h + ' ' + (w * .25) + ' ' + (h * .64) +
                ' 0 ' + (h * .82) + ' Z' });
        }
        if (shape === 'tape') {
            return el('path', { d: 'M 0 ' + (h * .18) +
                ' C ' + (w * .25) + ' ' + (-h * .1) + ' ' + (w * .75) + ' ' + (h * .4) + ' ' + w + ' ' + (h * .18) +
                ' L ' + w + ' ' + (h * .82) +
                ' C ' + (w * .75) + ' ' + (h * 1.1) + ' ' + (w * .25) + ' ' + (h * .6) + ' 0 ' + (h * .82) + ' Z' });
        }
        if (shape === 'cube') {
            var d = Math.min(w, h) * .22;
            return el('path', { d: 'M 0 ' + d + ' L ' + d + ' 0 L ' + w + ' 0 L ' + w + ' ' + (h - d) +
                ' L ' + (w - d) + ' ' + h + ' L 0 ' + h + ' Z M 0 ' + d + ' L ' + (w - d) + ' ' + d +
                ' L ' + w + ' 0 M ' + (w - d) + ' ' + d + ' L ' + (w - d) + ' ' + h });
        }
        if (shape === 'cloud') {
            return el('path', { d: 'M ' + (w * .25) + ' ' + (h * .8) +
                ' A ' + (w * .18) + ' ' + (h * .22) + ' 0 0 1 ' + (w * .18) + ' ' + (h * .45) +
                ' A ' + (w * .2) + ' ' + (h * .26) + ' 0 0 1 ' + (w * .45) + ' ' + (h * .22) +
                ' A ' + (w * .22) + ' ' + (h * .25) + ' 0 0 1 ' + (w * .82) + ' ' + (h * .38) +
                ' A ' + (w * .16) + ' ' + (h * .22) + ' 0 0 1 ' + (w * .78) + ' ' + (h * .8) + ' Z' });
        }
        if (shape === 'actor') {
            var head = Math.min(w, h) * .22;
            return el('path', { d:
                'M ' + (w / 2) + ' ' + head + ' m ' + (-head) + ' 0 a ' + head + ' ' + head +
                ' 0 1 0 ' + (head * 2) + ' 0 a ' + head + ' ' + head + ' 0 1 0 ' + (-head * 2) + ' 0 ' +
                'M ' + (w / 2) + ' ' + (head * 2) + ' L ' + (w / 2) + ' ' + (h * .68) +
                ' M ' + (w * .12) + ' ' + (h * .42) + ' L ' + (w * .88) + ' ' + (h * .42) +
                ' M ' + (w / 2) + ' ' + (h * .68) + ' L ' + (w * .15) + ' ' + h +
                ' M ' + (w / 2) + ' ' + (h * .68) + ' L ' + (w * .85) + ' ' + h });
        }
        if (shape === 'speech') {
            var tail = h * .22;
            return el('path', { d: 'M 0 0 L ' + w + ' 0 L ' + w + ' ' + (h - tail) +
                ' L ' + (w * .32) + ' ' + (h - tail) + ' L ' + (w * .18) + ' ' + h +
                ' L ' + (w * .2) + ' ' + (h - tail) + ' L 0 ' + (h - tail) + ' Z' });
        }
        if (shape === 'manualInput') {
            var manualSize = Math.min(h, node.shapeSize == null ? 30 : Number(node.shapeSize));
            return el('polygon', { points: '0,' + manualSize + ' ' + w + ',0 ' + w + ',' + h + ' 0,' + h });
        }
        if (shape === 'loopLimit') {
            // Two independent axes, matching the painter: shapeSize cuts the
            // top corners, dy sets how far the slope descends.
            var loopSize = Math.max(0, Math.min(w / 2, node.shapeSize == null ? 20 : Number(node.shapeSize)));
            var loopDrop = Math.max(0, Math.min(h, node.dy == null ? loopSize * .8 : Number(node.dy)));
            return el('polygon', { points: loopSize + ',0 ' + (w - loopSize) + ',0 ' + w + ',' + loopDrop +
                ' ' + w + ',' + h + ' 0,' + h + ' 0,' + loopDrop });
        }
        if (shape === 'offPageConnector') {
            var connectorSize = h * Math.max(0, Math.min(1, node.shapeSize == null ? 3 / 8 : Number(node.shapeSize)));
            return el('polygon', { points: '0,0 ' + w + ',0 ' + w + ',' + (h - connectorSize) +
                ' ' + (w / 2) + ',' + h + ' 0,' + (h - connectorSize) });
        }
        if (shape === 'display') {
            var displayDx = Math.min(w, h / 2);
            var displaySize = Math.min(w - displayDx, Math.max(0, node.shapeSize == null ? .25 : Number(node.shapeSize)) * w);
            return el('path', { d: 'M 0 ' + (h / 2) + ' L ' + displaySize + ' 0 L ' + (w - displayDx) +
                ' 0 Q ' + w + ' 0 ' + w + ' ' + (h / 2) + ' Q ' + w + ' ' + h + ' ' +
                (w - displayDx) + ' ' + h + ' L ' + displaySize + ' ' + h + ' Z' });
        }
        if (shape === 'singleArrow' || shape === 'doubleArrow') {
            var direction = node.direction || 'east';
            var vertical = direction === 'north' || direction === 'south';
            var aw = vertical ? h : w, ah = vertical ? w : h;
            var shaft = ah * Math.max(0, Math.min(1, node.arrowWidth == null ? .3 : Number(node.arrowWidth)));
            var tip = aw * Math.max(0, Math.min(1, node.arrowSize == null ? .2 : Number(node.arrowSize)));
            var at = (ah - shaft) / 2, ab = at + shaft;
            function ap(u, v) {
                if (direction === 'west') return (w - u) + ',' + (h - v);
                if (direction === 'north') return v + ',' + (h - u);
                if (direction === 'south') return (w - v) + ',' + u;
                return u + ',' + v;
            }
            var arrow = shape === 'singleArrow' ?
                [ap(0, at), ap(aw - tip, at), ap(aw - tip, 0), ap(aw, ah / 2), ap(aw - tip, ah), ap(aw - tip, ab), ap(0, ab)] :
                [ap(0, ah / 2), ap(tip, 0), ap(tip, at), ap(aw - tip, at), ap(aw - tip, 0), ap(aw, ah / 2),
                    ap(aw - tip, ah), ap(aw - tip, ab), ap(tip, ab), ap(tip, ah)];
            return el('polygon', { points: arrow.join(' ') });
        }
        if (shape === 'cross') {
            var cs = Math.min(w, h) * Math.max(0, Math.min(1, node.shapeSize == null ? .2 : Number(node.shapeSize)));
            var ct = (h - cs) / 2, cb = ct + cs, cl = (w - cs) / 2, cr = cl + cs;
            return el('polygon', { points: '0,' + ct + ' ' + cl + ',' + ct + ' ' + cl + ',0 ' + cr + ',0 ' + cr + ',' + ct +
                ' ' + w + ',' + ct + ' ' + w + ',' + cb + ' ' + cr + ',' + cb + ' ' + cr + ',' + h + ' ' + cl + ',' + h +
                ' ' + cl + ',' + cb + ' 0,' + cb });
        }
        if (shape === 'corner' || shape === 'tee') {
            var sd = Math.min(w, h, node.shapeSize == null ? 20 : Number(node.shapeSize));
            return el('polygon', { points: shape === 'corner' ?
                '0,0 ' + w + ',0 ' + w + ',' + sd + ' ' + sd + ',' + sd + ' ' + sd + ',' + h + ' 0,' + h :
                '0,0 ' + w + ',0 ' + w + ',' + sd + ' ' + (w / 2 + sd / 2) + ',' + sd + ' ' + (w / 2 + sd / 2) + ',' + h +
                ' ' + (w / 2 - sd / 2) + ',' + h + ' ' + (w / 2 - sd / 2) + ',' + sd + ' 0,' + sd });
        }
        if (shape === 'tapeData' || shape === 'orEllipse' || shape === 'sumEllipse' || shape === 'lineEllipse') {
            return el('ellipse', { cx: w / 2, cy: h / 2, rx: w / 2, ry: h / 2 });
        }
        if (shape === 'sortShape') {
            return el('polygon', { points: (w / 2) + ',0 ' + w + ',' + (h / 2) + ' ' + (w / 2) + ',' + h + ' 0,' + (h / 2) });
        }
        if (shape === 'collate') {
            return el('path', { d: 'M 0 0 L ' + w + ' 0 L ' + (w / 2) + ' ' + (h / 2) + ' Z M 0 ' + h +
                ' L ' + w + ' ' + h + ' L ' + (w / 2) + ' ' + (h / 2) + ' Z' });
        }
        if (shape === 'datastore') {
            var cap = Math.min(h / 2, Math.round(h / 8) + (node.strokeWidth || 1) - 1);
            return el('path', { d: 'M 0 ' + cap + ' C 0 ' + (-cap / 3) + ' ' + w + ' ' + (-cap / 3) + ' ' + w + ' ' + cap +
                ' L ' + w + ' ' + (h - cap) + ' C ' + w + ' ' + (h + cap / 3) + ' 0 ' + (h + cap / 3) + ' 0 ' + (h - cap) + ' Z' });
        }
        if (shape === 'switch') {
            return el('path', { d: 'M 0 0 Q ' + (w / 2) + ' ' + (h / 2) + ' ' + w + ' 0 Q ' + (w / 2) + ' ' +
                (h / 2) + ' ' + w + ' ' + h + ' Q ' + (w / 2) + ' ' + (h / 2) + ' 0 ' + h +
                ' Q ' + (w / 2) + ' ' + (h / 2) + ' 0 0 Z' });
        }
        if (shape === 'partialRectangle') {
            return el('rect', { x: 0, y: 0, width: w, height: h, stroke: 'none' });
        }
        if (shape === 'delay') {
            var delayDx = Math.min(w, h / 2);
            return el('path', { d: 'M 0 0 L ' + (w - delayDx) + ' 0 Q ' + w + ' 0 ' + w + ' ' + (h / 2) +
                ' Q ' + w + ' ' + h + ' ' + (w - delayDx) + ' ' + h + ' L 0 ' + h + ' Z' });
        }
        if (shape === 'umlBoundary') {
            return el('ellipse', { cx: w / 6 + (w * 5 / 6) / 2, cy: h / 2,
                rx: (w * 5 / 6) / 2, ry: h / 2 });
        }
        if (shape === 'umlEntity') {
            return el('ellipse', { cx: w / 2, cy: h / 2, rx: w / 2, ry: h / 2 });
        }
        if (shape === 'umlControl') {
            return el('ellipse', { cx: w / 2, cy: h / 8 + (h * 7 / 8) / 2,
                rx: w / 2, ry: (h * 7 / 8) / 2 });
        }
        if (shape === 'umlDestroy') {
            return el('path', { d: 'M ' + w + ' 0 L 0 ' + h + ' M 0 0 L ' + w + ' ' + h });
        }
        if (shape === 'umlLifeline') {
            var lifelineHead = Math.max(0, Math.min(h,
                node.shapeSize == null ? 40 : Number(node.shapeSize)));
            return el('rect', { x: 0, y: 0, width: w, height: lifelineHead });
        }
        if (shape === 'umlFrame' || shape === 'message') {
            return el('rect', { x: 0, y: 0, width: w, height: h });
        }
        if (shape === 'umlState') {
            var stateArc = node.radius == null ? 10 : node.radius;
            return el('rect', { x: 0, y: 0, width: w, height: h, rx: stateArc, ry: stateArc });
        }
        if (shape === 'module' || shape === 'component') {
            var jw = Number(node.jettyWidth) || (shape === 'module' ? 20 : 32);
            var jh = Number(node.jettyHeight) || (shape === 'module' ? 12 : 12);
            var jx = jw / 2;
            var ja = shape === 'module' ? Math.min(jh, h - jh) : .3 * h - jh / 2;
            var jb = shape === 'module' ? Math.min(ja + 2 * jh, h - jh) : .7 * h - jh / 2;
            return el('polygon', { points: points([
                { x: jx, y: 0 }, { x: w, y: 0 }, { x: w, y: h }, { x: jx, y: h },
                { x: jx, y: jb + jh }, { x: 0, y: jb + jh }, { x: 0, y: jb }, { x: jx, y: jb },
                { x: jx, y: ja + jh }, { x: 0, y: ja + jh }, { x: 0, y: ja }, { x: jx, y: ja }
            ]) });
        }
        if (shape === 'folder') {
            var tabW = Math.max(0, Math.min(w, node.tabWidth == null ? 60 : Number(node.tabWidth)));
            var tabH = Math.max(0, Math.min(h, node.tabHeight == null ? 20 : Number(node.tabHeight)));
            return el('polygon', { points: node.tabPosition === 'left' ? points([
                { x: 0, y: 0 }, { x: tabW, y: 0 }, { x: tabW, y: tabH },
                { x: w, y: tabH }, { x: w, y: h }, { x: 0, y: h }
            ]) : points([
                { x: w - tabW, y: 0 }, { x: w, y: 0 }, { x: w, y: h },
                { x: 0, y: h }, { x: 0, y: tabH }, { x: w - tabW, y: tabH }
            ]) });
        }
        if (shape === 'providedRequiredInterface') {
            var pri = (node.inset == null ? 2 : Number(node.inset)) +
                (node.strokeWidth == null ? 1 : node.strokeWidth);
            var priW = Math.max(0, w - 2 * pri);
            var priH = Math.max(0, h - 2 * pri);
            return el('ellipse', { cx: priW / 2, cy: pri + priH / 2, rx: priW / 2, ry: priH / 2 });
        }
        if (shape === 'requiredInterface') {
            return el('path', { d: 'M 0 0 Q ' + w + ' 0 ' + w + ' ' + (h / 2) +
                ' Q ' + w + ' ' + h + ' 0 ' + h });
        }
        if (shape === 'endState' || shape === 'startState') {
            var si = shape === 'endState' ? Math.min(4, Math.min(w / 5, h / 5)) : 0;
            return el('ellipse', { cx: w / 2, cy: h / 2,
                rx: Math.max(0, w / 2 - si), ry: Math.max(0, h / 2 - si) });
        }
        if (shape === 'parallelMarker') {
            var bw = w / 5;
            return el('path', { d:
                'M 0 0 h ' + bw + ' v ' + h + ' h ' + (-bw) + ' Z ' +
                'M ' + (2 * bw) + ' 0 h ' + bw + ' v ' + h + ' h ' + (-bw) + ' Z ' +
                'M ' + (4 * bw) + ' 0 h ' + bw + ' v ' + h + ' h ' + (-bw) + ' Z' });
        }
        if (shape === 'card') {
            var cardSize = Math.max(0, Math.min(w, node.shapeSize == null ? 30 : Number(node.shapeSize)));
            var cardDrop = Math.max(0, Math.min(h, node.dy == null ? cardSize : Number(node.dy)));
            return el('polygon', { points: cardSize + ',0 ' + w + ',0 ' + w + ',' + h +
                ' 0,' + h + ' 0,' + cardDrop });
        }
        if (shape === 'dataStorage') {
            var storageSize = w * Math.max(0, Math.min(1,
                node.shapeSize == null ? .1 : Number(node.shapeSize)));
            return el('path', { d: 'M ' + storageSize + ' 0 L ' + w + ' 0' +
                ' Q ' + (w - storageSize * 2) + ' ' + (h / 2) + ' ' + w + ' ' + h +
                ' L ' + storageSize + ' ' + h +
                ' Q ' + (-storageSize) + ' ' + (h / 2) + ' ' + storageSize + ' 0 Z' });
        }
        if (shape === 'xor' || shape === 'or') {
            return el('path', { d: 'M 0 0 Q ' + w + ' 0 ' + w + ' ' + (h / 2) +
                ' Q ' + w + ' ' + h + ' 0 ' + h +
                (shape === 'xor' ? ' Q ' + (w / 2) + ' ' + (h / 2) + ' 0 0' : '') + ' Z' });
        }
        if (shape === 'text') {
            return null;
        }

        return el('rect', {
            x: 0, y: 0, width: w, height: h,
            rx: Math.max(0, radius), ry: Math.max(0, radius)
        });
    }

    /* Extra strokes that sit on top of the outline. */
    function decorations(node) {
        var extras = [];
        var w = node.width;
        var h = node.height;

        if (node.shape === 'table') {
            var rows = Math.max(1, node.rows || 3);
            var columns = Math.max(1, node.columns || 3);
            var title = node.tableTitle == null ? 0 : Math.max(0,
                Math.min(h, Number(node.tableTitleHeight) || 30));
            var available = h - title;
            var rowWeights = Array.isArray(node.rowWeights) && node.rowWeights.length === rows ?
                node.rowWeights : new Array(rows).fill(1);
            var columnWeights = Array.isArray(node.columnWeights) && node.columnWeights.length === columns ?
                node.columnWeights : new Array(columns).fill(1);
            var rowTotal = rowWeights.reduce(function(sum, value) { return sum + Number(value || 0); }, 0) || rows;
            var columnTotal = columnWeights.reduce(function(sum, value) { return sum + Number(value || 0); }, 0) || columns;
            if (title > 0) extras.push(el('line', { x1: 0, y1: title, x2: w, y2: title }));
            var rowY = title;
            for (var r = 0; r < rows - 1; r++) {
                rowY += node.fixedRows ? Number(rowWeights[r]) || 1 : available * rowWeights[r] / rowTotal;
                if (node.rowLines !== false || (node.firstRowLine && r === 0)) {
                    extras.push(el('line', { x1: 0, y1: rowY, x2: w, y2: rowY }));
                }
            }
            var columnX = 0;
            var contentBottom = node.fixedRows ? Math.min(h, title + rowTotal) : h;
            for (var c = 0; c < columns - 1; c++) {
                columnX += w * columnWeights[c] / columnTotal;
                extras.push(el('line', { x1: columnX, y1: title, x2: columnX, y2: contentBottom }));
            }
        }

        if (node.double && (node.shape === 'rect' || node.shape === 'ellipse')) {
            var inset = Math.min(5, Math.min(w, h) / 6);
            extras.push(node.shape === 'ellipse' ? el('ellipse', {
                cx: w / 2, cy: h / 2, rx: Math.max(0, w / 2 - inset), ry: Math.max(0, h / 2 - inset)
            }) : el('rect', {
                x: inset, y: inset, width: Math.max(0, w - 2 * inset), height: Math.max(0, h - 2 * inset),
                rx: Math.max(0, (node.radius || 0) - inset / 2), ry: Math.max(0, (node.radius || 0) - inset / 2)
            }));
        }

        if (node.shape === 'swimlane') {
            var header = Math.min(node.headerHeight || 26, h);
            extras.push(el('line', { x1: 0, y1: header, x2: w, y2: header }));
        } else if (node.shape === 'tapeData') {
            extras.push(el('line', { x1: w / 2, y1: h, x2: w, y2: h }));
        } else if (node.shape === 'isoCube2') {
            var cubeAngle = Math.max(.01, Math.min(94,
                node.isoAngle == null ? 15 : Number(node.isoAngle))) * Math.PI / 200;
            var cubeHeight = Math.min(w * Math.tan(cubeAngle), h * .5);
            extras.push(el('path', { d: 'M 0 ' + cubeHeight + ' L ' + (w / 2) + ' ' +
                (2 * cubeHeight) + ' L ' + w + ' ' + cubeHeight + ' M ' + (w / 2) + ' ' +
                (2 * cubeHeight) + ' L ' + (w / 2) + ' ' + h }));
        } else if (node.shape === 'orEllipse') {
            extras.push(el('line', { x1: 0, y1: h / 2, x2: w, y2: h / 2 }));
            extras.push(el('line', { x1: w / 2, y1: 0, x2: w / 2, y2: h }));
        } else if (node.shape === 'sumEllipse') {
            extras.push(el('line', { x1: w * .145, y1: h * .145, x2: w * .855, y2: h * .855 }));
            extras.push(el('line', { x1: w * .855, y1: h * .145, x2: w * .145, y2: h * .855 }));
        } else if (node.shape === 'lineEllipse') {
            extras.push(node.line === 'vertical' ? el('line', { x1: w / 2, y1: 0, x2: w / 2, y2: h }) :
                el('line', { x1: 0, y1: h / 2, x2: w, y2: h / 2 }));
        } else if (node.shape === 'sortShape') {
            extras.push(el('line', { x1: 0, y1: h / 2, x2: w, y2: h / 2 }));
        } else if (node.shape === 'datastore') {
            var cap = Math.min(h / 2, Math.round(h / 8) + (node.strokeWidth || 1) - 1);
            for (var row = 1; row <= 3; row++) {
                var yy = cap * row / 2;
                extras.push(el('path', { d: 'M 0 ' + yy + ' C 0 ' + (yy + cap) + ' ' + w + ' ' + (yy + cap) + ' ' + w + ' ' + yy }));
            }
        } else if (node.shape === 'umlBoundary') {
            extras.push(el('line', { x1: 0, y1: h / 4, x2: 0, y2: h * 3 / 4 }));
            extras.push(el('line', { x1: 0, y1: h / 2, x2: w / 6, y2: h / 2 }));
        } else if (node.shape === 'umlEntity') {
            extras.push(el('line', { x1: w / 8, y1: h, x2: w * 7 / 8, y2: h }));
        } else if (node.shape === 'umlControl') {
            extras.push(el('line', { x1: w * 3 / 8, y1: h / 8 * 1.1, x2: w * 5 / 8, y2: 0 }));
            extras.push(el('line', { x1: w * 3 / 8, y1: h / 8 * 1.1, x2: w * 5 / 8, y2: h / 4 }));
        } else if (node.shape === 'umlLifeline') {
            var head = Math.max(0, Math.min(h, node.shapeSize == null ? 40 : Number(node.shapeSize)));
            if (head < h) {
                extras.push(el('line', { x1: w / 2, y1: head, x2: w / 2, y2: h,
                    'stroke-dasharray': '4 4' }));
            }
        } else if (node.shape === 'umlFrame') {
            var fw = Math.min(w, Math.max(10, node.frameWidth == null ? 60 : Number(node.frameWidth)));
            var fh = Math.min(h, Math.max(15, node.frameHeight == null ? 30 : Number(node.frameHeight)));
            extras.push(el('path', { d: 'M 0 0 L ' + fw + ' 0 L ' + fw + ' ' +
                Math.max(0, fh - 15) + ' L ' + Math.max(0, fw - 10) + ' ' + fh + ' L 0 ' + fh }));
        } else if (node.shape === 'module' || node.shape === 'component') {
            var mjw = Number(node.jettyWidth) || (node.shape === 'module' ? 20 : 32);
            var mjh = Number(node.jettyHeight) || 12;
            var mjx = mjw / 2;
            var mja = node.shape === 'module' ? Math.min(mjh, h - mjh) : .3 * h - mjh / 2;
            var mjb = node.shape === 'module' ? Math.min(mja + 2 * mjh, h - mjh) : .7 * h - mjh / 2;
            extras.push(el('rect', { x: 0, y: mja, width: mjx, height: mjh, fill: node.fill || '#ffffff' }));
            extras.push(el('rect', { x: 0, y: mjb, width: mjx, height: mjh, fill: node.fill || '#ffffff' }));
        } else if (node.shape === 'providedRequiredInterface') {
            extras.push(el('path', { d: 'M ' + (w / 2) + ' 0 Q ' + w + ' 0 ' + w + ' ' + (h / 2) +
                ' Q ' + w + ' ' + h + ' ' + (w / 2) + ' ' + h }));
        } else if (node.shape === 'endState') {
            extras.push(el('ellipse', { cx: w / 2, cy: h / 2, rx: w / 2, ry: h / 2 }));
        } else if (node.shape === 'message') {
            extras.push(el('path', { d: 'M 0 0 L ' + (w / 2) + ' ' + (h / 2) + ' L ' + w + ' 0' }));
        } else if (node.shape === 'process') {
            var processInset = node.shapeSize == null ? w * .1 :
                (Number(node.shapeSize) > 1 ? Math.min(w / 2, Number(node.shapeSize)) :
                    w * Math.max(0, Math.min(.5, Number(node.shapeSize))));
            extras.push(el('line', { x1: processInset, y1: 0, x2: processInset, y2: h }));
            extras.push(el('line', { x1: w - processInset, y1: 0, x2: w - processInset, y2: h }));
        } else if (node.shape === 'internalStorage') {
            var storeDx = Math.max(0, Math.min(w, node.dx == null ? 20 : Number(node.dx)));
            var storeDy = Math.max(0, Math.min(h, node.dy == null ? 20 : Number(node.dy)));
            extras.push(el('line', { x1: 0, y1: storeDy, x2: w, y2: storeDy }));
            extras.push(el('line', { x1: storeDx, y1: 0, x2: storeDx, y2: h }));
        } else if (node.shape === 'partialRectangle') {
            if (node.top !== false) extras.push(el('line', { x1: 0, y1: 0, x2: w, y2: 0 }));
            if (node.right !== false) extras.push(el('line', { x1: w, y1: 0, x2: w, y2: h }));
            if (node.bottom !== false) extras.push(el('line', { x1: w, y1: h, x2: 0, y2: h }));
            if (node.left !== false) extras.push(el('line', { x1: 0, y1: h, x2: 0, y2: 0 }));
        }

        return extras;
    }

    /* Renders a stencil program into SVG paths with the same state semantics as
       PixelStencils.run. */
    function stencilPaths(node, stroke, fill) {
        var stencil = root.PixelStencils && root.PixelStencils.get(node.stencil);
        if (stencil == null) return null;

        var group = el('g', {});
        var scaleX = node.width / stencil.w;
        var scaleY = node.height / stencil.h;
        var offsetX = 0;
        var offsetY = 0;
        if (stencil.aspect === 'fixed') {
            var uniform = Math.min(scaleX, scaleY);
            offsetX = (node.width - stencil.w * uniform) / 2;
            offsetY = (node.height - stencil.h * uniform) / 2;
            scaleX = uniform;
            scaleY = uniform;
        }
        group.setAttribute('transform', 'translate(' + offsetX + ',' + offsetY + ') scale(' + scaleX + ',' + scaleY + ')');

        function emit(ops) {
            var d = '';
            var current = {
                fill: fill, stroke: stroke,
                strokeWidth: node.strokeWidth || 1,
                alpha: 1, dashed: false, dashPattern: null,
                lineJoin: 'miter', lineCap: 'butt', miterLimit: 10
            };
            var stack = [];

            function paintAttributes(kind) {
                var attrs = {
                    fill: kind === 'stroke' ? 'none' : current.fill,
                    stroke: kind === 'fill' ? 'none' : current.stroke,
                    'stroke-width': current.strokeWidth,
                    'stroke-linejoin': current.lineJoin,
                    'stroke-linecap': current.lineCap,
                    'stroke-miterlimit': current.miterLimit,
                    opacity: current.alpha,
                    'vector-effect': 'non-scaling-stroke'
                };
                if (current.dashed) attrs['stroke-dasharray'] = (current.dashPattern || [4, 4]).join(' ');
                return attrs;
            }

            for (var i = 0; i < ops.length; i++) {
                var op = ops[i];
                switch (op.op) {
                    case 'begin': d = ''; break;
                    case 'move': d += 'M ' + op.x + ' ' + op.y + ' '; break;
                    case 'line': d += 'L ' + op.x + ' ' + op.y + ' '; break;
                    case 'quad': d += 'Q ' + op.x1 + ' ' + op.y1 + ' ' + op.x + ' ' + op.y + ' '; break;
                    case 'curve': d += 'C ' + op.x1 + ' ' + op.y1 + ' ' + op.x2 + ' ' + op.y2 + ' ' + op.x + ' ' + op.y + ' '; break;
                    case 'arc': d += 'A ' + op.rx + ' ' + op.ry + ' ' + (op.rotation || 0) + ' ' + (op.large ? 1 : 0) + ' ' + (op.sweep ? 1 : 0) + ' ' + op.x + ' ' + op.y + ' '; break;
                    case 'close': d += 'Z '; break;
                    case 'rect':
                        d = 'M ' + op.x + ' ' + op.y +
                            ' H ' + (op.x + op.w) +
                            ' V ' + (op.y + op.h) +
                            ' H ' + op.x + ' Z';
                        break;
                    case 'roundrect':
                        var radius = Math.min(op.w, op.h) * (op.arcsize / 100);
                        radius = Math.min(radius, op.w / 2, op.h / 2);
                        d = 'M ' + (op.x + radius) + ' ' + op.y +
                            ' H ' + (op.x + op.w - radius) +
                            ' A ' + radius + ' ' + radius + ' 0 0 1 ' +
                                (op.x + op.w) + ' ' + (op.y + radius) +
                            ' V ' + (op.y + op.h - radius) +
                            ' A ' + radius + ' ' + radius + ' 0 0 1 ' +
                                (op.x + op.w - radius) + ' ' + (op.y + op.h) +
                            ' H ' + (op.x + radius) +
                            ' A ' + radius + ' ' + radius + ' 0 0 1 ' +
                                op.x + ' ' + (op.y + op.h - radius) +
                            ' V ' + (op.y + radius) +
                            ' A ' + radius + ' ' + radius + ' 0 0 1 ' +
                                (op.x + radius) + ' ' + op.y + ' Z';
                        break;
                    case 'ellipse':
                        var rx = op.w / 2;
                        var ry = op.h / 2;
                        var cx = op.x + rx;
                        var cy = op.y + ry;
                        d = 'M ' + (cx - rx) + ' ' + cy +
                            ' A ' + rx + ' ' + ry + ' 0 1 0 ' + (cx + rx) + ' ' + cy +
                            ' A ' + rx + ' ' + ry + ' 0 1 0 ' + (cx - rx) + ' ' + cy + ' Z';
                        break;
                    case 'fillcolor': current.fill = op.color === 'none' ? 'none' : op.color; break;
                    case 'strokecolor': current.stroke = op.color === 'none' ? 'none' : op.color; break;
                    case 'strokewidth': current.strokeWidth = op.width === 'inherit' ? (node.strokeWidth || 1) : (parseFloat(op.width) || 1); break;
                    case 'alpha': current.alpha = op.alpha; break;
                    case 'dashed': current.dashed = op.on; break;
                    case 'dashpattern': current.dashPattern = op.pattern; break;
                    case 'linejoin': current.lineJoin = op.join; break;
                    case 'linecap': current.lineCap = op.cap; break;
                    case 'miterlimit': current.miterLimit = op.limit; break;
                    case 'save': stack.push(Object.assign({}, current, { dashPattern: current.dashPattern && current.dashPattern.slice() })); break;
                    case 'restore': if (stack.length) current = stack.pop(); break;
                    case 'fill':
                    case 'stroke':
                    case 'fillstroke':
                        if (d !== '') group.appendChild(el('path', Object.assign({ d: d.trim() }, paintAttributes(op.op))));
                        d = '';
                        break;
                    default: break;
                }
            }
        }

        emit(stencil.background.concat(stencil.foreground));
        return group;
    }

    function arrowMarker(defs, id, colour, kind) {
        if (kind === 'none') return null;
        var marker = el('marker', {
            id: id, viewBox: '0 0 10 10', refX: 9, refY: 5,
            markerWidth: 6, markerHeight: 6, orient: 'auto-start-reverse'
        });

        if (kind === 'oval') {
            marker.appendChild(el('circle', { cx: 5, cy: 5, r: 4, fill: colour }));
        } else if (kind === 'diamond') {
            marker.appendChild(el('polygon', { points: '0,5 5,0 10,5 5,10', fill: colour }));
        } else if (kind === 'open') {
            marker.appendChild(el('path', {
                d: 'M 0 0 L 10 5 L 0 10', fill: 'none', stroke: colour, 'stroke-width': 1.6
            }));
        } else {
            marker.appendChild(el('polygon', { points: '0,0 10,5 0,10', fill: colour }));
        }

        defs.appendChild(marker);
        return id;
    }

    var uid = 0;

    /* Builds an <svg> preview fitted into the compact old-sidebar box. */
    function preview(template, boxWidth, boxHeight, source) {
        if (template == null) return null;
        boxWidth = boxWidth || 32;
        boxHeight = boxHeight || boxWidth;

        var svg = el('svg', {
            width: boxWidth, height: boxHeight,
            viewBox: '0 0 ' + boxWidth + ' ' + boxHeight,
            xmlns: NS, 'shape-rendering': 'geometricPrecision'
        });
        var defs = el('defs', {});
        svg.appendChild(defs);

        var stroke = (template.stroke && template.stroke !== 'transparent') ? template.stroke : '#4a5564';
        var fill = (template.fill && template.fill !== 'transparent') ? template.fill : 'none';
        var inset = 4;

        if (template.type === 'edge') {
            var colour = stroke;
            var id = 'pm' + (++uid);
            var start = arrowMarker(defs, id + 's', colour, template.startArrow || 'none');
            var end = arrowMarker(defs, id + 'e', colour, template.endArrow || 'block');
            var line = el('line', {
                x1: inset, y1: boxHeight - inset, x2: boxWidth - inset, y2: inset,
                stroke: colour,
                'stroke-width': Math.max(1.2, Math.min(2.5, template.strokeWidth || 1.5)),
                'stroke-linecap': 'round'
            });
            if (template.dashed) {
                line.setAttribute('stroke-dasharray',
                    (template.dashPattern || [4, 3]).join(' '));
            }
            if (start) line.setAttribute('marker-start', 'url(#' + start + ')');
            if (end) line.setAttribute('marker-end', 'url(#' + end + ')');
            svg.appendChild(line);
            return svg;
        }

        var node = {
            shape: template.shape || 'rect',
            stencil: template.stencil,
            width: Math.max(1, template.width || 120),
            height: Math.max(1, template.height || 60),
            radius: template.radius,
            rows: template.rows, columns: template.columns,
            headerHeight: template.headerHeight,
            direction: template.direction,
            line: template.line,
            arrowSize: template.arrowSize,
            arrowWidth: template.arrowWidth,
            shapeSize: template.shapeSize,
            strokeWidth: template.strokeWidth,
            top: template.top, right: template.right,
            bottom: template.bottom, left: template.left
        };

        var scale = Math.min((boxWidth - inset * 2) / node.width,
            (boxHeight - inset * 2) / node.height);
        var group = el('g', {
            transform: 'translate(' + ((boxWidth - node.width * scale) / 2) + ',' +
                ((boxHeight - node.height * scale) / 2) + ') scale(' + scale + ')',
            // The outline must not thin out when the shape is scaled down.
            'vector-effect': 'non-scaling-stroke'
        });

        if (node.shape === 'stencil') {
            var stencilGroup = stencilPaths(node, stroke, fill);
            if (stencilGroup != null) {
                stencilGroup.setAttribute('vector-effect', 'non-scaling-stroke');
                group.appendChild(stencilGroup);
                svg.appendChild(group);
                return svg;
            }
        }

        if (node.shape === 'image') {
            group.appendChild(el('rect', {
                x: 0, y: 0, width: node.width, height: node.height,
                fill: '#eef1f5', stroke: '#b6bec9', 'stroke-width': 1,
                'vector-effect': 'non-scaling-stroke'
            }));
            group.appendChild(el('path', {
                d: 'M ' + (node.width * .15) + ' ' + (node.height * .75) +
                   ' L ' + (node.width * .4) + ' ' + (node.height * .4) +
                   ' L ' + (node.width * .6) + ' ' + (node.height * .62) +
                   ' L ' + (node.width * .75) + ' ' + (node.height * .5) +
                   ' L ' + (node.width * .88) + ' ' + (node.height * .75) + ' Z',
                fill: '#9aa4b2', stroke: 'none'
            }));
            svg.appendChild(group);
            return svg;
        }

        var body = outline(node);
        if (body != null) {
            body.setAttribute('fill', node.shape === 'parallelMarker' ? stroke :
                (STROKE_ONLY_SHAPES[node.shape] ? 'none' : fill));
            body.setAttribute('stroke', node.shape === 'partialRectangle' ? 'none' : stroke);
            body.setAttribute('stroke-width', Math.max(1, template.strokeWidth || 1.5));
            body.setAttribute('stroke-linejoin', 'round');
            body.setAttribute('vector-effect', 'non-scaling-stroke');
            group.appendChild(body);
        }

        decorations(node).forEach(function(extra) {
            extra.setAttribute('stroke', stroke);
            extra.setAttribute('stroke-width', 1);
            // A decoration that already chose its own fill (the module and
            // component jetties sit over cut-outs in the body) keeps it.
            if (!extra.hasAttribute('fill')) extra.setAttribute('fill', 'none');
            extra.setAttribute('vector-effect', 'non-scaling-stroke');
            group.appendChild(extra);
        });

        if (node.shape === 'table' && node.tableTitle != null) {
            var titleLabel = el('text', {
                x: node.width / 2,
                y: Math.max(1, Number(node.tableTitleHeight) || 30) / 2,
                'text-anchor': 'middle', 'dominant-baseline': 'central',
                'font-family': 'Arial, Helvetica, sans-serif', 'font-size': 11,
                'font-weight': 700, fill: template.textColor || '#172033'
            });
            titleLabel.textContent = node.tableTitle;
            group.appendChild(titleLabel);
        }

        // Text/HTML inventory entries keep their real DOM content. This is
        // particularly important for lists and tables, whose bullets, numbers,
        // rows and inline formatting cannot be represented by a canvas glyph.
        var markup = htmlValue(template, source);
        if (template.kind === 'visualScript') {
            addVisualScriptCard(group, node, template);
        } else if (markup != null && (node.shape === 'text' || node.shape === 'html' || body == null)) {
            addHtmlLabel(group, node, template, markup);
        } else if (node.shape === 'text' || body == null) {
            var label = el('text', {
                x: node.width / 2, y: node.height / 2,
                'text-anchor': 'middle', 'dominant-baseline': 'central',
                'font-family': 'Arial, Helvetica, sans-serif',
                'font-size': Math.min(node.height * .8, node.width * .5),
                'font-weight': template.fontWeight || 400,
                fill: template.textColor || '#172033'
            });
            label.textContent = template.text || (source && source.value) || 'Text';
            group.appendChild(label);
        }

        svg.appendChild(group);
        return svg;
    }

    root.PixelShapeSvg = { preview: preview, outline: outline };
})(typeof window !== 'undefined' ? window : this);
