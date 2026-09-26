/*
 * .qochart (mxGraphModel XML) support for the canvas editor.
 *
 * Reading reuses Editor.importLegacyGraph, which already handles mxfile
 * wrappers, nested cell geometry and the style vocabulary. This module adds
 * the two things that were missing for a server round trip:
 *
 *   1. round-trip metadata -- every imported item keeps the original cell
 *      under `mx`, including any custom wrapper element (for example
 *      <VisualScript code="..." vsType="..."> around an <mxCell>). Those
 *      wrappers carry application data this editor does not model, and
 *      dropping them on save would silently destroy it.
 *   2. a writer, so an edited diagram can go back to the server as .qochart.
 */
(function(root) {
    'use strict';

    /* mxGraph fontStyle is a bitmask. */
    var FONT_BOLD = 1;
    var FONT_ITALIC = 2;
    var FONT_UNDERLINE = 4;
    var FONT_STRIKE = 8;

    /* Canvas shape -> classic mxGraph shape name.
       Every shape the painter can draw needs an entry here. A shape that is
       missing is written with no shape information at all, so the document
       reloads it as a plain rectangle -- which is how the whole Advanced
       palette (loop limit, manual input, off-page connector, the arrows,
       cross/corner/tee, the divided ellipses, sort, collate, switch, ...)
       used to be flattened into squares on the first save. */
    var SHAPE_OUT = {
        rect: 'rectangle', ellipse: 'ellipse', diamond: 'rhombus',
        triangle: 'triangle', hexagon: 'hexagon', parallelogram: 'parallelogram',
        trapezoid: 'trapezoid', cylinder: 'cylinder3', cloud: 'cloud',
        document: 'document', note: 'note', cube: 'cube', actor: 'actor',
        step: 'step', delay: 'delay', swimlane: 'swimlane', table: 'table',
        image: 'image', text: 'text', speech: 'callout', plus: 'plus',
        chevron: 'step', blockArrow: 'singleArrow', html: 'rectangle',
        isoCube2: 'isoCube2', isoRectangle: 'isoRectangle',

        // Advanced palette and the remaining General/Misc shapes.
        manualInput: 'manualInput', loopLimit: 'loopLimit',
        offPageConnector: 'offPageConnector', display: 'display',
        singleArrow: 'singleArrow', doubleArrow: 'doubleArrow',
        cross: 'cross', corner: 'corner', tee: 'tee', datastore: 'datastore',
        tapeData: 'tapeData', orEllipse: 'orEllipse', sumEllipse: 'sumEllipse',
        lineEllipse: 'lineEllipse', sortShape: 'sortShape', collate: 'collate',
        'switch': 'switch', card: 'card', tape: 'tape', process: 'process',
        internalStorage: 'internalStorage', dataStorage: 'dataStorage',
        xor: 'xor', or: 'or', line: 'line', curlyBracket: 'curlyBracket',
        crossbar: 'crossbar', partialRectangle: 'partialRectangle',

        // UML and BPMN.
        umlBoundary: 'umlBoundary', umlEntity: 'umlEntity',
        umlControl: 'umlControl', umlDestroy: 'umlDestroy',
        umlLifeline: 'umlLifeline', umlFrame: 'umlFrame', umlState: 'umlState',
        module: 'module', component: 'component', folder: 'folder',
        providedRequiredInterface: 'providedRequiredInterface',
        requiredInterface: 'requiredInterface',
        endState: 'endState', startState: 'startState',
        message: 'message', parallelMarker: 'parallelMarker'
    };

    /* mxGraph names these as a bare style name rather than as shape=NAME. */
    var SHAPE_TOKEN_OUT = {
        rectangle: true, ellipse: true, rhombus: true, triangle: true,
        text: true, line: true, swimlane: true, image: true
    };

    var ARROW_OUT = {
        none: 'none', classic: 'classic', block: 'block', open: 'open',
        oval: 'oval', diamond: 'diamond'
    };

    function decodeStyle(style) {
        var result = { shapeTokens: [] };
        String(style == null ? '' : style).split(';').forEach(function(part) {
            if (part === '') return;
            var index = part.indexOf('=');
            if (index < 0) result.shapeTokens.push(part);
            else result[part.substring(0, index)] = part.substring(index + 1);
        });
        return result;
    }

    function encodeStyle(style) {
        var parts = (style.shapeTokens || []).slice();
        Object.keys(style).forEach(function(key) {
            if (key === 'shapeTokens' || style[key] == null || style[key] === '') return;
            parts.push(key + '=' + style[key]);
        });
        return parts.join(';') + (parts.length ? ';' : '');
    }

    function colorOut(value) {
        if (value == null) return null;
        return (value === 'transparent' || value === 'rgba(0,0,0,0)') ? 'none' : value;
    }

    function escapeAttr(value) {
        return String(value == null ? '' : value)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/\n/g, '&#10;');
    }

    function numberOut(value) {
        value = Number(value) || 0;
        return String(Math.round(value * 1000) / 1000);
    }

    function looksLikeXml(text) {
        return /^\s*(<\?xml|<mxGraphModel|<mxfile|<!--|<!DOCTYPE)/i.test(String(text || ''));
    }

    function encodedJson(value) {
        try { return encodeURIComponent(JSON.stringify(value)); }
        catch (error) { return null; }
    }

    function decodedJson(value, fallback) {
        if (value == null || value === '') return fallback;
        try { return JSON.parse(decodeURIComponent(value)); }
        catch (error) { return fallback; }
    }

    /* Runtime-only canvas metadata has no native mxGraph equivalent. Keep it
       in namespaced style keys so server .qochart files remain valid classic
       mxGraph documents while round-tripping groups and exact paint order. */
    function writeRuntimeStyle(style, item) {
        var groups = Array.isArray(item.groups) ? item.groups :
            (item.groupId ? [item.groupId] : []);
        style.qochartGroups = groups.length ? encodedJson(groups) : null;
        style.qochartZ = isFinite(Number(item.z)) ? Number(item.z) : 0;
        style.qochartLayer = item.layer == null ? null : encodeURIComponent(item.layer);
        style.qochartContainerRole = item.containerRole || null;
        style.qochartKind = ['container', 'list', 'listItem', 'taskList'].indexOf(item.kind) >= 0 ?
            item.kind : null;
    }

    function readRuntimeStyle(item, style) {
        var groups = decodedJson(style.qochartGroups, null);
        if (Array.isArray(groups) && groups.length > 0) {
            item.groups = groups.map(String);
            item.groupId = item.groups[0];
        } else {
            delete item.groups;
            delete item.groupId;
        }
        if (style.qochartZ != null && isFinite(Number(style.qochartZ))) {
            item.z = Number(style.qochartZ);
        }
        if (style.qochartLayer) {
            try { item.layer = decodeURIComponent(style.qochartLayer); }
            catch (error) { item.layer = style.qochartLayer; }
        }
        if (style.qochartContainerRole) item.containerRole = style.qochartContainerRole;
        if (style.qochartKind) item.kind = style.qochartKind;
    }

    /* ------------------------------------------------------------------ */
    /* Reading                                                             */
    /* ------------------------------------------------------------------ */

    /* Collects the original XML for each cell, keyed by id. */
    function collectCells(text) {
        var records = Object.create(null);
        if (typeof DOMParser === 'undefined') return records;

        var doc = new DOMParser().parseFromString(String(text || ''), 'application/xml');
        if (doc.getElementsByTagName('parsererror').length > 0) return records;

        var cells = doc.getElementsByTagName('mxCell');

        for (var i = 0; i < cells.length; i++) {
            var cell = cells[i];
            if (cell.getAttribute('vertex') !== '1' && cell.getAttribute('edge') !== '1') continue;

            var wrapper = cell.parentNode;
            var wrapped = wrapper != null && wrapper.nodeType === 1 &&
                wrapper.nodeName !== 'root' && wrapper.nodeName !== 'mxGraphModel';
            var id = (wrapped ? wrapper.getAttribute('id') : null) || cell.getAttribute('id');
            if (!id) continue;

            var record = {
                id: id,
                parent: cell.getAttribute('parent') || '1',
                style: cell.getAttribute('style') || '',
                wrapperTag: wrapped ? wrapper.nodeName : null,
                wrapperAttrs: null,
                link: wrapped ? wrapper.getAttribute('link') : cell.getAttribute('link')
            };

            if (wrapped) {
                record.wrapperAttrs = {};
                for (var w = 0; w < wrapper.attributes.length; w++) {
                    record.wrapperAttrs[wrapper.attributes[w].name] = wrapper.attributes[w].value;
                }
            }

            records[id] = record;
        }

        return records;
    }

    /* Parses a .qochart into a pixel document, keeping round-trip metadata. */
    function parse(text) {
        var importer = root.Editor && root.Editor.importLegacyGraph;
        if (typeof importer !== 'function') {
            throw new Error('The mxGraph importer is not loaded');
        }

        var documentData = importer(text);
        var records = collectCells(text);

        (documentData.items || []).forEach(function(item) {
            var record = records[item.id];
            if (record == null) return;
            item.mx = record;

            // Restore the properties the base importer does not know about.
            var style = decodeStyle(record.style);
            // Prefer the exact canvas shape when this file was written here.
            // Tables and stencils resolve their own shape during import and
            // must not be overwritten.
            if (style.qochartShape && item.shape !== 'table' && item.shape !== 'stencil' &&
                item.sourceType !== 'htmlTable' && item.kind !== 'table') {
                item.shape = style.qochartShape;
            }
            if (style.cscript) {
                try { item.cscript = decodeURIComponent(style.cscript); } catch (error) { /* keep none */ }
            }
            if (style.bookmark === '1') item.bookmark = true;
            if (record.link) item.link = record.link;
            if (style.imageFit) item.imageFit = style.imageFit;
            if (style.imageAlign) item.imageAlign = style.imageAlign;
            if (style.imageVerticalAlign) item.imageVerticalAlign = style.imageVerticalAlign;
            if (style.imageOpacity != null) item.imageOpacity = parseFloat(style.imageOpacity) / 100;
            if (style.mediaType) item.mediaType = style.mediaType;
            if (style.mediaLoop != null) item.mediaLoop = style.mediaLoop !== '0';
            if (style.mediaVolume != null) item.mediaVolume = Math.max(0,
                Math.min(1, Number(style.mediaVolume) / 100));
            var mediaLayers = decodedJson(style.mediaLayers, null);
            if (Array.isArray(mediaLayers) && mediaLayers.length > 0) {
                item.mediaLayers = mediaLayers.filter(function(layer) {
                    return layer && typeof layer.src === 'string' && layer.src !== '';
                }).map(function(layer) {
                    return {
                        src: layer.src,
                        mediaType: layer.mediaType || '',
                        depth: Math.max(0, Math.min(1, Number(layer.depth) || 0)),
                        opacity: Math.max(0, Math.min(1, layer.opacity == null ? 1 : Number(layer.opacity) || 0)),
                        scrollX: Number(layer.scrollX) || 0,
                        scrollY: Number(layer.scrollY) || 0
                    };
                });
                if (item.mediaLayers.length === 0) delete item.mediaLayers;
            }
            readRuntimeStyle(item, style);
            if (item.type === 'edge') {
                if (style.qochartSourceLabel) {
                    try { item.sourceLabel = decodeURIComponent(style.qochartSourceLabel); }
                    catch (error) { item.sourceLabel = style.qochartSourceLabel; }
                }
                if (style.qochartTargetLabel) {
                    try { item.targetLabel = decodeURIComponent(style.qochartTargetLabel); }
                    catch (error) { item.targetLabel = style.qochartTargetLabel; }
                }
                if (style.qochartEdgeSymbol) item.edgeSymbol = style.qochartEdgeSymbol;
            }
            if (item.type === 'edge' && style.qochartRoute === 'circular') {
                item.lineStyle = 'circular';
                item.route = null;
                item.arcSweep = Math.max(1, Math.min(360, Number(style.arcSweep) || 180));
                item.arcSide = Number(style.arcSide) < 0 ? -1 : 1;
                item.circleRadius = Math.max(5, Number(style.circleRadius) || 60);
            }
        });

        if (typeof DOMParser !== 'undefined') {
            var metadataDocument = new DOMParser().parseFromString(String(text || ''), 'application/xml');
            var model = metadataDocument.getElementsByTagName('mxGraphModel')[0];
            var savedLayers = model ? decodedJson(model.getAttribute('qochartLayers'), null) : null;
            if (Array.isArray(savedLayers) && savedLayers.length > 0) documentData.layers = savedLayers;
        }

        return documentData;
    }

    /* ------------------------------------------------------------------ */
    /* Writing                                                             */
    /* ------------------------------------------------------------------ */

    function nodeToStyle(node) {
        var style = node.mx ? decodeStyle(node.mx.style) : { shapeTokens: [] };

        if (node.shape === 'stencil' && node.stencil) {
            style.shape = node.stencil;
        } else if (node.sourceType !== 'htmlTable' && SHAPE_OUT[node.shape]) {
            var classicShape = SHAPE_OUT[node.shape];
            // Every bare token in an mxGraph style is a style name, and the
            // reader treats the last one it sees as the shape. Keeping a
            // token from the shape this node used to have would beat the
            // shape it has now, so the imported tokens are rewritten rather
            // than merged.
            style.shapeTokens = [];
            if (SHAPE_TOKEN_OUT[classicShape]) {
                style.shapeTokens.push(classicShape);
                delete style.shape;
            } else {
                style.shape = classicShape;
            }
        }

        // The canvas shape name itself. Several canvas shapes share one
        // classic name (chevron/step) and a few have no classic equivalent at
        // all (html), so the classic shape= alone cannot round-trip the
        // drawing exactly. Namespaced like the other qochart* keys, this stays
        // ignorable for any other mxGraph reader.
        style.qochartShape = (node.shape && node.shape !== 'stencil' &&
            node.shape !== 'table' && node.sourceType !== 'htmlTable') ? node.shape : null;

        style.fillColor = colorOut(node.fill);
        style.strokeColor = colorOut(node.stroke);
        style.strokeWidth = node.strokeWidth == null ? null : node.strokeWidth;
        style.fontColor = colorOut(node.textColor);
        style.fontSize = node.fontSize == null ? null : node.fontSize;
        style.fontFamily = node.fontFamily || null;
        style.align = node.textAlign || null;
        style.verticalAlign = node.verticalAlign || null;
        style.opacity = node.opacity == null ? null : Math.round(node.opacity * 100);
        style.shadow = node.shadow ? '1' : null;
        style.dashed = node.dashed ? '1' : null;
        style.dashPattern = (node.dashed && node.dashPattern) ? node.dashPattern.join(' ') : null;
        style.rounded = Number(node.radius) > 0 ? '1' : '0';
        style.arcSize = Number(node.radius) > 0 ? node.radius : null;
        style.gradientColor = node.gradient ? colorOut(node.gradient) : null;
        style.whiteSpace = node.wordWrap === false ? 'nowrap' : 'wrap';
        style.flipH = node.flipH ? '1' : null;
        style.flipV = node.flipV ? '1' : null;
        style.rotation = node.rotation ? node.rotation : null;
        if (node.shape === 'swimlane' || node.kind === 'taskList') {
            style.startSize = node.headerHeight == null ? null : node.headerHeight;
        }
        if (node.shapeSize != null) {
            style.size = node.shape === 'cylinder' ? node.shapeSize * node.height :
                (node.shape === 'cube' || node.shape === 'note' ?
                    node.shapeSize * Math.min(node.width, node.height) : node.shapeSize);
        }
        if (node.shape === 'isoCube2') {
            style.isoAngle = node.isoAngle == null ? 15 : node.isoAngle;
        }
        if (node.shape === 'blockArrow' || node.shape === 'singleArrow' ||
            node.shape === 'doubleArrow') {
            style.arrowSize = node.arrowSize == null ? null : node.arrowSize;
            style.arrowWidth = node.arrowWidth == null ? null : node.arrowWidth;
        }
        // Modifiers that decide what an advanced shape actually looks like:
        // which way an arrow points, which way a divided ellipse is split,
        // which sides a partial rectangle draws, and the internal-storage
        // divider offsets. Without these the shape reloads in its default
        // orientation instead of the one that was saved.
        style.direction = node.direction || null;
        style.line = node.line || null;
        style.double = node.double ? '1' : null;
        style.dx = node.dx == null ? null : node.dx;
        style.dy = node.dy == null ? null : node.dy;
        ['top', 'right', 'bottom', 'left'].forEach(function(side) {
            style[side] = node[side] === false ? '0' : (node[side] === true ? '1' : null);
        });
        // UML/BPMN shape parameters.
        style.jettyWidth = node.jettyWidth == null ? null : node.jettyWidth;
        style.jettyHeight = node.jettyHeight == null ? null : node.jettyHeight;
        style.tabWidth = node.tabWidth == null ? null : node.tabWidth;
        style.tabHeight = node.tabHeight == null ? null : node.tabHeight;
        style.tabPosition = node.tabPosition || null;
        style.inset = node.inset == null ? null : node.inset;
        style.umlStateSymbol = node.umlStateSymbol || null;
        style.participant = node.participant || null;
        if (node.shape === 'umlFrame') {
            style.width = node.frameWidth == null ? null : node.frameWidth;
            style.height = node.frameHeight == null ? null : node.frameHeight;
        }
        if (node.shape === 'image' && node.src) {
            style.image = encodeURIComponent(node.src);
            style.imageFit = node.imageFit || null;
            style.imageAlign = node.imageAlign || null;
            style.imageVerticalAlign = node.imageVerticalAlign || null;
            style.imageOpacity = node.imageOpacity == null ? null : Math.round(node.imageOpacity * 100);
            style.mediaType = node.mediaType || null;
            style.mediaLoop = node.mediaType && /^video\//.test(node.mediaType) ?
                (node.mediaLoop === false ? '0' : '1') : null;
            style.mediaVolume = node.mediaType && /^video\//.test(node.mediaType) ?
                Math.round((node.mediaVolume == null ? 1 : node.mediaVolume) * 100) : null;
            style.mediaLayers = Array.isArray(node.mediaLayers) && node.mediaLayers.length > 0 ?
                encodedJson(node.mediaLayers.filter(function(layer) {
                    return layer && typeof layer.src === 'string' && layer.src !== '';
                }).map(function(layer) {
                    return {
                        src: layer.src,
                        mediaType: layer.mediaType || '',
                        depth: Math.max(0, Math.min(1, Number(layer.depth) || 0)),
                        opacity: Math.max(0, Math.min(1, layer.opacity == null ? 1 : Number(layer.opacity) || 0)),
                        scrollX: Number(layer.scrollX) || 0,
                        scrollY: Number(layer.scrollY) || 0
                    };
                })) : null;
        }
        if (node.richText != null || node.html != null || node.sourceType === 'htmlTable' ||
            node.shape === 'table') style.html = '1';
        // The script travels in the style so it survives a .qochart round trip,
        // unlike the classic hidden-span storage which was lost on save.
        style.cscript = node.cscript ? encodeURIComponent(node.cscript) : null;
        style.bookmark = node.bookmark ? '1' : null;
        style.container = node.container ? '1' : null;
        style.childLayout = node.childLayout || null;
        style.horizontalStack = node.stackHorizontal === true ? '1' :
            (node.stackHorizontal === false ? '0' : null);
        style.stackSpacing = node.stackSpacing == null ? null : node.stackSpacing;
        style.stackBorder = node.stackBorder == null ? null : node.stackBorder;
        style.resizeParent = node.resizeParent === true ? '1' : null;
        style.resizeParentMax = node.resizeParentMax === true ? '1' : null;
        style.resizeLast = node.resizeLast === true ? '1' : null;
        style.allowGaps = node.allowStackGaps === false ? '0' :
            (node.allowStackGaps === true ? '1' : null);
        style.collapsible = node.collapsible === false ? '0' :
            (node.collapsible === true ? '1' : null);
        writeRuntimeStyle(style, node);

        if (node.kind === 'visualScript') {
            style.html = '1';
            style.vsType = node.vsType || (node.visualScript && node.visualScript.vsType) || 'process';
            style.align = 'left';
            style.verticalAlign = 'top';
            style.overflow = 'hidden';
            style.spacing = '0';
            style.editable = '0';
            style.rounded = '1';
            style.arcSize = node.radius == null ? 6 : node.radius;
        }

        var fontStyle = 0;
        if (Number(node.fontWeight) >= 700 || node.bold) fontStyle |= FONT_BOLD;
        if (node.italic) fontStyle |= FONT_ITALIC;
        if (node.underline) fontStyle |= FONT_UNDERLINE;
        if (node.strikethrough) fontStyle |= FONT_STRIKE;
        style.fontStyle = fontStyle > 0 ? fontStyle : null;

        return encodeStyle(style);
    }

    function edgeToStyle(edge) {
        var style = edge.mx ? decodeStyle(edge.mx.style) : { shapeTokens: [] };
        style.edgeStyle = edge.lineStyle === 'straight' || edge.lineStyle === 'circular' ?
            'none' : 'orthogonalEdgeStyle';
        style.curved = edge.lineStyle === 'curved' ? '1' : null;
        style.qochartRoute = edge.lineStyle === 'circular' ? 'circular' : null;
        style.arcSweep = edge.lineStyle === 'circular' ? edge.arcSweep : null;
        style.arcSide = edge.lineStyle === 'circular' ? edge.arcSide : null;
        style.circleRadius = edge.lineStyle === 'circular' ? edge.circleRadius : null;
        style.strokeColor = colorOut(edge.stroke);
        style.strokeWidth = edge.strokeWidth == null ? null : edge.strokeWidth;
        style.dashed = edge.dashed ? '1' : null;
        style.opacity = edge.opacity == null ? null : Math.round(edge.opacity * 100);
        style.startArrow = ARROW_OUT[edge.startArrow] || 'none';
        style.endArrow = ARROW_OUT[edge.endArrow] || 'block';
        style.endSize = edge.arrowSize == null ? null : edge.arrowSize;
        style.fontColor = colorOut(edge.textColor);
        style.fontSize = edge.fontSize == null ? null : edge.fontSize;
        writeRuntimeStyle(style, edge);

        style.qochartSourceLabel = edge.sourceLabel ?
            encodeURIComponent(edge.sourceLabel) : null;
        style.qochartTargetLabel = edge.targetLabel ?
            encodeURIComponent(edge.targetLabel) : null;
        style.qochartEdgeSymbol = edge.edgeSymbol || null;

        if (edge.sourceAnchor) {
            style.exitX = edge.sourceAnchor.x;
            style.exitY = edge.sourceAnchor.y;
        }
        if (edge.targetAnchor) {
            style.entryX = edge.targetAnchor.x;
            style.entryY = edge.targetAnchor.y;
        }

        return encodeStyle(style);
    }

    function escapeHtml(value) {
        return String(value == null ? '' : value).replace(/&/g, '&amp;')
            .replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    function tableHtmlFor(item) {
        var rows = Math.max(1, Number(item.rows) || 1);
        var columns = Math.max(1, Number(item.columns) || 1);
        var rowWeights = Array.isArray(item.rowWeights) && item.rowWeights.length === rows ?
            item.rowWeights : new Array(rows).fill(1);
        var columnWeights = Array.isArray(item.columnWeights) && item.columnWeights.length === columns ?
            item.columnWeights : new Array(columns).fill(1);
        var rowTotal = rowWeights.reduce(function(sum, value) { return sum + (Number(value) || 0); }, 0) || rows;
        var columnTotal = columnWeights.reduce(function(sum, value) { return sum + (Number(value) || 0); }, 0) || columns;
        var border = item.tableBorder == null ? 1 : Math.max(0, Number(item.tableBorder) || 0);
        var padding = item.tableCellPadding == null ? 0 : Math.max(0, Number(item.tableCellPadding) || 0);
        var tableAttrs = '';
        function cellOriginAt(row, column) {
            var cells = item.cells || {};
            var keys = Object.keys(cells);
            for (var i = 0; i < keys.length; i++) {
                var parts = keys[i].split(',');
                var originRow = Number(parts[0]);
                var originColumn = Number(parts[1]);
                var cell = typeof cells[keys[i]] === 'string' ? { text: cells[keys[i]] } : cells[keys[i]] || {};
                var rowspan = Math.max(1, Math.min(rows - originRow, Number(cell.rowspan) || 1));
                var colspan = Math.max(1, Math.min(columns - originColumn, Number(cell.colspan) || 1));
                if (row >= originRow && row < originRow + rowspan &&
                    column >= originColumn && column < originColumn + colspan) {
                    return { row: originRow, column: originColumn, cell: cell,
                        rowspan: rowspan, colspan: colspan };
                }
            }
            return { row: row, column: column, cell: {}, rowspan: 1, colspan: 1 };
        }
        if (item.fixedRows) tableAttrs += ' data-pixel-fixed-rows="1"';
        tableAttrs += ' data-pixel-reorder-rows="' + (item.reorderRows === false ? '0' : '1') + '"';
        if (item.rowIndexColumn != null) tableAttrs += ' data-pixel-row-index-column="' +
            Math.max(0, Number(item.rowIndexColumn) || 0) + '"';
        if (item.rowLines === false) tableAttrs += ' data-pixel-row-lines="0"';
        if (item.firstRowLine) tableAttrs += ' data-pixel-first-row-line="1"';
        var html = '<table border="' + border + '" width="100%" height="100%" cellpadding="' +
            padding + '"' + tableAttrs + ' style="width:100%;height:100%;border-collapse:collapse;">';
        if (item.tableTitle != null) {
            html += '<caption data-pixel-height="' + Math.max(1,
                Number(item.tableTitleHeight) || 30) + '" style="caption-side:top;font-weight:bold;text-align:center;">' +
                escapeHtml(item.tableTitle) + '</caption>';
        }
        html += '<colgroup>';
        for (var c = 0; c < columns; c++) {
            html += '<col style="width:' + Math.round(columnWeights[c] / columnTotal * 10000) / 100 + '%">';
        }
        html += '</colgroup>';

        for (var r = 0; r < rows; r++) {
            html += '<tr style="height:' + (item.fixedRows ?
                (Math.max(1, Number(rowWeights[r]) || 1) + 'px') :
                (Math.round(rowWeights[r] / rowTotal * 10000) / 100 + '%')) + '">';
            for (var column = 0; column < columns;) {
                var origin = cellOriginAt(r, column);
                if (origin.row !== r || origin.column !== column) {
                    column++;
                    continue;
                }
                var cell = origin.cell;
                var span = origin.colspan;
                var rowSpan = origin.rowspan;
                var tag = cell.tag === 'th' || (item.headerRow && r === 0) ? 'th' : 'td';
                var styles = [];
                if (cell.fill) styles.push('background-color:' + cell.fill);
                if (cell.textColor) styles.push('color:' + cell.textColor);
                if (cell.align) styles.push('text-align:' + cell.align);
                if (cell.fontWeight) styles.push('font-weight:' + cell.fontWeight);
                if (cell.fontFamily) styles.push('font-family:' + cell.fontFamily);
                if (cell.fontSize) styles.push('font-size:' + cell.fontSize + 'px');
                if (cell.italic) styles.push('font-style:italic');
                if (cell.underline || cell.strikethrough) styles.push('text-decoration:' +
                    (cell.underline ? 'underline ' : '') + (cell.strikethrough ? 'line-through' : ''));
                if (cell.verticalAlign) styles.push('vertical-align:' + cell.verticalAlign);
                if (cell.opacity != null) styles.push('opacity:' + cell.opacity);
                if (cell.wordWrap === false) styles.push('white-space:nowrap');
                if (cell.textPadding != null) styles.push('padding:' + cell.textPadding + 'px');
                if (border && item.gridStroke) styles.push('border:1px solid ' + item.gridStroke);
                if (cell.stroke) styles.push('border:' + (cell.strokeWidth || 1) + 'px ' +
                    (cell.dashed ? 'dashed ' : 'solid ') + cell.stroke);
                var content;
                if (cell.richText != null && root.PixelRichText != null) content = root.PixelRichText.toHtml(cell.richText);
                else if (cell.html != null) content = cell.html;
                else content = escapeHtml(cell.text || '').replace(/\n/g, '<br>');
                if (cell.link) content = '<a href="' + escapeAttr(cell.link) + '">' + content + '</a>';
                html += '<' + tag + (span > 1 ? ' colspan="' + span + '"' : '') +
                    (rowSpan > 1 ? ' rowspan="' + rowSpan + '"' : '') +
                    (cell.align ? ' align="' + escapeAttr(cell.align) + '"' : '') +
                    (styles.length ? ' style="' + escapeAttr(styles.join(';')) + '"' : '') + '>' +
                    content + '</' + tag + '>';
                column += span;
            }
            html += '</tr>';
        }
        return html + '</table>';
    }

    function labelFor(item) {
        // Every retained table carries its nested cell content and cell-level
        // styling through qochart as HTML, not only tables originally created
        // from an HTML palette entry.
        if (item.shape === 'table') return tableHtmlFor(item);
        if (item.richText != null && root.PixelRichText != null) {
            return root.PixelRichText.toHtml(item.richText);
        }
        if (item.html != null) return item.html;
        return item.text || '';
    }

    /* Serialises a scene back to a .qochart document. */
    function serialize(scene) {
        var diagram = scene.diagram || {};
        var items = (scene.items || []).filter(function(item) { return !item.foldedAway; });
        var known = Object.create(null);
        var byId = Object.create(null);
        items.forEach(function(item) {
            known[item.id] = true;
            byId[item.id] = item;
        });

        var lines = [];
        lines.push('<mxGraphModel dx="1200" dy="800"' +
            ' grid="' + (diagram.gridEnabled === false ? '0' : '1') + '"' +
            ' gridSize="' + (diagram.gridSize || 10) + '"' +
            ' guides="' + (diagram.guidesEnabled === false ? '0' : '1') + '"' +
            ' tooltips="' + (diagram.tooltipsEnabled === false ? '0' : '1') + '"' +
            ' connect="1" arrows="1" fold="1"' +
            ' page="' + (diagram.pageView ? '1' : '0') + '"' +
            ' pageScale="' + (diagram.pageScale || 1) + '"' +
            ' pageWidth="' + Math.round(diagram.pageWidth || 850) + '"' +
            ' pageHeight="' + Math.round(diagram.pageHeight || 1100) + '"' +
            ' background="' + (diagram.backgroundColor || '#ffffff') + '"' +
            ((scene.layers && scene.layers.length) ?
                ' qochartLayers="' + escapeAttr(encodedJson(scene.layers)) + '"' : '') + '>');
        lines.push('  <root>');
        lines.push('    <mxCell id="0" />');
        lines.push('    <mxCell id="1" parent="0" />');

        items.forEach(function(item) {
            var isEdge = item.type === 'edge';
            // Dangling terminals are represented by sourcePoint/targetPoint,
            // exactly like mxGeometry in the original editor.
            if (isEdge && ((!known[item.sourceId] && !item.sourcePoint) ||
                (!known[item.targetId] && !item.targetPoint))) return;

            var mx = item.mx || {};
            var style = isEdge ? edgeToStyle(item) : nodeToStyle(item);
            var label = labelFor(item);
            var geometry;
            // Canvas items use absolute world coordinates, whereas a classic
            // mxGeometry is local to its parent vertex. Writing the absolute
            // value with a non-root parent makes every load add the parent
            // offset again (and nested list labels get it added repeatedly).
            var parentId = (!isEdge && item.containerId && known[item.containerId]) ?
                item.containerId : '1';
            var parentItem = byId[parentId];

            if (isEdge) {
                geometry = '<mxGeometry relative="1" as="geometry">';
                if (!known[item.sourceId] && item.sourcePoint) {
                    geometry += '<mxPoint x="' + numberOut(item.sourcePoint.x) +
                        '" y="' + numberOut(item.sourcePoint.y) + '" as="sourcePoint" />';
                }
                if (!known[item.targetId] && item.targetPoint) {
                    geometry += '<mxPoint x="' + numberOut(item.targetPoint.x) +
                        '" y="' + numberOut(item.targetPoint.y) + '" as="targetPoint" />';
                }
                if (item.route && item.route.length > 0) {
                    geometry += '<Array as="points">';
                    item.route.forEach(function(point) {
                        geometry += '<mxPoint x="' + numberOut(point.x) +
                            '" y="' + numberOut(point.y) + '" />';
                    });
                    geometry += '</Array>';
                }
                geometry += '</mxGeometry>';
            } else {
                var localX = item.x - (parentItem ? parentItem.x : 0);
                var localY = item.y - (parentItem ? parentItem.y : 0);
                geometry = '<mxGeometry x="' + numberOut(localX) + '" y="' + numberOut(localY) +
                    '" width="' + numberOut(item.width) + '" height="' + numberOut(item.height) +
                    '" as="geometry" />';
            }

                var attrs = ' style="' + escapeAttr(style) + '"' +
                (isEdge ? ' edge="1"' : ' vertex="1"') +
                ' parent="' + escapeAttr(parentId) + '"';
            if (isEdge && item.sourceId && known[item.sourceId]) {
                attrs += ' source="' + escapeAttr(item.sourceId) + '"';
            }
            if (isEdge && item.targetId && known[item.targetId]) {
                attrs += ' target="' + escapeAttr(item.targetId) + '"';
            }
            if (item.visible === false) attrs += ' visible="0"';

            // Links in mxGraph are attributes on a UserObject/UserData
            // wrapper. Preserve an imported wrapper and create a standard
            // UserObject for a newly linked canvas item.
            // Edges carry links too, so this must not be limited to vertices.
            var wrapperTag = mx.wrapperTag ||
                (item.kind === 'visualScript' ? 'VisualScript' : (item.link ? 'UserObject' : null));
            if (wrapperTag) {
                var wrapperAttrs = '';
                var seenId = false;
                var sourceAttrs = Object.assign({}, mx.wrapperAttrs || {},
                    item.kind === 'visualScript' ? (item.visualScript || {}) : {});
                if (item.kind === 'visualScript') {
                    sourceAttrs.vsType = item.vsType || sourceAttrs.vsType || 'process';
                    sourceAttrs.label = item.text || sourceAttrs.label || sourceAttrs.vsType;
                }
                if (!sourceAttrs.label && !sourceAttrs.value) sourceAttrs.label = label;
                if (!sourceAttrs.id) sourceAttrs.id = item.id;
                if (item.link) sourceAttrs.link = item.link;
                else delete sourceAttrs.link;
                Object.keys(sourceAttrs).forEach(function(name) {
                    var value = sourceAttrs[name];
                    if (name === 'label' || name === 'value') value = label;
                    if (name === 'id') seenId = true;
                    wrapperAttrs += ' ' + name + '="' + escapeAttr(value) + '"';
                });
                if (!seenId) wrapperAttrs += ' id="' + escapeAttr(item.id) + '"';

                lines.push('    <' + wrapperTag + wrapperAttrs + '>');
                lines.push('      <mxCell' + attrs + '>');
                lines.push('        ' + geometry);
                lines.push('      </mxCell>');
                lines.push('    </' + wrapperTag + '>');
            } else {
                lines.push('    <mxCell id="' + escapeAttr(item.id) + '"' +
                    ' value="' + escapeAttr(label) + '"' + attrs + '>');
                lines.push('      ' + geometry);
                lines.push('    </mxCell>');
            }
        });

        lines.push('  </root>');
        lines.push('</mxGraphModel>');
        return lines.join('\n');
    }

    root.PixelMxGraphFormat = {
        parse: parse,
        serialize: serialize,
        looksLikeXml: looksLikeXml,
        decodeStyle: decodeStyle,
        encodeStyle: encodeStyle
    };
})(typeof self !== 'undefined' ? self : this);
