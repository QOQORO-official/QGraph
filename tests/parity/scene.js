/* A scene that exercises every painter path, shared by the parity pages. */
(function(root) {
    'use strict';
    var shapes = ['rect', 'ellipse', 'diamond', 'triangle', 'hexagon', 'parallelogram',
        'trapezoid', 'chevron', 'step', 'isoCube2', 'isoRectangle', 'line', 'curlyBracket',
        'crossbar', 'manualInput', 'loopLimit', 'offPageConnector', 'display', 'singleArrow',
        'doubleArrow', 'cross', 'corner', 'tee', 'tapeData', 'orEllipse', 'sumEllipse',
        'lineEllipse', 'sortShape', 'datastore', 'switch', 'collate', 'partialRectangle',
        'delay', 'document', 'note', 'cube', 'cylinder', 'cloud', 'actor', 'blockArrow',
        'speech', 'plus', 'umlBoundary', 'umlEntity', 'umlControl', 'umlDestroy',
        'umlLifeline', 'umlFrame', 'umlState', 'module', 'component', 'folder',
        'providedRequiredInterface', 'requiredInterface', 'endState', 'startState',
        'message', 'parallelMarker', 'card', 'tape', 'dataStorage', 'xor', 'or', 'text',
        'swimlane', 'process', 'internalStorage'];
    var fills = ['#ffffff', '#dae8fc', '#d5e8d4', '#ffe6cc', '#fff2cc', '#f8cecc', '#e1d5e7'];

    function makeScene() {
        var items = [];
        var z = 1;
        shapes.forEach(function(shape, i) {
            var col = i % 10;
            var row = Math.floor(i / 10);
            items.push({
                id: 'n' + i, type: 'node', kind: 'shape', shape: shape,
                x: 20 + col * 130, y: 20 + row * 110, width: 100 + (i % 3) * 10,
                height: 70 + (i % 4) * 5, rotation: i % 7 === 3 ? 15 : 0,
                fill: fills[i % fills.length], stroke: i % 5 === 0 ? '#b85450' : '#4a5564',
                strokeWidth: 1 + (i % 3) * 0.5, radius: i % 4 === 0 ? 8 : undefined,
                text: i % 6 === 0 ? 'Long label that wraps across lines ' + shape : shape,
                textColor: '#172033', fontSize: 11 + (i % 4),
                dashed: i % 9 === 4, shadow: i % 8 === 2, opacity: i % 11 === 5 ? 0.6 : undefined,
                gradient: i % 13 === 7 ? '#7ea6e0' : undefined,
                gradientDirection: i % 13 === 7 ? ['south', 'horizontal', 'radial', 'diagonal'][i % 4] : undefined,
                textAlign: ['center', 'left', 'right'][i % 3], verticalAlign: ['middle', 'top', 'bottom'][i % 3],
                underline: i % 10 === 1, strikethrough: i % 10 === 2, italic: i % 7 === 1, bold: i % 7 === 2,
                flipH: i % 17 === 9, double: shape === 'rect' || shape === 'ellipse',
                collapsible: i === 12, collapsed: i === 12, cscript: i === 15 ? 'x' : undefined,
                shapeSize: i % 4 === 1 ? 0.3 : undefined, direction: i % 5 === 2 ? 'south' : undefined,
                z: z++, visible: true
            });
        });
        items.push({
            id: 'rich', type: 'node', shape: 'rect', x: 20, y: 800, width: 260, height: 170,
            fill: '#ffffff', stroke: '#333333', strokeWidth: 1, z: z++, textAlign: 'left',
            richText: { blocks: [
                { type: 'h1', indent: 0, runs: [{ text: 'Heading' }] },
                { type: 'p', indent: 0, runs: [{ text: 'Plain ' }, { text: 'bold', bold: true },
                    { text: ' and ', italic: true }, { text: 'red', color: '#cc0000' },
                    { text: 'x' }, { text: '2', script: 'sup' }, { text: ' link', link: 'http://x' }] },
                { type: 'ul', indent: 0, runs: [{ text: 'first bullet item that wraps onto another line' }] },
                { type: 'ul', indent: 1, runs: [{ text: 'nested' }] },
                { type: 'ol', indent: 0, runs: [{ text: 'one' }] },
                { type: 'ol', indent: 0, runs: [{ text: 'two', strike: true, underline: true }] },
                { type: 'pre', indent: 0, align: 'right', runs: [{ text: 'code()' }] }
            ] }
        });
        items.push({
            id: 'table', type: 'node', kind: 'table', shape: 'table', x: 300, y: 800,
            width: 320, height: 160, rows: 4, columns: 3, tableTitle: 'Table title',
            tableTitleHeight: 28, headerRow: true, headerFill: '#e6f0ff', fill: '#ffffff',
            stroke: '#4a5564', strokeWidth: 1, gridStroke: '#666666', z: z++,
            columnWeights: [1, 2, 1], rowWeights: [1, 1, 2, 1],
            cells: {
                '0,0': { text: 'Name' }, '0,1': { text: 'Value' }, '0,2': 'Plain string',
                '1,0': { text: 'merged', colspan: 2, fill: '#fff2cc' },
                '2,0': { text: 'tall', rowspan: 2, align: 'left', verticalAlign: 'top' },
                '2,1': { text: 'Some longer cell text that wraps', italic: true },
                '3,2': { text: 'end', stroke: '#ff0000', dashed: true, textColor: '#0000ff' }
            }
        });
        items.push({
            id: 'tasks', type: 'node', kind: 'taskList', shape: 'rect', x: 640, y: 800,
            width: 180, height: 140, fill: '#ffffff', stroke: '#333', z: z++,
            tasks: [{ text: 'first', done: true }, 'second', { text: 'third' }]
        });
        items.push({
            id: 'stencil1', type: 'node', shape: 'stencil', stencil: 'mxgraph.flowchart.annotation_2',
            x: 840, y: 800, width: 80, height: 100, fill: '#ffffff', stroke: '#000000', z: z++, text: 'stencil'
        });
        items.push({
            id: 'stencil2', type: 'node', shape: 'stencil', stencil: 'mxgraph.basic.star',
            x: 940, y: 800, width: 100, height: 100, fill: '#ffcc00', stroke: '#996600', z: z++, dashed: true
        });
        items.push({
            id: 'stencil3', type: 'node', shape: 'stencil', stencil: 'mxgraph.arrows.jump-in_arrow_1',
            x: 1060, y: 800, width: 100, height: 100, fill: '#dae8fc', stroke: '#6c8ebf', z: z++
        });
        // Connectors of every kind.
        var edgeDefs = [
            { sourceId: 'n0', targetId: 'n1', lineStyle: 'orthogonal', endArrow: 'classic' },
            { sourceId: 'n1', targetId: 'n12', lineStyle: 'straight', endArrow: 'open', startArrow: 'oval' },
            { sourceId: 'n2', targetId: 'n13', lineStyle: 'curved', endArrow: 'diamond', text: 'curved label',
              route: [{ x: 330, y: 200 }, { x: 400, y: 120 }] },
            { sourceId: 'n3', targetId: 'n14', lineStyle: 'circular', arcSweep: 120, endArrow: 'block' },
            { sourceId: 'n20', targetId: 'n33', lineStyle: 'orthogonal', endArrow: 'classicThin',
              sourceLabel: 'src', targetLabel: 'dst', dashed: true, stroke: '#0066cc', strokeWidth: 2 },
            { sourceId: 'n21', targetId: null, targetPoint: { x: 900, y: 760 }, lineStyle: 'orthogonal',
              targetSide: null, edgeSymbol: 'message' },
            { sourceId: null, targetId: null, sourcePoint: { x: 1250, y: 40 }, targetPoint: { x: 1350, y: 300 },
              lineStyle: 'straight', endArrow: 'none', opacity: 0.5 },
            { sourceId: 'n40', targetId: 'n41', lineStyle: 'orthogonal', sourceAnchor: { x: 0.25, y: 1, side: 'south' },
              targetAnchor: { x: 0, y: 0.5, side: 'west' }, route: [{ x: 60, y: 560 }, { x: 250, y: 580 }] },
            { sourceId: 'n50', targetId: 'n50', lineStyle: 'circular', circleRadius: 30 },
            { sourceId: 'n55', targetId: 'n58', lineStyle: 'orthogonal', endArrow: '', startArrow: 'classic', arrowSize: 14 }
        ];
        edgeDefs.forEach(function(def, i) {
            var edge = {
                id: 'e' + i, type: 'edge', sourceSide: 'east', targetSide: 'west', sourceAnchor: null,
                targetAnchor: null, route: null, stroke: '#000000', strokeWidth: 1, lineStyle: 'straight',
                startArrow: 'none', endArrow: 'classic', rounded: true, fontFamily: 'Helvetica, Arial, sans-serif',
                fontSize: 11, z: z++, visible: true
            };
            Object.keys(def).forEach(function(key) { edge[key] = def[key]; });
            items.push(edge);
        });
        return items;
    }

    root.makeScene = makeScene;
    root.sceneViews = [
        { width: 1400, height: 1000, scrollX: 0, scrollY: 0, zoom: 1, dpr: 1, grid: true, gridSize: 10,
          gridColor: '#dfe4ea', background: '#ffffff', pageView: false, hiddenLayers: [] },
        { width: 900, height: 700, scrollX: 120, scrollY: 60, zoom: 1.7, dpr: 1, grid: true, gridSize: 10,
          gridColor: '#dfe4ea', background: '#ffffff', pageView: false, hiddenLayers: [] },
        { width: 1000, height: 800, scrollX: -60, scrollY: -30, zoom: 0.6, dpr: 2, grid: true, gridSize: 10,
          gridColor: '#dfe4ea', background: '#f0f0f0', pageView: true, pageWidth: 827, pageHeight: 1169,
          pageColumns: 2, pageRows: 1, pageStartColumn: 0, pageStartRow: 0, hiddenLayers: [] }
    ];
})(window);
