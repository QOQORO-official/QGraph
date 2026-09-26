/* Classic geToolbar, driven by the pixel-native scene model. */
(function(root) {
    'use strict';

    function Toolbar(ui) {
        this.ui = ui;
        this.controls = Object.create(null);
    }

    Toolbar.prototype.button = function(container, sprite, title, action) {
        var button = document.createElement('a');
        button.className = 'geButton geSprite geSprite-' + sprite;
        button.setAttribute('title', title);
        button.setAttribute('aria-label', title);
        button.dataset.action = action;
        // Do not steal focus from an open label, so text commands can apply
        // to the selected range.
        button.addEventListener('mousedown', function(event) { event.preventDefault(); });
        button.addEventListener('click', function() { this.ui.actions.run(action); }.bind(this));
        container.appendChild(button);
        return button;
    };

    Toolbar.prototype.separator = function(container) {
        var separator = document.createElement('div');
        separator.className = 'geSeparator';
        container.appendChild(separator);
        return separator;
    };

    /* Menu button (sprite or text label) with a classic dropdown. */
    Toolbar.prototype.menu = function(container, element, entries) {
        var wrapper = document.createElement('div');
        wrapper.className = 'geMenuWrapper';
        wrapper.appendChild(element);
        wrapper.appendChild(this.ui.attachDropdown(element, entries));
        container.appendChild(wrapper);
        return element;
    };

    Toolbar.prototype.select = function(container, key, title, values, handler) {
        var select = document.createElement('select');
        select.className = 'geToolbarSelect';
        select.setAttribute('title', title);

        for (var i = 0; i < values.length; i++) {
            var option = document.createElement('option');
            option.value = values[i][0];
            option.textContent = values[i][1];
            select.appendChild(option);
        }

        select.addEventListener('change', function() { handler(select.value); });
        container.appendChild(select);
        this.controls[key] = select;
        return select;
    };

    Toolbar.prototype.color = function(container, key, sprite, title, property, fallback, predicate) {
        var wrapper = document.createElement('label');
        wrapper.className = 'geColorItem';
        wrapper.setAttribute('title', title);

        var glyph = document.createElement('span');
        glyph.className = 'geSprite geSprite-' + sprite;
        var input = document.createElement('input');
        input.type = 'color';
        input.value = fallback;
        // Live preview against the selection latched when the picker opened.
        this.ui.bindLiveStyle(input, function(value) {
            var changes = {};
            changes[property] = value;
            return changes;
        }, title, predicate);

        wrapper.appendChild(glyph);
        wrapper.appendChild(input);
        container.appendChild(wrapper);
        this.controls[key] = input;
        return input;
    };

    Toolbar.prototype.build = function(container) {
        var graph = this.ui.editor.graph;
        var nodes = function(item) { return item.type !== 'edge'; };
        var edges = function(item) { return item.type === 'edge'; };

        // View panels.
        var viewButton = document.createElement('a');
        viewButton.className = 'geButton geSprite geSprite-formatpanel';
        viewButton.setAttribute('title', 'View');
        this.menu(container, viewButton, ['sidebar', 'formatPanel', '-', 'grid', 'guides', 'pageView']);
        this.separator(container);

        // Zoom.
        this.controls.zoom = document.createElement('a');
        this.controls.zoom.className = 'geLabel';
        this.controls.zoom.setAttribute('title', 'Zoom');
        this.controls.zoom.style.minWidth = '36px';
        this.controls.zoom.style.textAlign = 'center';
        this.menu(container, this.controls.zoom, [
            'fit', 'actualSize', '-',
            { label: '50%', handler: function() { graph.setZoom(.5); } },
            { label: '75%', handler: function() { graph.setZoom(.75); } },
            { label: '100%', handler: function() { graph.setZoom(1); } },
            { label: '125%', handler: function() { graph.setZoom(1.25); } },
            { label: '150%', handler: function() { graph.setZoom(1.5); } },
            { label: '200%', handler: function() { graph.setZoom(2); } },
            { label: '400%', handler: function() { graph.setZoom(4); } }
        ]);
        this.separator(container);
        this.button(container, 'zoomin', 'Zoom In', 'zoomIn');
        this.button(container, 'zoomout', 'Zoom Out', 'zoomOut');

        this.separator(container);
        this.button(container, 'undo', 'Undo (Ctrl+Z)', 'undo');
        this.button(container, 'redo', 'Redo (Ctrl+Y)', 'redo');

        this.separator(container);
        this.button(container, 'delete', 'Delete', 'delete');
        this.button(container, 'duplicate', 'Duplicate (Ctrl+D)', 'duplicate');

        this.separator(container);
        this.button(container, 'tofront', 'To Front', 'toFront');
        this.button(container, 'toback', 'To Back', 'toBack');

        this.separator(container);
        this.color(container, 'fill', 'fillcolor', 'Fill Color', 'fill', '#ffffff', nodes);
        this.color(container, 'stroke', 'strokecolor', 'Line Color', 'stroke', '#4a5564');
        this.color(container, 'textColor', 'fontcolor', 'Font Color', 'textColor', '#172033', nodes);
        this.controls.shadow = this.button(container, 'shadow', 'Shadow', 'shadow');

        this.separator(container);
        var connectionButton = document.createElement('a');
        connectionButton.className = 'geButton geSprite geSprite-connection';
        connectionButton.setAttribute('title', 'Connector Style');
        this.menu(container, connectionButton, [
            { label: 'Orthogonal', handler: function() {
                graph.applyStyle({ lineStyle: 'orthogonal', route: null }, 'Connector Style', edges);
            } },
            { label: 'Straight', handler: function() {
                graph.applyStyle({ lineStyle: 'straight', route: null }, 'Connector Style', edges);
            } },
            { label: 'Curved', handler: function() {
                graph.applyStyle({ lineStyle: 'curved', route: null }, 'Connector Style', edges);
            } },
            { label: 'Circular Arc', handler: function() {
                graph.applyStyle({ lineStyle: 'circular', route: null, arcSweep: 180 },
                    'Connector Style', edges);
            } },
            { type: 'number', label: 'Arc Degrees', min: 1, max: 360, step: 1,
                value: function() {
                    var edge = graph.getSelection().filter(edges)[0];
                    return edge ? Math.round(Number(edge.arcSweep) || 180) : 180;
                },
                handler: function(value) {
                    graph.applyStyle({ lineStyle: 'circular', route: null, arcSweep: value },
                        'Circular Arc Degrees', edges);
                } },
            { label: 'Flip Circular Arc', handler: function() { graph.flipCircularArc(); } },
            '-', 'resetWaypoints', 'addWaypoint', 'reverseConnector'
        ]);

        this.separator(container);
        this.controls.bold = this.button(container, 'bold', 'Bold', 'bold');
        this.controls.italic = this.button(container, 'italic', 'Italic', 'italic');
        this.controls.underline = this.button(container, 'underline', 'Underline', 'underline');

        this.separator(container);
        this.button(container, 'left', 'Align Text Left', 'textLeft');
        this.button(container, 'center', 'Align Text Center', 'textCenter');
        this.button(container, 'right', 'Align Text Right', 'textRight');

        this.separator(container);
        this.select(container, 'fontFamily', 'Font Family', [
            ['Arial, sans-serif', 'Arial'], ['Helvetica, sans-serif', 'Helvetica'],
            ['Verdana, sans-serif', 'Verdana'], ['Georgia, serif', 'Georgia'],
            ['Courier New, monospace', 'Courier New']
        ], function(value) { graph.applyStyle({ fontFamily: value }, 'Font', nodes); });
        this.select(container, 'fontSize', 'Font Size', [
            ['10', '10'], ['12', '12'], ['14', '14'], ['16', '16'],
            ['18', '18'], ['24', '24'], ['32', '32'], ['48', '48']
        ], function(value) { graph.applyStyle({ fontSize: Number(value) }, 'Font Size', nodes); });
        this.select(container, 'strokeWidth', 'Line Width', [
            ['1', '1 pt'], ['1.5', '1.5 pt'], ['2', '2 pt'], ['3', '3 pt'], ['4', '4 pt'], ['6', '6 pt']
        ], function(value) { graph.applyStyle({ strokeWidth: Number(value) }, 'Line Width'); });

        graph.on('selectionchange', this.refresh.bind(this));
        graph.on('zoomchange', this.refresh.bind(this));
        this.refresh();
    };

    Toolbar.prototype.refresh = function() {
        var graph = this.ui.editor.graph;
        if (this.controls.zoom) this.controls.zoom.textContent = Math.round(graph.zoom * 100) + '%';

        var bindings = [
            ['fontFamily', 'fontFamily', 'Arial, sans-serif'],
            ['fontSize', 'fontSize', 14],
            ['strokeWidth', 'strokeWidth', 1.5]
        ];

        for (var i = 0; i < bindings.length; i++) {
            var control = this.controls[bindings[i][0]];
            if (!control) continue;
            var value = graph.getCommonStyle(bindings[i][1], bindings[i][2]);
            if (value !== '') control.value = String(value);
        }

        var colors = [['fill', 'fill', '#ffffff'], ['stroke', 'stroke', '#4a5564'], ['textColor', 'textColor', '#172033']];

        for (var c = 0; c < colors.length; c++) {
            var input = this.controls[colors[c][0]];
            var color = graph.getCommonStyle(colors[c][1], colors[c][2]);
            // Leave the swatch alone while its picker is open.
            if (input && input.geLiveEdit !== true && input !== document.activeElement &&
                /^#[0-9a-f]{6}$/i.test(color || '')) input.value = color;
        }

        var toggles = [['bold', graph.getCommonStyle('fontWeight', 400) >= 700],
            ['italic', graph.getCommonStyle('italic', false) === true],
            ['underline', graph.getCommonStyle('underline', false) === true],
            ['shadow', graph.getCommonStyle('shadow', false) === true]];

        for (var t = 0; t < toggles.length; t++) {
            if (this.controls[toggles[t][0]]) {
                this.controls[toggles[t][0]].classList.toggle('geChecked', toggles[t][1]);
            }
        }
    };

    root.Toolbar = Toolbar;
})(window);
