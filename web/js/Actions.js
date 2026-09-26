/* Action registry for the pixel-native editor shell. */
(function(root) {
    'use strict';

    function Actions(ui) {
        this.ui = ui;
        this.map = Object.create(null);
        this.install();
    }

    Actions.prototype.add = function(name, label, handler, shortcut, checked) {
        this.map[name] = {
            name: name, label: label, handler: handler,
            shortcut: shortcut || '', checked: checked || null
        };
    };

    Actions.prototype.get = function(name) { return this.map[name] || null; };

    Actions.prototype.run = function(name) {
        var action = this.get(name);
        if (action) action.handler();
    };

    Actions.prototype.install = function() {
        var ui = this.ui;
        var graph = ui.editor.graph;
        var editor = ui.editor;
        this.add('new', 'New…', function() { editor.newDocument(); }, 'Ctrl+N');

        this.add('open', 'Open Diagram…', function() { ui.fileInput.click(); }, 'Ctrl+O');
        this.add('openFile', 'Open Local File…', function() { ui.fileInput.click(); });
        this.add('save', 'Save', function() { graph.saveLocal(); }, 'Ctrl+S');
        this.add('saveBrowser', 'Save in Browser', function() { graph.saveLocal(); });
        this.add('load', 'Load from Browser', function() { graph.loadLocal(); });
        this.add('download', 'Download JSON', function() { editor.download(); });
        this.add('exportPng', 'Export PNG', function() { graph.exportPng(); });
        this.add('export', 'Export…', function() { graph.exportPng(); });
        this.add('undo', 'Undo', function() { graph.undo(); }, 'Ctrl+Z');
        this.add('redo', 'Redo', function() { graph.redo(); }, 'Ctrl+Y');
        // Copy and cut also publish the selection to the system clipboard, so
        // an editor window served from another address can receive it.
        this.add('cut', 'Cut', function() {
            graph.copy();
            ui.writeSelectionToSystemClipboard();
            graph.removeSelection();
        }, 'Ctrl+X');
        this.add('copy', 'Copy', function() {
            graph.copy();
            ui.writeSelectionToSystemClipboard();
        }, 'Ctrl+C');
        this.add('paste', 'Paste', function() { graph.paste(); }, 'Ctrl+V');
        this.add('duplicate', 'Duplicate', function() { graph.duplicate(); }, 'Ctrl+D');
        this.add('delete', 'Delete', function() { graph.removeSelection(); }, 'Delete');
        this.add('selectAll', 'Select All', function() { graph.selectByType(null); }, 'Ctrl+A');
        this.add('selectVertices', 'Select Vertices', function() { graph.selectByType('node'); }, 'Ctrl+Shift+I');
        this.add('selectEdges', 'Select Edges', function() { graph.selectByType('edge'); }, 'Ctrl+Shift+E');
        this.add('toFront', 'To Front', function() { graph.changeZ(true); });
        this.add('toBack', 'To Back', function() { graph.changeZ(false); });
        this.add('group', 'Group', function() { graph.groupSelection(); }, 'Ctrl+G');
        this.add('ungroup', 'Ungroup', function() { graph.ungroupSelection(); }, 'Ctrl+Shift+G');
        this.add('lock', 'Lock/Unlock', function() { graph.toggleLock(); }, 'Ctrl+L');
        this.add('enterGroup', 'Enter Group', function() { graph.enterGroup(); });
        this.add('exitGroup', 'Exit Group', function() { graph.exitGroup(); }, 'Escape');
        this.add('removeFromGroup', 'Remove from Group', function() { graph.removeFromGroup(); });
        this.add('autosize', 'Autosize', function() { graph.autosizeSelection(); });
        this.add('copySize', 'Copy Size', function() { graph.copySize(); });
        this.add('pasteSize', 'Paste Size', function() { graph.pasteSize(); });
        this.add('clearLabels', 'Clear Labels', function() { graph.clearLabels(); });
        this.add('deleteAll', 'Delete All', function() { graph.deleteAll(); });
        this.add('selectNone', 'Select None', function() { graph.setSelection([]); }, 'Ctrl+Shift+A');
        this.add('pasteHere', 'Paste Here', function() { graph.paste(ui.contextPoint); });
        this.add('resetView', 'Reset View', function() { graph.resetView(); }, 'Ctrl+H');
        this.add('fitPage', 'Fit Page', function() { graph.fitPage(false); });
        this.add('fitPageWidth', 'Fit Page Width', function() { graph.fitPage(true); });
        this.add('pageSetup', 'Page Setup…', function() {
            graph.setSelection([]);
            if (ui.formatWidth === 0) {
                ui.formatWidth = 240;
                ui.refresh();
            }
            ui.updateFormatTabs(false);
            ui.selectFormatTab('diagram');
            var titles = ui.formatContainer.querySelectorAll('.geFormatTitle');
            for (var i = 0; i < titles.length; i++) {
                if (titles[i].textContent === 'Paper Size') {
                    titles[i].parentNode.scrollIntoView({ block: 'start' });
                    break;
                }
            }
        });
        this.add('print', 'Print…', function() { graph.print(); }, 'Ctrl+P');
        this.add('solid', 'Solid', function() {
            graph.applyStyle({ dashed: false, dashPattern: undefined }, 'Solid');
        });
        this.add('dashed', 'Dashed', function() {
            graph.applyStyle({ dashed: true, dashPattern: undefined }, 'Dashed');
        });
        this.add('dotted', 'Dotted', function() {
            graph.applyStyle({ dashed: true, dashPattern: [1, 3] }, 'Dotted');
        });
        this.add('rounded', 'Rounded', function() {
            graph.applyStyle({ radius: Number(graph.getCommonStyle('radius', 0)) > 0 ? 0 : 12 }, 'Rounded',
                function(item) { return item.type !== 'edge'; });
        });
        this.add('saveAs', 'Save As…', function() {
            var name = prompt('File name', editor.filename);
            if (name == null) return;
            editor.filename = /\.json$/i.test(name) ? name : name + '.json';
            editor.download();
        }, 'Ctrl+Shift+S');
        this.add('openLink', 'Open Link', function() {
            var item = graph.getSelection()[0];
            var cell = graph.getSelectedTableCell();
            var link = cell ? cell.cell.link : (item && item.link);
            if (link) graph.openLink(link);
            else ui.toast('The selection has no link');
        });
        this.add('editDiagram', 'Edit Diagram…', function() { ui.editDiagram(); });
        this.add('svgToMxGraph', 'SVG to mxGraph…', function() { ui.showSvgToMxGraphDialog(); });
        // Keep the historic action ids so old menus/shortcuts still resolve.
        this.add('editImage', 'Edit Media…', function() { ui.editMedia(); }, 'Alt+Shift+I');
        this.add('layers', 'Layers…', function() { ui.showLayers(); }, 'Ctrl+Shift+L');
        this.add('outline', 'Outline', function() { ui.toggleOutline(); });
        this.add('image', 'Insert Media…', function() { ui.insertMedia(); });
        this.add('collapseExpand', 'Collapse / Expand', function() { graph.toggleFold(); });
        this.add('tooltips', 'Tooltips', function() {
            graph.tooltipsEnabled = !graph.tooltipsEnabled;
            if (!graph.tooltipsEnabled) graph.hideTooltip();
            ui.toast(graph.tooltipsEnabled ? 'Tooltips on' : 'Tooltips off');
        });
        this.add('autosave', 'Autosave', function() { ui.toggleAutosave(); });
        this.add('pageScale', 'Page Scale…', function() {
            var value = prompt('Page scale (%)', Math.round(graph.pageScale * 100));
            if (value == null) return;
            var scale = Math.max(10, Math.min(400, Number(value) || 100)) / 100;
            graph.setDiagramOptions({ pageScale: scale });
        });
        this.add('addToScratchpad', 'Add to Scratchpad', function() { ui.sidebar.addToScratchpad(); });

        function selectedTable() {
            return graph.getSelection().filter(function(item) { return item.shape === 'table'; })[0];
        }

        this.add('insertTable', 'Insert Table', function() { editor.addAtCenter('table'); });
        this.add('insertHtml', 'Insert HTML Block…', function() { ui.editHtml(); });
        this.add('editHtml', 'Edit HTML…', function() { ui.editHtml(graph.getSelection()[0]); });
        this.add('tableAddRow', 'Insert Row', function() { graph.changeTableSize(selectedTable(), 1, 0); });
        this.add('tableRemoveRow', 'Delete Row', function() { graph.changeTableSize(selectedTable(), -1, 0); });
        this.add('tableAddColumn', 'Insert Column', function() { graph.changeTableSize(selectedTable(), 0, 1); });
        this.add('tableRemoveColumn', 'Delete Column', function() { graph.changeTableSize(selectedTable(), 0, -1); });
        this.add('tableInsertRowAbove', 'Insert Row Above', function() {
            var cell = graph.getSelectedTableCell();
            var table = cell ? cell.node : selectedTable();
            graph.insertTableRow(table, cell ? cell.startRow : 0);
        });
        this.add('tableInsertRowBelow', 'Insert Row Below', function() {
            var cell = graph.getSelectedTableCell();
            var table = cell ? cell.node : selectedTable();
            graph.insertTableRow(table, cell ? cell.endRow + 1 : (table ? table.rows : 0));
        });
        this.add('tableDeleteRow', 'Delete Row', function() {
            var cell = graph.getSelectedTableCell();
            graph.deleteTableRow(cell ? cell.node : selectedTable(), cell ? cell.startRow : null);
        });
        this.add('tableInsertColumnLeft', 'Insert Column Left', function() {
            var cell = graph.getSelectedTableCell();
            var table = cell ? cell.node : selectedTable();
            graph.insertTableColumn(table, cell ? cell.startColumn : 0);
        });
        this.add('tableInsertColumnRight', 'Insert Column Right', function() {
            var cell = graph.getSelectedTableCell();
            var table = cell ? cell.node : selectedTable();
            graph.insertTableColumn(table, cell ? cell.endColumn + 1 : (table ? table.columns : 0));
        });
        this.add('tableDeleteColumn', 'Delete Column', function() {
            var cell = graph.getSelectedTableCell();
            graph.deleteTableColumn(cell ? cell.node : selectedTable(), cell ? cell.startColumn : null);
        });
        this.add('tableMergeCells', 'Merge Cells', function() {
            var cell = graph.getSelectedTableCell();
            if (!cell) { ui.toast('Select a table cell first'); return; }
            if (!graph.mergeTableCells(cell.node, cell.startRow, cell.startColumn,
                cell.endRow, cell.endColumn)) ui.toast('No adjacent cell is available to merge');
        });
        this.add('tableUnmergeCell', 'Unmerge Cell', function() {
            var cell = graph.getSelectedTableCell();
            if (!cell || !graph.unmergeTableCell(cell.node, cell.row, cell.column)) {
                ui.toast('The selected cell is not merged');
            }
        });
        this.add('tableSplitCell', 'Split Cell', function() {
            var cell = graph.getSelectedTableCell();
            if (!cell || !graph.splitTableCell(cell.node, cell.row, cell.column)) {
                ui.toast('The selected cell is not merged');
            }
        });
        this.add('tableHeaderRow', 'Toggle Header Row', function() {
            var table = selectedTable();
            if (!table) { ui.toast('Select a table first'); return; }
            graph.applyStyle({
                headerRow: !table.headerRow,
                headerFill: table.headerFill || '#eef1f6'
            }, 'Header Row', function(item) { return item.shape === 'table'; });
        });
        this.add('editCell', 'Edit Cell…', function() {
            var table = selectedTable();
            if (!table) { ui.toast('Select a table first'); return; }
            var point = ui.contextPoint || { x: table.x + 1, y: table.y + 1 };
            var cell = graph.tableCellAt(table, point) ||
                graph.tableCellAt(table, { x: table.x + 1, y: table.y + 1 });
            if (cell) graph.startTextEdit(table, cell);
        });
        this.add('alignLeft', 'Align Left', function() { graph.alignSelection('left'); });
        this.add('alignCenter', 'Align Center', function() { graph.alignSelection('center'); });
        this.add('alignRight', 'Align Right', function() { graph.alignSelection('right'); });
        this.add('alignTop', 'Align Top', function() { graph.alignSelection('top'); });
        this.add('alignMiddle', 'Align Middle', function() { graph.alignSelection('middle'); });
        this.add('alignBottom', 'Align Bottom', function() { graph.alignSelection('bottom'); });
        this.add('distributeHorizontal', 'Distribute Horizontally', function() { graph.distributeSelection('horizontal'); });
        this.add('distributeVertical', 'Distribute Vertically', function() { graph.distributeSelection('vertical'); });
        this.add('rotate90', 'Rotate 90°', function() { graph.rotateSelection(90); });
        this.add('flipHorizontal', 'Flip Horizontal', function() { graph.flipSelection('horizontal'); });
        this.add('flipVertical', 'Flip Vertical', function() { graph.flipSelection('vertical'); });
        this.add('resetWaypoints', 'Reset Waypoints', function() { graph.resetWaypoints(); });
        this.add('addWaypoint', 'Add Waypoint', function() { graph.addWaypointToSelection(ui.contextPoint); });
        this.add('reverseConnector', 'Reverse Connector', function() { graph.reverseEdges(); });
        this.add('copyStyle', 'Copy Style', function() { graph.copyStyle(); }, 'Ctrl+Shift+C');
        this.add('pasteStyle', 'Paste Style', function() { graph.pasteStyle(); }, 'Ctrl+Shift+V');
        this.add('setBookmark', 'Set Bookmark', function() {
            var selected = graph.getSelection()[0];
            if (!selected) return;
            graph.applyStyle({ bookmark: true }, 'Set Bookmark');
            ui.toast('Bookmark set on ' + (selected.text || selected.id));
        }, 'Ctrl+Shift+R');
        this.add('setDefaultStyle', 'Set as Default Style', function() { graph.setDefaultStyle(); }, 'Ctrl+Shift+D');
        this.add('clearDefaultStyle', 'Clear Default Style', function() { graph.clearDefaultStyle(); });
        this.add('zoomIn', 'Zoom In', function() { graph.zoomIn(); }, 'Ctrl++');
        this.add('zoomOut', 'Zoom Out', function() { graph.zoomOut(); }, 'Ctrl+-');
        this.add('actualSize', 'Actual Size', function() { graph.zoomActual(); });
        this.add('fit', 'Fit Window', function() { graph.fit(); });
        this.add('grid', 'Toggle Grid', function() {
            graph.setDiagramOptions({ gridEnabled: !graph.gridEnabled });
            ui.toast(graph.gridEnabled ? 'Grid enabled' : 'Grid disabled');
        });
        this.add('pageView', 'Page View', function() {
            graph.setDiagramOptions({ pageView: !graph.pageView });
        }, '', function() { return graph.pageView; });
        this.add('connectionArrows', 'Connection Arrows', function() {
            graph.setDiagramOptions({ connectionArrows: !graph.connectionArrows });
            graph.drawOverlay();
        });
        this.add('connectionPoints', 'Connection Points', function() {
            graph.setDiagramOptions({ connectionPoints: !graph.connectionPoints });
            graph.drawOverlay();
        });
        this.add('guides', 'Guides', function() {
            graph.setDiagramOptions({ guidesEnabled: !graph.guidesEnabled });
        });
        this.add('sidebar', 'Shapes Panel', function() { ui.togglePane('sidebar'); });
        this.add('formatPanel', 'Format Panel', function() { ui.togglePane('inspector'); });
        this.add('portMode', 'Switch Port Mode (Unity)', function() {
            graph.portMode = graph.portMode === 'unity' ? 'outline' : 'unity';
            graph.drawOverlay();
            ui.toast('Port mode: ' + graph.portMode);
        });
        this.add('editText', 'Edit Text', function() {
            var cell = graph.getSelectedTableCell();
            if (cell) {
                graph.startTextEdit(cell.node, {
                    row: cell.row, column: cell.column,
                    x: cell.x, y: cell.y, width: cell.width, height: cell.height
                });
                return;
            }
            var selected = graph.getSelection()[0];
            if (selected) graph.startTextEdit(selected);
        });
        this.add('edit', 'Edit', function() {
            var cell = graph.getSelectedTableCell();
            if (cell) {
                graph.startTextEdit(cell.node, {
                    row: cell.row, column: cell.column,
                    x: cell.x, y: cell.y, width: cell.width, height: cell.height
                });
                return;
            }
            var selected = graph.getSelection()[0];
            if (selected) graph.startTextEdit(selected);
        }, 'F2 / Enter');
        this.add('editStyle', 'Edit Style…', function() { ui.editStyle(); }, 'Ctrl+E');
        this.add('editData', 'Edit Data…', function() { ui.editData(); }, 'Ctrl+M');
        this.add('editTooltip', 'Edit Tooltip…', function() {
            var selected = graph.getSelection()[0];
            if (!selected) return;
            var value = prompt('Tooltip', selected.tooltip || '');
            if (value == null) return;
            graph.applyStyle({ tooltip: value.trim() || undefined }, 'Edit Tooltip');
        }, 'Alt+Shift+T');
        this.add('editLink', 'Edit Link…', function() {
            if (graph.isEditingText()) {
                var textLink = prompt('Hyperlink for selected text (leave empty to remove)', 'https://');
                if (textLink == null) return;
                textLink = textLink.trim();
                graph.execTextCommand(textLink ? 'createLink' : 'unlink', textLink || null);
                return;
            }
            var selected = graph.getSelection();
            if (!selected.length) return;
            var selectedCell = graph.getSelectedTableCell();
            var value = prompt('Link URL (leave empty to remove)',
                (selectedCell ? selectedCell.cell.link : selected[0].link) || 'https://');
            if (value == null) return;
            value = value.trim();
            graph.applyStyle({ link: value || undefined }, value ? 'Edit Link' : 'Remove Link');
        }, 'Alt+Shift+L');
        // While a label is open these act on the selected range inside it,
        // exactly as the classic editor's text toolbar does.
        var nodes = function(item) { return item.type !== 'edge'; };
        this.add('bold', 'Bold', function() {
            if (graph.execTextCommand('bold')) return;
            graph.applyStyle({ fontWeight: graph.getCommonStyle('fontWeight', 400) >= 700 ? 400 : 700 }, 'Bold', nodes);
        }, 'Ctrl+B');
        this.add('italic', 'Italic', function() {
            if (graph.execTextCommand('italic')) return;
            graph.applyStyle({ italic: !graph.getCommonStyle('italic', false) }, 'Italic', nodes);
        }, 'Ctrl+I');
        this.add('underline', 'Underline', function() {
            if (graph.execTextCommand('underline')) return;
            graph.applyStyle({ underline: !graph.getCommonStyle('underline', false) }, 'Underline', nodes);
        }, 'Ctrl+U');
        this.add('strikethrough', 'Strikethrough', function() {
            if (graph.execTextCommand('strikeThrough')) return;
            graph.applyStyle({ strikethrough: !graph.getCommonStyle('strikethrough', false) }, 'Strikethrough', nodes);
        });
        this.add('subscript', 'Subscript', function() {
            if (!graph.execTextCommand('subscript')) ui.toast('Open a label to format part of it');
        });
        this.add('superscript', 'Superscript', function() {
            if (!graph.execTextCommand('superscript')) ui.toast('Open a label to format part of it');
        });
        this.add('unorderedlist', 'Bulleted List', function() {
            if (!graph.execTextCommand('insertUnorderedList')) ui.toast('Open a label to add a list');
        });
        this.add('orderedlist', 'Numbered List', function() {
            if (!graph.execTextCommand('insertOrderedList')) ui.toast('Open a label to add a list');
        });
        this.add('indent', 'Increase Indent', function() {
            if (!graph.execTextCommand('indent')) ui.toast('Open a label to indent it');
        });
        this.add('outdent', 'Decrease Indent', function() {
            if (!graph.execTextCommand('outdent')) ui.toast('Open a label to outdent it');
        });
        this.add('removeFormat', 'Clear Formatting', function() {
            if (graph.execTextCommand('removeFormat')) return;
            graph.applyStyle({
                richText: undefined, bold: undefined, italic: undefined,
                underline: undefined, strikethrough: undefined
            }, 'Clear Formatting', nodes);
        });
        this.add('textColor', 'Text Colour…', function() {
            var value = prompt('Text colour', graph.getCommonStyle('textColor', '#172033'));
            if (value == null) return;
            if (graph.execTextCommand('foreColor', value)) return;
            graph.applyStyle({ textColor: value }, 'Text Color', nodes);
        });
        this.add('shadow', 'Shadow', function() {
            graph.applyStyle({ shadow: !graph.getCommonStyle('shadow', false) }, 'Shadow',
                function(item) { return item.type !== 'edge'; });
        });
        this.add('textLeft', 'Align Text Left', function() {
            graph.applyStyle({ textAlign: 'left' }, 'Text Align', function(item) { return item.type !== 'edge'; });
        });
        this.add('textCenter', 'Align Text Center', function() {
            graph.applyStyle({ textAlign: 'center' }, 'Text Align', function(item) { return item.type !== 'edge'; });
        });
        this.add('textRight', 'Align Text Right', function() {
            graph.applyStyle({ textAlign: 'right' }, 'Text Align', function(item) { return item.type !== 'edge'; });
        });
        this.add('about', 'About Pixel Graph', function() {
            ui.showDialog('Pixel Graph',
                'A canvas-native diagram editor with worker culling, WebGPU/WebGL presentation, and Visio-like pixel controls. No SVG is used in the diagram viewport.');
        });
    };

    root.Actions = Actions;
})(window);
