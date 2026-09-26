/* Document facade and node templates for the pixel-native graph editor. */
(function(root) {
    'use strict';

    /* The Visual Script inventory is deliberately described separately from
       the ordinary flowchart shapes. The classic editor did not use a
       different symbol for each script type: every entry was the same white,
       rounded HTML node with a type-coloured outline and a live-looking title
       bar. Keeping the description here lets the SVG palette and the canvas
       painter consume exactly the same geometry and content. */
    var VISUAL_SCRIPT_DEFINITIONS = [
        { key: 'vsInput', type: 'input', label: 'Input', width: 160, height: 120, stroke: '#2563eb', rows: [['message', 'message'], ['value', 'value']] },
        { key: 'vsProcess', type: 'process', label: 'Process', width: 160, height: 120, stroke: '#dc2626', rows: [['left + right', 'left + right'], ['result', 'result']] },
        { key: 'vsLlm', type: 'llm', label: 'LLM Node', width: 180, height: 165, stroke: '#e11d48', rows: [['model', 'model'], ['response', 'response'], ['tokens', 'totalTokens']] },
        { key: 'vsUiLlm', type: 'uiLLM', label: 'UI LLM Node', width: 180, height: 390, stroke: '#06b6d4', rows: [['model', 'model'], ['last response', 'response']] },
        { key: 'vsQnote', type: 'qnoteTemplate', label: 'QNote Template', width: 180, height: 75, stroke: '#7c3aed', summary: ['QNote Template', '3 objects'] },
        { key: 'vsSheet', type: 'sheetTemplate', label: 'Sheet Template', width: 180, height: 75, stroke: '#0e7490', summary: ['Sheet Template', '3 rows'] },
        { key: 'vsCondition', type: 'condition', label: 'If', width: 140, height: 120, stroke: '#d97706', rows: [['test', 'equals'], ['branch', 'FALSE']] },
        { key: 'vsFor', type: 'for', label: 'For Loop', width: 160, height: 158, stroke: '#ea580c', rows: [['iterator', 'i'], ['iterations', '3'], ['use msg variables', 'off'], ['', 'not run']] },
        { key: 'vsWhile', type: 'while', label: 'While Loop', width: 180, height: 158, stroke: '#7c3aed', rows: [['condition', 'loopIteration <= 3'], ['max iterations', '100'], ['', 'not run']] },
        { key: 'vsOutput', type: 'output', label: 'Output', width: 160, height: 120, stroke: '#16a34a', summary: ['Output', '0 variables'] },
        { key: 'vsFunction', type: 'function', label: 'Function', width: 180, height: 120, stroke: '#0891b2', rows: [['input', 'inputValue'], ['result', 'result']] },
        { key: 'vsHttp', type: 'http', label: 'HTTP', width: 180, height: 120, stroke: '#0d9488', rows: [['url', 'url'], ['mock', 'response']] },
        { key: 'vsDelay', type: 'delay', label: 'Delay', width: 160, height: 120, stroke: '#ca8a04', rows: [['delay', 'ms'], ['mode', 'pass-through']] },
        { key: 'vsSlack', type: 'slack', label: 'Slack', width: 220, height: 200, stroke: '#611f69', rows: [['action', 'search'], ['target', 'channel'], ['scope', 'messages'], ['limit', '20'], ['read-only', 'not run']] }
    ];

    function visualScriptTemplate(definition) {
        var template = {
            kind: 'visualScript', vsType: definition.type,
            shape: 'rect', width: definition.width, height: definition.height,
            text: definition.label, fill: '#ffffff', stroke: definition.stroke,
            strokeWidth: 2, radius: 6, textColor: '#222222', fontSize: 12,
            fontFamily: 'Arial, Helvetica, sans-serif', textAlign: 'left',
            verticalAlign: 'top', textPadding: 0, editable: false,
            visualRows: definition.rows || null,
            visualSummary: definition.summary || null,
            visualScript: { label: definition.label, vsType: definition.type,
                lastResult: '', lastError: '' }
        };
        if (definition.type === 'input') {
            template.visualScript.inputVars = JSON.stringify([
                { name: 'message', type: 'string', value: 'Hello from Input' },
                { name: 'value', type: 'number', value: '5' }
            ]);
            template.visualScript.exports = 'message,value';
        }
        return template;
    }

    root.PixelVisualScriptDefinitions = VISUAL_SCRIPT_DEFINITIONS;

    root.PixelNodeTemplates = {
        process: {
            shape: 'rect', width: 160, height: 76, text: 'Process',
            fill: '#ffffff', stroke: '#4a5564', radius: 5
        },
        rounded: {
            shape: 'rect', width: 170, height: 76, text: 'Rounded Process',
            fill: '#e8f4ff', stroke: '#2783c5', radius: 18
        },
        decision: {
            shape: 'diamond', width: 130, height: 100, text: 'Decision',
            fill: '#fff4d6', stroke: '#c98b18'
        },
        terminator: {
            shape: 'ellipse', width: 150, height: 68, text: 'Start / End',
            fill: '#e8f8ef', stroke: '#2f9e64'
        },
        llm: {
            shape: 'rect', width: 190, height: 90, text: 'LLM Node',
            fill: '#241442', stroke: '#8b5cf6', textColor: '#ffffff',
            radius: 10, shadow: true
        },
        tool: {
            shape: 'rect', width: 190, height: 90, text: 'Tool Node',
            fill: '#13374d', stroke: '#38bdf8', textColor: '#ffffff',
            radius: 10, shadow: true
        },
        condition: {
            shape: 'diamond', width: 150, height: 112, text: 'Condition',
            fill: '#3b2610', stroke: '#f59e0b', textColor: '#fff7dc'
        },
        taskList: {
            kind: 'taskList', shape: 'rect', width: 230, height: 168,
            text: 'Task Masterlist', fill: '#ffffff', stroke: '#252b33', radius: 0,
            tasks: [
                { text: 'Ask LoA from Tokyo-Tech' },
                { text: 'Submit LoA to PK before August' },
                { text: 'Call LPDP staff (Emergency Next Week)' },
                { text: 'Submit form COE' }
            ]
        },
        note: {
            shape: 'note', width: 180, height: 110, text: 'Note',
            fill: '#fff8bf', stroke: '#caa61c', radius: 2, textAlign: 'left'
        },
        text: {
            shape: 'text', width: 160, height: 44, text: 'Text',
            fill: 'transparent', stroke: 'transparent', strokeWidth: 0, fontSize: 16
        },
        heading: {
            shape: 'text', width: 220, height: 52, text: 'Heading',
            fill: 'transparent', stroke: 'transparent', strokeWidth: 0,
            fontSize: 24, fontWeight: 700
        },
        square: {
            shape: 'rect', width: 90, height: 90, text: '',
            fill: '#ffffff', stroke: '#4a5564', radius: 0
        },
        circle: {
            shape: 'ellipse', width: 90, height: 90, text: '',
            fill: '#ffffff', stroke: '#4a5564'
        },
        ellipse: {
            shape: 'ellipse', width: 150, height: 82, text: 'Ellipse',
            fill: '#ffffff', stroke: '#4a5564'
        },
        triangle: {
            shape: 'triangle', width: 116, height: 96, text: '',
            fill: '#ffffff', stroke: '#4a5564'
        },
        hexagon: {
            shape: 'hexagon', width: 145, height: 88, text: 'Hexagon',
            fill: '#ffffff', stroke: '#4a5564'
        },
        parallelogram: {
            shape: 'parallelogram', width: 155, height: 82, text: 'Data',
            fill: '#ffffff', stroke: '#4a5564'
        },
        trapezoid: {
            shape: 'trapezoid', width: 150, height: 82, text: 'Manual',
            fill: '#ffffff', stroke: '#4a5564'
        },
        cylinder: {
            shape: 'cylinder', width: 120, height: 100, text: 'Database',
            fill: '#ffffff', stroke: '#4a5564'
        },
        cloud: {
            shape: 'cloud', width: 160, height: 100, text: 'Cloud',
            fill: '#ffffff', stroke: '#4a5564'
        },
        document: {
            shape: 'document', width: 145, height: 96, text: 'Document',
            fill: '#ffffff', stroke: '#4a5564'
        },
        cube: {
            shape: 'cube', width: 125, height: 100, text: 'Cube',
            fill: '#ffffff', stroke: '#4a5564'
        },
        actor: {
            shape: 'actor', width: 80, height: 125, text: '',
            fill: 'transparent', stroke: '#4a5564', strokeWidth: 2
        },
        containerBlock: {
            kind: 'container', shape: 'swimlane', width: 200, height: 200,
            text: 'Container', fill: '#ffffff', stroke: '#4a5564',
            headerHeight: 26, verticalAlign: 'top', container: true,
            collapsible: true, radius: 0
        },
        listItem: {
            kind: 'listItem', shape: 'text', width: 60, height: 26,
            text: 'List Item', fill: 'transparent', stroke: 'transparent',
            strokeWidth: 0, textAlign: 'left', verticalAlign: 'top',
            textPadding: 4, wordWrap: false, rotatable: false
        },
        list: {
            kind: 'list', shape: 'swimlane', width: 140, height: 104,
            text: 'List', fill: 'transparent', stroke: '#4a5564',
            headerHeight: 26, verticalAlign: 'top', fontWeight: 400,
            childLayout: 'stackLayout', stackHorizontal: false,
            resizeParent: true, resizeParentMax: false, resizeLast: false,
            collapsible: true, container: true, marginBottom: 0,
            children: [
                { kind: 'listItem', shape: 'text', x: 0, y: 26, width: 140, height: 26,
                    text: 'Item 1', fill: 'transparent', stroke: 'transparent', strokeWidth: 0,
                    textAlign: 'left', verticalAlign: 'top', textPadding: 4,
                    wordWrap: false, rotatable: false },
                { kind: 'listItem', shape: 'text', x: 0, y: 52, width: 140, height: 26,
                    text: 'Item 2', fill: 'transparent', stroke: 'transparent', strokeWidth: 0,
                    textAlign: 'left', verticalAlign: 'top', textPadding: 4,
                    wordWrap: false, rotatable: false },
                { kind: 'listItem', shape: 'text', x: 0, y: 78, width: 140, height: 26,
                    text: 'Item 3', fill: 'transparent', stroke: 'transparent', strokeWidth: 0,
                    textAlign: 'left', verticalAlign: 'top', textPadding: 4,
                    wordWrap: false, rotatable: false }
            ]
        },
        table: {
            shape: 'table', width: 260, height: 150, text: '', rows: 4, columns: 3,
            fill: '#ffffff', stroke: '#4a5564', radius: 0,
            headerRow: true, headerFill: '#eef1f6', cellAlign: 'center', fontSize: 12,
            cells: {
                '0,0': { text: 'Item' }, '0,1': { text: 'Owner' }, '0,2': { text: 'Due' },
                '1,0': { text: 'Draft' }, '1,1': { text: 'Ana' }, '1,2': { text: 'Mon' },
                '2,0': { text: 'Review' }, '2,1': { text: 'Sam' }, '2,2': { text: 'Wed' }
            }
        },
        html: {
            shape: 'html', width: 260, height: 140, text: '',
            fill: '#ffffff', stroke: '#4a5564', radius: 4,
            textAlign: 'left', verticalAlign: 'top', fontSize: 13,
            html: '<h3>HTML block</h3><p>Rich text with <b>bold</b>, <i>italic</i> and a list:</p>' +
                '<ul><li>First item</li><li>Second item</li></ul>'
        },
        chevron: {
            shape: 'chevron', width: 150, height: 82, text: 'Chevron',
            fill: '#e8f4ff', stroke: '#2783c5'
        },
        step: {
            shape: 'step', width: 150, height: 82, text: 'Step',
            fill: '#ffffff', stroke: '#4a5564'
        },
        delay: {
            shape: 'delay', width: 145, height: 82, text: 'Delay',
            fill: '#ffffff', stroke: '#4a5564'
        },
        plus: {
            shape: 'plus', width: 100, height: 100, text: '',
            fill: '#ffffff', stroke: '#4a5564'
        },
        speech: {
            shape: 'speech', width: 160, height: 105, text: 'Callout',
            fill: '#ffffff', stroke: '#4a5564'
        },
        arrowRight: {
            shape: 'blockArrow', width: 160, height: 76, text: '',
            fill: '#ffffff', stroke: '#4a5564'
        },
        arrowDown: {
            shape: 'blockArrow', width: 160, height: 76, text: '', rotation: 90,
            fill: '#ffffff', stroke: '#4a5564'
        },
        arrowLeft: {
            shape: 'blockArrow', width: 160, height: 76, text: '', rotation: 180,
            fill: '#ffffff', stroke: '#4a5564'
        },
        arrowUp: {
            shape: 'blockArrow', width: 160, height: 76, text: '', rotation: 270,
            fill: '#ffffff', stroke: '#4a5564'
        },

        /* Misc palette: canvas-native counterparts of the old GraphEditor
           list/table/HTML entries. */
        title: {
            shape: 'text', width: 180, height: 44, text: 'Title',
            fill: 'transparent', stroke: 'transparent', strokeWidth: 0,
            fontSize: 24, fontWeight: 700
        },
        unorderedList: {
            shape: 'html', width: 180, height: 105, text: '',
            fill: 'transparent', stroke: 'transparent', strokeWidth: 0,
            textAlign: 'left', verticalAlign: 'top', fontSize: 14,
            html: '<ul><li>Value 1</li><li>Value 2</li><li>Value 3</li></ul>'
        },
        orderedList: {
            shape: 'html', width: 180, height: 105, text: '',
            fill: 'transparent', stroke: 'transparent', strokeWidth: 0,
            textAlign: 'left', verticalAlign: 'top', fontSize: 14,
            html: '<ol><li>Value 1</li><li>Value 2</li><li>Value 3</li></ol>'
        },
        tableCompact: {
            shape: 'table', width: 220, height: 120, text: '', rows: 3, columns: 3,
            fill: '#ffffff', stroke: '#4a5564', radius: 0, headerRow: false,
            cellAlign: 'center', fontSize: 12,
            cells: {
                '0,0': { text: 'Value 1' }, '0,1': { text: 'Value 2' }, '0,2': { text: 'Value 3' },
                '1,0': { text: 'Value 4' }, '1,1': { text: 'Value 5' }, '1,2': { text: 'Value 6' },
                '2,0': { text: 'Value 7' }, '2,1': { text: 'Value 8' }, '2,2': { text: 'Value 9' }
            }
        },
        tableTitle: {
            shape: 'table', width: 230, height: 145, text: '', rows: 4, columns: 3,
            fill: '#ffffff', stroke: '#4a5564', radius: 0, headerRow: true,
            headerFill: '#eef1f6', cellAlign: 'center', fontSize: 12,
            cells: {
                '0,0': { text: 'Title 1' }, '0,1': { text: 'Title 2' }, '0,2': { text: 'Title 3' },
                '1,0': { text: 'Value 1' }, '1,1': { text: 'Value 2' }, '1,2': { text: 'Value 3' },
                '2,0': { text: 'Value 4' }, '2,1': { text: 'Value 5' }, '2,2': { text: 'Value 6' }
            }
        },
        htmlTable1: {
            shape: 'table', sourceType: 'htmlTable', width: 280, height: 160, text: '', rows: 3, columns: 3,
            fill: '#ffffff', stroke: '#98bf21', radius: 0, headerRow: true, headerFill: '#a7c942', cellAlign: 'left', fontSize: 12,
            html: '<table border="1"><tr><th>Title 1</th><th>Title 2</th><th>Title 3</th></tr><tr><td>Value 1</td><td>Value 2</td><td>Value 3</td></tr><tr><td>Value 4</td><td>Value 5</td><td>Value 6</td></tr></table>',
            cells: { '0,0':{text:'Title 1'},'0,1':{text:'Title 2'},'0,2':{text:'Title 3'},'1,0':{text:'Value 1'},'1,1':{text:'Value 2'},'1,2':{text:'Value 3'},'2,0':{text:'Value 4'},'2,1':{text:'Value 5'},'2,2':{text:'Value 6'} }
        },
        htmlTable2: {
            shape: 'table', sourceType: 'htmlTable', width: 220, height: 140, text: '', rows: 3, columns: 3,
            fill: '#ffffff', stroke: '#c0c0c0', radius: 0, headerRow: false, cellAlign: 'center', fontSize: 12,
            html: '<table><tr><td>Value 1</td><td>Value 2</td><td>Value 3</td></tr><tr><td>Value 4</td><td>Value 5</td><td>Value 6</td></tr><tr><td>Value 7</td><td>Value 8</td><td>Value 9</td></tr></table>',
            cells: { '0,0':{text:'Value 1'},'0,1':{text:'Value 2'},'0,2':{text:'Value 3'},'1,0':{text:'Value 4'},'1,1':{text:'Value 5'},'1,2':{text:'Value 6'},'2,0':{text:'Value 7'},'2,1':{text:'Value 8'},'2,2':{text:'Value 9'} }
        },
        htmlTable3: {
            shape: 'table', sourceType: 'htmlTable', width: 220, height: 140, text: '', rows: 3, columns: 3,
            fill: 'transparent', stroke: '#4a5564', radius: 0, headerRow: false, cellAlign: 'center', fontSize: 12,
            html: '<table border="1"><tr><td>Value 1</td><td>Value 2</td><td>Value 3</td></tr><tr><td>Value 4</td><td>Value 5</td><td>Value 6</td></tr><tr><td>Value 7</td><td>Value 8</td><td>Value 9</td></tr></table>',
            cells: { '0,0':{text:'Value 1'},'0,1':{text:'Value 2'},'0,2':{text:'Value 3'},'1,0':{text:'Value 4'},'1,1':{text:'Value 5'},'1,2':{text:'Value 6'},'2,0':{text:'Value 7'},'2,1':{text:'Value 8'},'2,2':{text:'Value 9'} }
        },
        htmlTable4: {
            shape: 'table', sourceType: 'htmlTable', width: 180, height: 150, text: '', rows: 3, columns: 1,
            fill: '#ffffff', stroke: '#4a5564', radius: 0, headerRow: true, headerFill: '#eef1f6', cellAlign: 'center', fontSize: 12,
            html: '<table border="1"><tr><th>Title</th></tr><tr><td>Section 1.1 / 1.2 / 1.3</td></tr><tr><td>Section 2.1 / 2.2 / 2.3</td></tr></table>',
            cells: { '0,0':{text:'Title'},'1,0':{text:'Section 1.1\nSection 1.2\nSection 1.3'},'2,0':{text:'Section 2.1\nSection 2.2\nSection 2.3'} }
        },

        /* Lightweight canvas-native UML/BPMN palette entries. */
        umlActor: { shape: 'actor', width: 54, height: 96, text: 'Actor', fill: 'transparent', stroke: '#333333', strokeWidth: 2 },
        umlUseCase: { shape: 'ellipse', width: 150, height: 72, text: 'Use Case', fill: '#ffffff', stroke: '#333333' },
        umlObject: { shape: 'rect', width: 150, height: 72, text: 'Object', fill: '#ffffff', stroke: '#333333', radius: 0, underline: true },
        umlLifeline: { shape: 'swimlane', width: 100, height: 260, text: ':Object', fill: '#ffffff', stroke: '#333333', radius: 0 },
        umlNote: { shape: 'note', width: 140, height: 90, text: 'Comment', fill: '#fffbd6', stroke: '#555555' },
        umlPackage: { shape: 'rect', width: 170, height: 110, text: 'Package', fill: '#ffffff', stroke: '#333333', radius: 0 },
        bpmnEvent: { shape: 'ellipse', width: 58, height: 58, text: '', fill: '#ffffff', stroke: '#333333', strokeWidth: 2 },
        bpmnEventEnd: { shape: 'ellipse', width: 58, height: 58, text: '', fill: '#ffffff', stroke: '#333333', strokeWidth: 4 },
        bpmnGateway: { shape: 'diamond', width: 74, height: 74, text: '×', fill: '#ffffff', stroke: '#333333', fontSize: 28 },
        bpmnTask: { shape: 'rect', width: 150, height: 82, text: 'Task', fill: '#ffffff', stroke: '#333333', radius: 12 },
        bpmnSubprocess: { shape: 'rect', width: 170, height: 92, text: 'Subprocess  +', fill: '#ffffff', stroke: '#333333', radius: 12 },
        bpmnData: { shape: 'document', width: 110, height: 92, text: 'Data', fill: '#ffffff', stroke: '#333333' },

        /* Visual Script nodes are the classic HTML-node cards, not generic
           flowchart symbols with similar names. */
        vsInput: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[0]),
        vsProcess: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[1]),
        vsLlm: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[2]),
        vsUiLlm: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[3]),
        vsQnote: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[4]),
        vsSheet: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[5]),
        vsCondition: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[6]),
        vsFor: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[7]),
        vsWhile: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[8]),
        vsOutput: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[9]),
        vsFunction: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[10]),
        vsHttp: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[11]),
        vsDelay: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[12]),
        vsSlack: visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[13])
    };

    function numberAttribute(node, name, fallback) {
        var value = node == null ? null : Number(node.getAttribute(name));
        return isFinite(value) ? value : fallback;
    }

    function parseLegacyStyle(text) {
        var result = Object.create(null);
        var parts = String(text || '').split(';');
        for (var i = 0; i < parts.length; i++) {
            if (!parts[i]) continue;
            var equals = parts[i].indexOf('=');
            if (equals < 0) result.shape = parts[i];
            else result[parts[i].substring(0, equals)] = parts[i].substring(equals + 1);
        }
        return result;
    }

    function legacyShape(style) {
        var shape = style.shape || 'rect';
        var aliases = {
            rectangle: 'rect', rhombus: 'diamond', label: 'rect', process: 'rect',
            internalStorage: 'rect', umlActor: 'actor',
            cylinder2: 'cylinder', cylinder3: 'cylinder', ext: 'rect',
            doubleEllipse: 'ellipse', icon: 'image'
        };
        return aliases[shape] || shape;
    }

    function decodeLegacyUri(value) {
        try { return decodeURIComponent(value); } catch (error) { return value; }
    }

    function textFromHtml(value) {
        if (!/[<&]/.test(value)) return value;
        var element = document.createElement('div');
        element.innerHTML = value;
        // innerText on a detached element does not consistently preserve BRs
        // (notably while importing serialized table cells). Convert them
        // explicitly so merged-cell text survives save/load as separate lines.
        Array.prototype.forEach.call(element.querySelectorAll('br'), function(br) {
            br.parentNode.replaceChild(document.createTextNode('\n'), br);
        });
        return (element.innerText || element.textContent || '').replace(/\u00a0/g, ' ').trim();
    }

    /* Converts a classic foreignObject HTML table into an editable retained
       grid. The source markup remains attached for round-tripping, while rows
       and columns become real divider geometry instead of a flattened label. */
    function tableFromHtml(value) {
        if (!/<table\b/i.test(String(value || ''))) return null;
        var host = document.createElement('div');
        host.innerHTML = value;
        var table = host.querySelector('table');
        if (!table || !table.rows || table.rows.length === 0) return null;

        var rows = Array.prototype.slice.call(table.rows);
        var columns = 0;
        var placements = [];
        var occupied = Object.create(null);
        rows.forEach(function(row, rowIndex) {
            var column = 0;
            Array.prototype.forEach.call(row.cells, function(cell) {
                while (occupied[rowIndex + ',' + column]) column++;
                var colspan = Math.max(1, Number(cell.colSpan) || 1);
                var rowspan = Math.max(1, Math.min(rows.length - rowIndex, Number(cell.rowSpan) || 1));
                placements.push({ row: rowIndex, column: column, colspan: colspan,
                    rowspan: rowspan, cell: cell });
                for (var rr = rowIndex; rr < rowIndex + rowspan; rr++) {
                    for (var cc = column; cc < column + colspan; cc++) {
                        occupied[rr + ',' + cc] = true;
                    }
                }
                column += colspan;
                columns = Math.max(columns, column);
            });
            Object.keys(occupied).forEach(function(key) {
                var parts = key.split(',');
                if (Number(parts[0]) === rowIndex) columns = Math.max(columns, Number(parts[1]) + 1);
            });
        });
        if (columns === 0) return null;

        function inlineColor(element, property, attribute) {
            return element.style[property] || element.getAttribute(attribute || property) || null;
        }
        function numericSize(value) {
            var parsed = parseFloat(String(value == null ? '' : value));
            return isFinite(parsed) && parsed > 0 ? parsed : 1;
        }

        var cells = {};
        var rowWeights = [];
        var columnWeights = new Array(columns).fill(1);
        var authoredColumns = table.querySelectorAll('colgroup col');
        var hasAuthoredColumns = authoredColumns.length === columns;
        if (hasAuthoredColumns) {
            Array.prototype.forEach.call(authoredColumns, function(column, index) {
                columnWeights[index] = numericSize(column.style.width || column.getAttribute('width'));
            });
        }
        rows.forEach(function(row, rowIndex) {
            rowWeights.push(numericSize(row.style.height || row.getAttribute('height')));
            placements.filter(function(placement) { return placement.row === rowIndex; })
                .forEach(function(placement) {
                var sourceCell = placement.cell;
                var column = placement.column;
                var span = placement.colspan;
                var fill = inlineColor(sourceCell, 'backgroundColor', 'bgcolor') ||
                    inlineColor(row, 'backgroundColor', 'bgcolor');
                var color = inlineColor(sourceCell, 'color') || inlineColor(row, 'color');
                var align = sourceCell.getAttribute('align') || sourceCell.style.textAlign ||
                    row.getAttribute('align') || row.style.textAlign || null;
                var cell = {
                    text: textFromHtml(sourceCell.innerHTML),
                    html: sourceCell.innerHTML,
                    tag: sourceCell.tagName.toLowerCase(),
                    colspan: span,
                    rowspan: placement.rowspan
                };
                if (cell.colspan === 1) delete cell.colspan;
                if (cell.rowspan === 1) delete cell.rowspan;
                if (fill) cell.fill = fill;
                if (color) cell.textColor = color;
                if (align) cell.align = align;
                if (cell.tag === 'th' || /bold|[6-9]00/i.test(sourceCell.style.fontWeight)) cell.fontWeight = 700;
                else if (sourceCell.style.fontWeight) cell.fontWeight = Number(sourceCell.style.fontWeight) || 400;
                if (sourceCell.style.fontFamily) cell.fontFamily = sourceCell.style.fontFamily;
                if (sourceCell.style.fontSize) cell.fontSize = numericSize(sourceCell.style.fontSize);
                if (sourceCell.style.fontStyle === 'italic') cell.italic = true;
                var decoration = sourceCell.style.textDecoration || sourceCell.style.textDecorationLine || '';
                if (decoration.indexOf('underline') >= 0) cell.underline = true;
                if (decoration.indexOf('line-through') >= 0) cell.strikethrough = true;
                if (sourceCell.style.verticalAlign) cell.verticalAlign = sourceCell.style.verticalAlign;
                if (sourceCell.style.opacity) cell.opacity = Number(sourceCell.style.opacity);
                if (sourceCell.style.whiteSpace === 'nowrap') cell.wordWrap = false;
                if (sourceCell.style.padding) cell.textPadding = numericSize(sourceCell.style.padding);
                if (sourceCell.style.borderColor) cell.stroke = sourceCell.style.borderColor;
                if (sourceCell.style.borderWidth) cell.strokeWidth = numericSize(sourceCell.style.borderWidth);
                if (sourceCell.style.borderStyle === 'dashed') cell.dashed = true;
                var cellLink = sourceCell.querySelector('a[href]');
                if (cellLink) cell.link = cellLink.getAttribute('href');
                cells[rowIndex + ',' + column] = cell;
                if (rowIndex === 0 && !hasAuthoredColumns) {
                    var width = sourceCell.style.width || sourceCell.getAttribute('width');
                    if (width) {
                        var each = numericSize(width) / span;
                        for (var s = 0; s < span && column + s < columns; s++) columnWeights[column + s] = each;
                    }
                }
            });
        });

        var firstCells = rows[0].cells;
        var firstRowIsHeader = firstCells.length > 0 && Array.prototype.every.call(firstCells,
            function(cell) { return cell.tagName.toLowerCase() === 'th'; });
        var border = Number(table.getAttribute('border')) || 0;
        var gridStroke = '#000000';
        for (var r = 0; r < rows.length; r++) {
            var borderColor = rows[r].style.borderColor;
            if (borderColor) { gridStroke = borderColor; break; }
        }

        var caption = table.querySelector('caption');
        var titleHeight = caption ? numericSize(caption.getAttribute('data-pixel-height') ||
            caption.style.height || 30) : 0;
        var fixedRows = table.getAttribute('data-pixel-fixed-rows') === '1';
        // Classic structural tables expose row move handles by default.
        // An explicit 0 is the only opt-out for retained/imported tables.
        var reorderRows = table.getAttribute('data-pixel-reorder-rows') !== '0';
        var rowIndexColumn = table.getAttribute('data-pixel-row-index-column');

        return {
            rows: rows.length, columns: columns, cells: cells,
            rowWeights: rowWeights, columnWeights: columnWeights,
            headerRow: firstRowIsHeader, tableBorder: border,
            tableCellPadding: Number(table.getAttribute('cellpadding')) || 0,
            gridStroke: gridStroke, html: table.outerHTML,
            sourceType: 'htmlTable',
            tableTitle: caption ? (caption.innerText || caption.textContent || '').trim() : null,
            tableTitleHeight: titleHeight, fixedRows: fixedRows,
            reorderRows: reorderRows,
            rowIndexColumn: rowIndexColumn == null ? null : Number(rowIndexColumn),
            rowLines: table.getAttribute('data-pixel-row-lines') !== '0',
            firstRowLine: table.getAttribute('data-pixel-first-row-line') === '1'
        };
    }

    function legacyLabel(record) {
        var value = record.wrapper === record.cell ? record.cell.getAttribute('value') :
            record.wrapper.getAttribute('label');
        return value == null ? '' : value;
    }

    /* Converts classic mxGraph XML into the retained canvas scene. Geometry
       becomes absolute because the canvas scene is flat, but every vertex
       keeps its legacy parent as containerId. This deliberately does not
       recognize named widgets: a swimlane containing rows, ellipses and text
       remains those same independently selectable cells after import. */
    function importLegacyGraph(text) {
        var xml = new DOMParser().parseFromString(text, 'application/xml');
        var parseError = xml.getElementsByTagName('parsererror')[0];
        if (parseError != null) throw new Error('Invalid mxGraph XML: ' + parseError.textContent.trim());

        var model = xml.documentElement;
        if (model.nodeName === 'mxfile') {
            var diagram = model.getElementsByTagName('diagram')[0];
            if (diagram == null || diagram.children.length === 0) {
                throw new Error('Compressed mxfile diagrams are not supported by this importer');
            }
            model = diagram.children[0];
        }
        if (model == null || model.nodeName !== 'mxGraphModel') {
            throw new Error('This file is not an mxGraphModel document');
        }

        var rootNode = model.getElementsByTagName('root')[0];
        if (rootNode == null) throw new Error('The mxGraphModel has no root');
        var records = [];
        var byId = Object.create(null);
        var childrenByParent = Object.create(null);

        for (var i = 0; i < rootNode.children.length; i++) {
            var wrapper = rootNode.children[i];
            var cell = wrapper.nodeName === 'mxCell' ? wrapper :
                Array.prototype.find.call(wrapper.children, function(child) {
                    return child.nodeName === 'mxCell';
                });
            if (cell == null) continue;
            var id = cell.getAttribute('id') || wrapper.getAttribute('id');
            if (!id) id = 'legacy-' + i;
            var record = {
                id: id, wrapper: wrapper, cell: cell,
                parent: cell.getAttribute('parent') || '',
                style: parseLegacyStyle(cell.getAttribute('style')),
                geometry: Array.prototype.find.call(cell.children, function(child) {
                    return child.nodeName === 'mxGeometry';
                })
            };
            records.push(record);
            byId[id] = record;
            if (!childrenByParent[record.parent]) childrenByParent[record.parent] = [];
            childrenByParent[record.parent].push(record);
        }

        var absoluteCache = Object.create(null);
        function absoluteGeometry(record, visiting) {
            if (absoluteCache[record.id]) return absoluteCache[record.id];
            var geometry = record.geometry;
            var result = {
                x: numberAttribute(geometry, 'x', 0), y: numberAttribute(geometry, 'y', 0),
                width: Math.max(1, numberAttribute(geometry, 'width', 80)),
                height: Math.max(1, numberAttribute(geometry, 'height', 40))
            };
            var parent = byId[record.parent];
            visiting = visiting || Object.create(null);
            if (parent && parent !== record && !visiting[record.id]) {
                visiting[record.id] = true;
                var parentGeometry = absoluteGeometry(parent, visiting);
                if (geometry && geometry.getAttribute('relative') === '1') {
                    result.x = parentGeometry.x + result.x * parentGeometry.width;
                    result.y = parentGeometry.y + result.y * parentGeometry.height;
                } else {
                    result.x += parentGeometry.x;
                    result.y += parentGeometry.y;
                }
                delete visiting[record.id];
            }
            absoluteCache[record.id] = result;
            return result;
        }

        /* Classic titled tables are nested table -> row -> cell vertices.
           Collapse that hierarchy into the retained table model so dividers,
           cell editing and row reordering remain live instead of becoming a
           pile of unrelated rectangles. */
        var structuralTables = Object.create(null);
        var structuralDescendants = Object.create(null);
        records.forEach(function(tableRecord) {
            if (tableRecord.cell.getAttribute('vertex') !== '1' ||
                tableRecord.style.childLayout !== 'tableLayout') return;
            var rowRecords = (childrenByParent[tableRecord.id] || []).filter(function(row) {
                return row.cell.getAttribute('vertex') === '1';
            });
            if (rowRecords.length === 0) return;
            var columnCount = 0;
            rowRecords.forEach(function(row) {
                columnCount = Math.max(columnCount, (childrenByParent[row.id] || []).filter(function(cell) {
                    return cell.cell.getAttribute('vertex') === '1';
                }).length);
            });
            if (columnCount === 0) return;

            var data = {
                rows: rowRecords.length, columns: columnCount, cells: {},
                rowWeights: [], columnWeights: [],
                tableTitle: textFromHtml(legacyLabel(tableRecord)),
                tableTitleHeight: Number(tableRecord.style.startSize) || 30,
                fixedRows: tableRecord.style.fixedRows === '1',
                rowLines: tableRecord.style.rowLines !== '0',
                firstRowLine: false, sourceType: 'htmlTable',
                tableBorder: 1, gridStroke: tableRecord.style.strokeColor || '#4a5564'
            };

            rowRecords.forEach(function(rowRecord, rowIndex) {
                var rowGeometry = rowRecord.geometry;
                data.rowWeights.push(Math.max(1, numberAttribute(rowGeometry, 'height', 30)));
                if (rowIndex === 0 && rowRecord.style.bottom === '1') data.firstRowLine = true;
                structuralDescendants[rowRecord.id] = true;
                var cellRecords = (childrenByParent[rowRecord.id] || []).filter(function(cell) {
                    return cell.cell.getAttribute('vertex') === '1';
                });
                cellRecords.forEach(function(cellRecord, columnIndex) {
                    structuralDescendants[cellRecord.id] = true;
                    var cellStyle = cellRecord.style;
                    var cellData = {
                        text: textFromHtml(legacyLabel(cellRecord)),
                        align: cellStyle.align || 'center'
                    };
                    if ((Number(cellStyle.fontStyle) || 0) & 1) cellData.fontWeight = 700;
                    data.cells[rowIndex + ',' + columnIndex] = cellData;
                    if (rowIndex === 0) {
                        data.columnWeights.push(Math.max(1,
                            numberAttribute(cellRecord.geometry, 'width', 60)));
                    }
                });
            });

            var indexed = true;
            for (var rowIndex = 0; rowIndex < data.rows; rowIndex++) {
                if (String((data.cells[rowIndex + ',0'] || {}).text || '').trim() !== String(rowIndex + 1)) {
                    indexed = false;
                    break;
                }
            }
            if (indexed) {
                data.rowIndexColumn = 0;
                data.reorderRows = true;
            }
            structuralTables[tableRecord.id] = data;
        });

        var items = [];
        var importedIds = Object.create(null);
        var z = 0;
        records.forEach(function(record) {
            if (record.cell.getAttribute('vertex') !== '1') return;
            if (structuralDescendants[record.id]) return;
            var geometry = absoluteGeometry(record);
            var style = record.style;
            var rawLabel = legacyLabel(record);
            var shape = legacyShape(style);
            var item = {
                id: record.id, type: 'node', kind: 'shape', shape: shape,
                x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height,
                rotation: Number(style.rotation) || 0,
                fill: style.fillColor === 'none' ? 'transparent' : (style.fillColor || '#ffffff'),
                stroke: style.strokeColor === 'none' ? 'transparent' : (style.strokeColor || '#4a5564'),
                strokeWidth: Math.max(0, Number(style.strokeWidth) || 1),
                text: textFromHtml(rawLabel), textColor: style.fontColor || '#172033',
                // Classic mxGraph defaults are 11px Arial/Helvetica. Using
                // the canvas editor's 14px default changes wrapping and makes
                // legacy labels spill into the next stacked row.
                fontSize: Number(style.fontSize) || 11,
                fontFamily: style.fontFamily || 'Arial, Helvetica, sans-serif',
                fontWeight: 400,
                textPadding: style.spacing == null ? 2 : Math.max(0, Number(style.spacing) || 0),
                textAlign: style.align || 'center', verticalAlign: style.verticalAlign || 'middle',
                radius: style.rounded === '1' ? 10 : 0,
                shadow: style.shadow === '1', dashed: style.dashed === '1',
                opacity: style.opacity == null ? 1 : Math.max(0, Math.min(1, Number(style.opacity) / 100)),
                visible: style.visible !== '0', locked: style.movable === '0' && style.resizable === '0',
                editable: style.editable !== '0', movable: style.movable !== '0',
                resizable: style.resizable !== '0', deletable: style.deletable !== '0',
                connectable: style.connectable !== '0', rotatable: style.rotatable !== '0',
                dropTarget: style.dropTarget !== '0', part: style.part === '1',
                z: ++z
            };
            var fontStyle = Number(style.fontStyle) || 0;
            if (style.double === '1' || (style.shape || '') === 'doubleEllipse') item.double = true;
            if (style.isoAngle != null) item.isoAngle = Number(style.isoAngle) || 15;
            if (fontStyle & 1) item.fontWeight = 700;
            if (fontStyle & 2) item.italic = true;
            if (fontStyle & 4) item.underline = true;
            if (style.whiteSpace !== 'wrap') item.wordWrap = false;
            if (style.html === '1' && /<[^>]+>/.test(rawLabel)) item.html = rawLabel;
            var htmlTable = style.html === '1' ? tableFromHtml(rawLabel) : null;
            if (htmlTable != null) {
                item.shape = 'table';
                item.sourceType = htmlTable.sourceType;
                item.rows = htmlTable.rows;
                item.columns = htmlTable.columns;
                item.cells = htmlTable.cells;
                item.rowWeights = htmlTable.rowWeights;
                item.columnWeights = htmlTable.columnWeights;
                item.headerRow = htmlTable.headerRow;
                item.tableBorder = htmlTable.tableBorder;
                item.tableCellPadding = htmlTable.tableCellPadding;
                item.gridStroke = htmlTable.gridStroke;
                item.html = htmlTable.html;
                item.tableTitle = htmlTable.tableTitle;
                item.tableTitleHeight = htmlTable.tableTitleHeight;
                item.fixedRows = htmlTable.fixedRows;
                item.rowLines = htmlTable.rowLines;
                item.firstRowLine = htmlTable.firstRowLine;
                item.reorderRows = htmlTable.reorderRows;
                item.rowIndexColumn = htmlTable.rowIndexColumn;
                item.text = '';
            }
            var structuralTable = structuralTables[record.id];
            if (structuralTable != null) {
                item.kind = 'table';
                item.shape = 'table';
                item.sourceType = structuralTable.sourceType;
                item.rows = structuralTable.rows;
                item.columns = structuralTable.columns;
                item.cells = structuralTable.cells;
                item.rowWeights = structuralTable.rowWeights;
                item.columnWeights = structuralTable.columnWeights;
                item.tableTitle = structuralTable.tableTitle;
                item.tableTitleHeight = structuralTable.tableTitleHeight;
                item.fixedRows = structuralTable.fixedRows;
                item.rowLines = structuralTable.rowLines;
                item.firstRowLine = structuralTable.firstRowLine;
                item.rowIndexColumn = structuralTable.rowIndexColumn;
                item.reorderRows = structuralTable.reorderRows;
                item.tableBorder = structuralTable.tableBorder;
                item.gridStroke = structuralTable.gridStroke;
                item.container = false;
                item.childLayout = null;
                item.text = '';
            }
            if (shape === 'text') {
                if (!style.fillColor) item.fill = 'transparent';
                if (!style.strokeColor) { item.stroke = 'transparent'; item.strokeWidth = 0; }
            }
            if (shape === 'image' && style.image) {
                item.src = decodeLegacyUri(style.image);
                // imageAspect=0 is the classic "fill the cell" flag.
                item.imageFit = (style.imageAspect === '0') ? 'stretch' : 'contain';
                if (style.mediaType) item.mediaType = style.mediaType;
                if (style.mediaLoop != null) item.mediaLoop = style.mediaLoop !== '0';
                if (style.mediaVolume != null) item.mediaVolume = Math.max(0,
                    Math.min(1, Number(style.mediaVolume) / 100));
            }
            if (shape === 'swimlane') item.headerHeight = Number(style.startSize) || 26;
            if (style.size != null && ['trapezoid', 'parallelogram', 'hexagon', 'chevron',
                'step', 'cube', 'cylinder', 'note'].indexOf(shape) >= 0) {
                var legacySize = Number(style.size);
                if (legacySize > 1) {
                    legacySize /= shape === 'cylinder' ? geometry.height :
                        (shape === 'cube' || shape === 'note' ?
                            Math.min(geometry.width, geometry.height) : geometry.width);
                }
                item.shapeSize = legacySize;
            }
            if (shape === 'blockArrow' || shape === 'singleArrow' || shape === 'doubleArrow') {
                if (style.arrowSize != null) item.arrowSize = Number(style.arrowSize);
                if (style.arrowWidth != null) item.arrowWidth = Number(style.arrowWidth);
            }
            if (style.direction) item.direction = style.direction;
            if (style.line) item.line = style.line;
            ['top', 'right', 'bottom', 'left'].forEach(function(side) {
                if (style[side] != null) item[side] = style[side] !== '0';
            });
            if (style.size != null && ['manualInput', 'loopLimit', 'offPageConnector',
                'display', 'cross', 'corner', 'tee', 'datastore'].indexOf(shape) >= 0) {
                item.shapeSize = Number(style.size);
            }

            // A VisualScript wrapper is the node's value in the classic
            // editor. Preserve those attributes as live canvas data instead
            // of flattening the card into an ordinary rectangle with only its
            // label left behind.
            if (record.wrapper !== record.cell &&
                String(record.wrapper.nodeName).toLowerCase() === 'visualscript') {
                var visualAttrs = {};
                for (var va = 0; va < record.wrapper.attributes.length; va++) {
                    var visualAttribute = record.wrapper.attributes[va];
                    visualAttrs[visualAttribute.name] = visualAttribute.value;
                }
                item.kind = 'visualScript';
                item.vsType = visualAttrs.vsType || style.vsType || 'process';
                item.visualScript = visualAttrs;
                item.text = visualAttrs.label || item.text || item.vsType;
                item.shape = 'rect';
                item.fill = style.fillColor === 'none' ? 'transparent' : (style.fillColor || '#ffffff');
                item.radius = style.rounded === '1' ? (Number(style.arcSize) || 6) : 0;
                item.editable = false;

                for (var vd = 0; vd < VISUAL_SCRIPT_DEFINITIONS.length; vd++) {
                    if (VISUAL_SCRIPT_DEFINITIONS[vd].type !== item.vsType) continue;
                    var visualTemplate = visualScriptTemplate(VISUAL_SCRIPT_DEFINITIONS[vd]);
                    item.visualRows = visualTemplate.visualRows;
                    item.visualSummary = visualTemplate.visualSummary;
                    if (!style.strokeColor) item.stroke = visualTemplate.stroke;
                    if (!style.strokeWidth) item.strokeWidth = visualTemplate.strokeWidth;
                    break;
                }
            }
            if (style.childLayout && structuralTable == null) item.childLayout = style.childLayout;
            if (style.horizontal != null) item.horizontal = style.horizontal !== '0';
            if (style.horizontalStack != null) item.stackHorizontal = style.horizontalStack !== '0';
            if (style.resizeParent != null) item.resizeParent = style.resizeParent !== '0';
            if (style.resizeParentMax != null) item.resizeParentMax = style.resizeParentMax !== '0';
            else if (style.childLayout === 'stackLayout') item.resizeParentMax = true;
            if (style.resizeLast != null) item.resizeLast = style.resizeLast !== '0';
            if (style.stackSpacing != null) item.stackSpacing = Number(style.stackSpacing) || 0;
            if (style.stackBorder != null) item.stackBorder = Number(style.stackBorder) || 0;
            if (style.marginLeft != null) item.marginLeft = Number(style.marginLeft) || 0;
            if (style.marginRight != null) item.marginRight = Number(style.marginRight) || 0;
            if (style.marginTop != null) item.marginTop = Number(style.marginTop) || 0;
            if (style.marginBottom != null) item.marginBottom = Number(style.marginBottom) || 0;
            if (style.allowGaps != null) item.allowStackGaps = style.allowGaps !== '0';
            if (style.collapsible != null) item.collapsible = style.collapsible !== '0';
            var parentRecord = byId[record.parent];
            if (parentRecord && parentRecord.cell.getAttribute('vertex') === '1') {
                item.containerId = parentRecord.id;
            }
            items.push(item);
            importedIds[record.id] = true;
        });

        items.forEach(function(item) {
            if (!item.containerId) return;
            var parent = items.find(function(candidate) { return candidate.id === item.containerId; });
            if (parent) parent.container = true;
            else delete item.containerId;
        });

        items.forEach(function(item) {
            var record = byId[item.id];
            if (record && record.style.container === '1') item.container = true;
        });

        records.forEach(function(record) {
            if (record.cell.getAttribute('edge') !== '1') return;
            var style = record.style;
            var sourceId = record.cell.getAttribute('source');
            var targetId = record.cell.getAttribute('target');
            var legacyEdgeStyle = String(style.edgeStyle || '');
            var lineStyle = style.curved === '1' ? 'curved' :
                (/^(none|straight)$/i.test(legacyEdgeStyle) ? 'straight' :
                    (!legacyEdgeStyle || /orthogonal|elbow|segment|isometric/i.test(legacyEdgeStyle) ?
                        'orthogonal' : 'straight'));
            var edge = {
                id: record.id, type: 'edge', sourceId: importedIds[sourceId] ? sourceId : null,
                targetId: importedIds[targetId] ? targetId : null,
                sourceSide: 'east', targetSide: 'west', route: null,
                stroke: style.strokeColor || '#4f5968', strokeWidth: Number(style.strokeWidth) || 2,
                lineStyle: lineStyle,
                startArrow: style.startArrow || 'none', endArrow: style.endArrow || 'classic',
                dashed: style.dashed === '1', z: ++z, visible: true, previewPoints: []
            };
            if (style.exitX != null && style.exitY != null) {
                edge.sourceAnchor = { x: Number(style.exitX), y: Number(style.exitY) };
            }
            if (style.entryX != null && style.entryY != null) {
                edge.targetAnchor = { x: Number(style.entryX), y: Number(style.entryY) };
            }
            var points = [];
            if (record.geometry) {
                var pointNodes = record.geometry.getElementsByTagName('mxPoint');
                var sourcePoint = null, targetPoint = null, route = [];
                for (var p = 0; p < pointNodes.length; p++) {
                    var point = { x: numberAttribute(pointNodes[p], 'x', 0), y: numberAttribute(pointNodes[p], 'y', 0) };
                    var role = pointNodes[p].getAttribute('as');
                    if (role === 'sourcePoint') sourcePoint = point;
                    else if (role === 'targetPoint') targetPoint = point;
                    else route.push(point);
                }
                if (sourcePoint) edge.sourcePoint = sourcePoint;
                if (targetPoint) edge.targetPoint = targetPoint;
                if (route.length) edge.route = route;
                if (!edge.sourceId && !edge.targetId) {
                    if (sourcePoint) points.push(sourcePoint);
                    points.push.apply(points, route);
                    if (targetPoint) points.push(targetPoint);
                    edge.previewPoints = points;
                }
            }
            if ((edge.sourceId || edge.sourcePoint) &&
                (edge.targetId || edge.targetPoint)) items.push(edge);
        });

        if (items.length === 0) throw new Error('No drawable cells were found in this mxGraph document');
        return {
            format: 'pixel-graph-v2', viewport: { zoom: 1 },
            diagram: {
                gridEnabled: model.getAttribute('grid') !== '0',
                gridSize: Number(model.getAttribute('gridSize')) || 10,
                pageView: model.getAttribute('page') === '1',
                pageWidth: Number(model.getAttribute('pageWidth')) || 850,
                pageHeight: Number(model.getAttribute('pageHeight')) || 1100,
                pageScale: Number(model.getAttribute('pageScale')) || 1
            },
            items: items
        };
    }

    function Editor(container, options) {
        this.graph = new Graph(container, options || {});
        this.filename = 'pixel-diagram.json';
    }

    Editor.prototype.newDocument = function() {
        this.graph.loadItems([], true);
    };

    Editor.prototype.loadDemo = function() {
        var items = [
            {
                id: 'title', type: 'node', kind: 'shape', shape: 'rect',
                x: 72, y: 52, width: 340, height: 52, rotation: 0,
                fill: 'transparent', stroke: 'transparent', strokeWidth: 0,
                text: 'Life OS Dashboard', textColor: '#111111', fontSize: 26,
                fontWeight: 700, textAlign: 'left', z: 1, visible: true
            },
            {
                id: 'add', type: 'node', kind: 'shape', shape: 'rect',
                x: 82, y: 118, width: 88, height: 40, rotation: 0,
                fill: '#780000', stroke: '#310000', strokeWidth: 2,
                text: 'Add', textColor: '#ffffff', fontSize: 13,
                fontWeight: 700, radius: 5, z: 4, visible: true
            },
            {
                id: 'add-fixed', type: 'node', kind: 'shape', shape: 'rect',
                x: 180, y: 118, width: 104, height: 40, rotation: 0,
                fill: '#780000', stroke: '#310000', strokeWidth: 2,
                text: 'Add Fixed', textColor: '#ffffff', fontSize: 13,
                fontWeight: 700, radius: 5, z: 4, visible: true
            },
            Object.assign({
                id: 'tasks', type: 'node', x: 82, y: 164, rotation: 0,
                z: 3, visible: true
            }, JSON.parse(JSON.stringify(root.PixelNodeTemplates.taskList))),
            {
                id: 'panel-a', type: 'node', kind: 'shape', shape: 'rect',
                x: 355, y: 118, width: 285, height: 255, rotation: 0,
                fill: 'rgba(255,255,255,0.55)', stroke: '#3e454e', strokeWidth: 1,
                text: '', radius: 0, z: 1, visible: true
            },
            {
                id: 'panel-b', type: 'node', kind: 'shape', shape: 'rect',
                x: 640, y: 118, width: 470, height: 430, rotation: 0,
                fill: 'rgba(255,255,255,0.55)', stroke: '#3e454e', strokeWidth: 1,
                text: '', radius: 0, z: 1, visible: true
            },
            {
                id: 'test', type: 'node', kind: 'shape', shape: 'rect',
                x: 365, y: 120, width: 145, height: 66, rotation: 0,
                fill: '#780000', stroke: '#250000', strokeWidth: 3,
                text: 'Test', textColor: '#ffffff', fontSize: 13,
                fontWeight: 700, radius: 11, z: 5, visible: true, shadow: true
            },
            {
                id: 'docs', type: 'node', kind: 'shape', shape: 'rect',
                x: 545, y: 120, width: 145, height: 66, rotation: 0,
                fill: '#780000', stroke: '#250000', strokeWidth: 3,
                text: 'Important Docs for Tokyo Tech COE', textColor: '#ffffff',
                fontSize: 12, fontWeight: 700, radius: 11, z: 5, visible: true, shadow: true
            },
            {
                id: 'admission', type: 'node', kind: 'shape', shape: 'rect',
                x: 715, y: 120, width: 158, height: 66, rotation: 0,
                fill: '#780000', stroke: '#250000', strokeWidth: 3,
                text: 'Important Document for Admission Result', textColor: '#ffffff',
                fontSize: 12, fontWeight: 700, radius: 11, z: 5, visible: true, shadow: true
            }
        ];
        this.graph.loadItems(items, true);
        this.graph.setSelection(['tasks']);
    };

    Editor.prototype.addAtCenter = function(templateName) {
        return this.addTemplateAtCenter(root.PixelNodeTemplates[templateName] ||
            root.PixelNodeTemplates.process);
    };

    /* Drops a literal shape definition (scratchpad entry) in the viewport. */
    Editor.prototype.addTemplateAtCenter = function(template) {
        var view = this.graph.getViewState();
        var width = template.width || 160;
        var height = template.height || 80;
        var before = this.graph.snapshot();
        var node = this.graph.addTemplate(template, {
            x: (view.scrollX + view.width / 2) / this.graph.zoom - width / 2,
            y: (view.scrollY + view.height / 2) / this.graph.zoom - height / 2
        });
        this.graph.commit(before, 'Add Shape');
        return node;
    };

    Editor.prototype.downloadText = function(text, filename, mime) {
        var blob = new Blob([text], { type: mime || 'text/plain' });
        var link = document.createElement('a');
        link.href = URL.createObjectURL(blob);
        link.download = filename || this.filename;
        link.click();
        setTimeout(function() { URL.revokeObjectURL(link.href); }, 1000);
    };

    Editor.prototype.download = function() {
        this.downloadText(this.graph.toJSON(),
            this.filename.replace(/\.qochart$/i, '.json'), 'application/json');
    };

    Editor.prototype.openFile = function(file) {
        var reader = new FileReader();
        reader.onload = function() {
            try {
                var text = String(reader.result || '');
                // The format module adds round-trip metadata on top of the
                // importer, so a local .qochart can be saved back cleanly.
                var documentData = !/^\s*</.test(text) ? JSON.parse(text) :
                    (root.PixelMxGraphFormat ? root.PixelMxGraphFormat.parse(text) : importLegacyGraph(text));
                this.graph.fromJSON(documentData);
                this.filename = file.name || this.filename;
                this.graph.emit('toast', /^\s*</.test(text) ?
                    'Imported legacy qochart (' + documentData.items.length + ' objects)' : 'Diagram loaded');
            } catch (error) {
                console.error('Could not load diagram', error);
                this.graph.emit('toast', 'Could not load diagram: ' + error.message);
            }
        }.bind(this);
        reader.onerror = function() {
            this.graph.emit('toast', 'Could not read ' + (file.name || 'the selected file'));
        }.bind(this);
        reader.readAsText(file);
    };

    Editor.importLegacyGraph = importLegacyGraph;
    root.Editor = Editor;
})(window);
