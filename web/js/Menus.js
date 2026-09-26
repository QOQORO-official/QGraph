/* Menubar definitions, rendered with the classic geMenubar markup. */
(function(root) {
    'use strict';

    function Menus(ui) {
        this.ui = ui;
        this.definitions = {
            // Match the classic GraphEditor hierarchy. Server/browser helper
            // commands stay available elsewhere instead of flooding File.
            File: ['new', 'open', '-', 'save', 'saveAs', '-',
                'export', '-', 'pageSetup', 'print'],
            Edit: ['undo', 'redo', '-', 'cut', 'copy', 'paste', 'pasteOfficeShapes', 'delete', '-',
                'duplicate', '-', 'editData', 'editTooltip', '-', 'editStyle', '-',
                'edit', '-', 'editLink', 'openLink', '-',
                'selectVertices', 'selectEdges', 'selectAll', 'selectNone', '-', 'lock'],
            View: ['sidebar', 'formatPanel', 'outline', 'layers', '-',
                'zoomIn', 'zoomOut', 'actualSize', '-',
                'fit', 'fitPage', 'fitPageWidth', 'resetView', '-',
                'grid', 'pageView', 'pageScale', 'connectionArrows', 'connectionPoints',
                'guides', 'tooltips'],
            Arrange: ['toFront', 'toBack', '-', 'group', 'ungroup', 'removeFromGroup',
                'enterGroup', 'exitGroup', 'collapseExpand', '-', 'lock', 'autosize', '-',
                'alignLeft', 'alignCenter', 'alignRight', 'alignTop', 'alignMiddle', 'alignBottom', '-',
                'distributeHorizontal', 'distributeVertical', '-', 'rotate90', 'flipHorizontal', 'flipVertical'],
            Extras: ['svgToMxGraph', '-', 'editCScript', 'runCScript', 'cscriptRunMode', '-',
                'portMode', 'addWaypoint', 'resetWaypoints', 'reverseConnector', '-',
                'solid', 'dashed', 'dotted', 'rounded', 'shadow', '-',
                'setDefaultStyle', 'clearDefaultStyle'],
            Help: ['about']
        };
    }

    Menus.prototype.build = function(container) {
        Object.keys(this.definitions).forEach(function(name) {
            var wrapper = document.createElement('div');
            wrapper.className = 'geMenuWrapper';

            var trigger = document.createElement('a');
            trigger.className = 'geItem';
            trigger.textContent = name;
            wrapper.appendChild(trigger);
            wrapper.appendChild(this.ui.attachDropdown(trigger, this.definitions[name]));

            container.appendChild(wrapper);
        }, this);
    };

    root.Menus = Menus;
})(window);
