/* Classic GraphEditor shell (menubar, toolbar, sidebar, hsplit, format
   panel, footer) hosting the pixel-native canvas diagram engine. The
   container markup and geometry match the original grapheditor exactly;
   only the diagram viewport is canvas instead of SVG. */
(function(root) {
    'use strict';

    function EditorUi(host) {
        this.container = host || document.body;
        this.container.className = 'geEditor';
        this.container.innerHTML = '';
        this.destroyFunctions = [];

        this.createDivs();
        this.refresh(false);

        this.editor = new Editor(this.diagram, { workerUrl: 'js/renderer-worker.js' });
        this.actions = new Actions(this);
        this.menus = new Menus(this);
        this.toolbar = new Toolbar(this);
        this.sidebar = new Sidebar(this);

        this.createUi();
        this.bind();
        this.refresh();

        // Start on a blank canvas. A host that wants a document supplies one.
        this.editor.newDocument();
        this.updateFormat();
        this.updateStatus();

        // Stencil libraries arrive asynchronously and fill in their palettes.
        this.editor.graph.on('stencilsloaded', function() {
            this.sidebar.addStencilPalettes();
        }.bind(this));
        var stencils = this.editor.graph.loadStencils(EditorUi.stencilLibraries);

        // Resolves once the shell is laid out, the first frame has been
        // painted and the stencil libraries have settled. Anything that opens
        // a document waits on this so it never races the first render.
        this.ready = new Promise(function(resolve) {
            var settle = function() {
                this.refresh();
                this.editor.graph.render();
                resolve(this);
            }.bind(this);

            Promise.resolve(stencils).catch(function() {}).then(function() {
                if (typeof requestAnimationFrame === 'function') requestAnimationFrame(settle);
                else setTimeout(settle, 0);
            });
        }.bind(this));
    }

    EditorUi.stencilLibraries = [
        'stencils/basic.xml',
        'stencils/arrows.xml',
        'stencils/flowchart.xml'
    ];

    /* Geometry of the classic shell. */
    EditorUi.prototype.menubarHeight = 30;
    EditorUi.prototype.toolbarHeight = 38;
    EditorUi.prototype.footerHeight = 28;
    EditorUi.prototype.formatWidth = 240;
    EditorUi.prototype.hsplitPosition = (screen.width <= 640) ? 118 : 212;
    EditorUi.prototype.splitSize = 12;
    EditorUi.prototype.hsplitClickEnabled = true;

    EditorUi.prototype.createDiv = function(classname) {
        var elt = document.createElement('div');
        elt.className = classname;
        return elt;
    };

    /* ------------------------------------------------------------------ */
    /* Containers                                                          */
    /* ------------------------------------------------------------------ */

    EditorUi.prototype.createDivs = function() {
        this.menubarContainer = this.createDiv('geMenubarContainer');
        this.toolbarContainer = this.createDiv('geToolbarContainer');
        this.sidebarContainer = this.createDiv('geSidebarContainer');
        this.formatContainer = this.createDiv('geSidebarContainer geFormatContainer');
        this.diagramContainer = this.createDiv('geDiagramContainer');
        this.footerContainer = this.createDiv('geFooterContainer');
        this.hsplit = this.createDiv('geHsplit');
        this.hsplit.setAttribute('title', 'Collapse/Expand');

        // Static styles, matching the classic container geometry.
        this.menubarContainer.style.top = '0px';
        this.menubarContainer.style.left = '0px';
        this.menubarContainer.style.right = '0px';
        this.toolbarContainer.style.left = '0px';
        this.toolbarContainer.style.right = '0px';
        this.sidebarContainer.style.left = '0px';
        this.formatContainer.style.right = '0px';
        this.formatContainer.style.zIndex = '1';
        this.diagramContainer.style.right = this.formatWidth + 'px';
        this.footerContainer.style.left = '0px';
        this.footerContainer.style.right = '0px';
        this.footerContainer.style.bottom = '0px';
        this.hsplit.style.width = this.splitSize + 'px';
        this.hsplit.style.touchAction = 'none';

        // The canvas engine owns everything inside the diagram container.
        this.diagram = document.createElement('div');
        this.diagramContainer.appendChild(this.diagram);

        this.container.appendChild(this.menubarContainer);
        this.container.appendChild(this.sidebarContainer);
        this.container.appendChild(this.formatContainer);
        this.container.appendChild(this.footerContainer);
        this.container.appendChild(this.diagramContainer);
        this.container.appendChild(this.toolbarContainer);
        this.container.appendChild(this.hsplit);

        this.fileInput = document.createElement('input');
        this.fileInput.type = 'file';
        this.fileInput.accept = '.json,.qochart,.xml,application/json,application/xml,text/xml';
        this.fileInput.hidden = true;
        this.container.appendChild(this.fileInput);

        this.toastElement = this.createDiv('geToast');
        this.toastElement.hidden = true;
        this.container.appendChild(this.toastElement);
    };

    EditorUi.prototype.createUi = function() {
        // Menubar with the application mark, menus and status label.
        this.menubar = this.createDiv('geMenubar');
        this.appMark = this.createDiv('geAppMark');
        this.appMark.textContent = 'P';
        this.appMark.title = 'Pixel Graph Editor';
        this.menubar.appendChild(this.appMark);
        this.menus.build(this.menubar);

        this.statusContainer = document.createElement('a');
        this.statusContainer.className = 'geItem geStatus';
        this.menubar.appendChild(this.statusContainer);

        this.documentTitle = this.createDiv('geDocumentTitle');
        this.documentTitle.textContent = 'Visual Script Editor — Canvas Native';
        this.menubar.appendChild(this.documentTitle);
        this.menubarContainer.appendChild(this.menubar);

        // Toolbar.
        this.toolbarElement = this.createDiv('geToolbar');
        this.toolbar.build(this.toolbarElement);
        this.toolbarContainer.appendChild(this.toolbarElement);

        // Shape palette and format panel.
        this.sidebar.build(this.sidebarContainer);
        this.buildFormat();
        this.buildFooter();
        this.buildContextMenu();

        this.addSplitHandler(this.hsplit, function(value) {
            this.hsplitPosition = value;
            this.refresh();
        }.bind(this));
    };

    EditorUi.prototype.buildFooter = function() {
        this.statusLeft = document.createElement('span');
        this.statusLeft.textContent = 'Ready';
        this.footerContainer.appendChild(this.statusLeft);
        this.statusRight = document.createElement('span');
        this.statusRight.className = 'geFooterRight';
        this.footerContainer.appendChild(this.statusRight);
    };

    /* ------------------------------------------------------------------ */
    /* Layout                                                              */
    /* ------------------------------------------------------------------ */

    EditorUi.prototype.refresh = function(sizeDidChange) {
        sizeDidChange = (sizeDidChange != null) ? sizeDidChange : true;

        var w = this.container.clientWidth;

        if (this.container === document.body) {
            w = document.body.clientWidth || document.documentElement.clientWidth;
        }

        var effHsplitPosition = Math.max(0, Math.min(this.hsplitPosition, w - this.splitSize - 20));
        var tmp = this.menubarHeight + this.toolbarHeight + 1;
        var fw = this.formatWidth;

        this.menubarContainer.style.height = this.menubarHeight + 'px';
        this.toolbarContainer.style.top = this.menubarHeight + 'px';
        this.toolbarContainer.style.height = this.toolbarHeight + 'px';

        this.sidebarContainer.style.top = tmp + 'px';
        this.sidebarContainer.style.width = effHsplitPosition + 'px';
        this.formatContainer.style.top = tmp + 'px';
        this.formatContainer.style.width = fw + 'px';
        this.formatContainer.style.display = (fw === 0) ? 'none' : '';

        this.diagramContainer.style.left = (effHsplitPosition + this.splitSize) + 'px';
        this.diagramContainer.style.top = tmp + 'px';
        this.footerContainer.style.height = this.footerHeight + 'px';
        this.hsplit.style.top = this.sidebarContainer.style.top;
        this.hsplit.style.bottom = this.footerHeight + 'px';
        this.hsplit.style.left = effHsplitPosition + 'px';
        this.footerContainer.style.display = (this.footerHeight === 0) ? 'none' : '';

        this.diagramContainer.style.right = fw + 'px';
        this.sidebarContainer.style.bottom = this.footerHeight + 'px';
        this.formatContainer.style.bottom = this.footerHeight + 'px';
        this.diagramContainer.style.bottom = this.footerHeight + 'px';

        if (sizeDidChange && this.editor != null) {
            this.editor.graph.render();
        }
    };

    /* Drag to resize, click to collapse/expand — as in the classic shell. */
    EditorUi.prototype.addSplitHandler = function(elt, onChange) {
        var start = null;
        var initial = null;
        var ignoreClick = true;
        var last = null;
        var self = this;

        function getValue() { return parseInt(elt.style.left, 10) || 0; }

        function moveHandler(evt) {
            if (start != null) {
                var x = (evt.touches != null && evt.touches.length > 0) ? evt.touches[0].clientX : evt.clientX;
                onChange(Math.max(0, initial + (x - start)));
                evt.preventDefault();

                if (initial !== getValue()) {
                    ignoreClick = true;
                    last = null;
                }
            }
        }

        function dropHandler(evt) {
            moveHandler(evt);
            initial = null;
            start = null;
        }

        elt.addEventListener('pointerdown', function(evt) {
            start = evt.clientX;
            initial = getValue();
            ignoreClick = false;
            evt.preventDefault();
        });

        elt.addEventListener('click', function(evt) {
            if (!ignoreClick && self.hsplitClickEnabled) {
                var next = (last != null) ? last : 0;
                last = getValue();
                onChange(next);
                evt.preventDefault();
            }
        });

        document.addEventListener('pointermove', moveHandler);
        document.addEventListener('pointerup', dropHandler);

        this.destroyFunctions.push(function() {
            document.removeEventListener('pointermove', moveHandler);
            document.removeEventListener('pointerup', dropHandler);
        });
    };

    EditorUi.prototype.togglePane = function(name) {
        if (name === 'sidebar') {
            if (this.hsplitPosition > 0) {
                this.lastHsplitPosition = this.hsplitPosition;
                this.hsplitPosition = 0;
            } else {
                this.hsplitPosition = this.lastHsplitPosition || 212;
            }
        } else {
            this.formatWidth = (this.formatWidth > 0) ? 0 : 240;
        }

        this.refresh();
    };

    /* ------------------------------------------------------------------ */
    /* Popup menus                                                         */
    /* ------------------------------------------------------------------ */

    /* Fills a popup with action names, '-' separators or literal entries. */
    EditorUi.prototype.addMenuItems = function(popup, entries) {
        entries.forEach(function(entry) {
            if (entry === '-') {
                popup.appendChild(document.createElement('hr'));
                return;
            }

            if (entry && entry.type === 'number') {
                var numberRow = document.createElement('label');
                numberRow.className = 'geMenuInputRow';
                numberRow.style.cssText = 'display:flex;align-items:center;gap:12px;' +
                    'padding:7px 12px;white-space:nowrap;';
                var numberLabel = document.createElement('span');
                numberLabel.textContent = entry.label;
                numberLabel.style.flex = '1';
                var numberInput = document.createElement('input');
                numberInput.type = 'number';
                numberInput.min = entry.min == null ? 1 : entry.min;
                numberInput.max = entry.max == null ? 360 : entry.max;
                numberInput.step = entry.step == null ? 1 : entry.step;
                numberInput.style.width = '72px';
                numberRow._syncValue = function() {
                    if (document.activeElement !== numberInput) {
                        numberInput.value = typeof entry.value === 'function' ? entry.value() : entry.value;
                    }
                };
                numberRow._syncValue();
                numberInput.addEventListener('pointerdown', function(event) { event.stopPropagation(); });
                numberInput.addEventListener('click', function(event) { event.stopPropagation(); });
                numberInput.addEventListener('keydown', function(event) { event.stopPropagation(); });
                numberInput.addEventListener('change', function(event) {
                    event.stopPropagation();
                    entry.handler(Number(numberInput.value));
                });
                numberRow.appendChild(numberLabel);
                numberRow.appendChild(numberInput);
                popup.appendChild(numberRow);
                return;
            }

            var action = (typeof entry === 'string') ? this.actions.get(entry) : null;
            var label = action ? action.label : entry.label;
            var shortcut = action ? action.shortcut : entry.shortcut;

            var item = document.createElement('button');
            item.className = 'geMenuItem';
            var text = document.createElement('span');
            if (action && typeof action.checked === 'function') {
                var check = document.createElement('input');
                check.type = 'checkbox';
                check.tabIndex = -1;
                check.className = 'geMenuCheckbox';
                check.setAttribute('aria-hidden', 'true');
                check.addEventListener('click', function(event) { event.preventDefault(); });
                text.appendChild(check);
                text.appendChild(document.createTextNode(label));
                item._syncCheck = function() { check.checked = action.checked() === true; };
                item._syncCheck();
            } else {
                text.textContent = label;
            }
            var keys = document.createElement('kbd');
            keys.textContent = shortcut || '';
            item.appendChild(text);
            item.appendChild(keys);
            item.addEventListener('click', function(event) {
                event.stopPropagation();
                this.closeMenus();
                this.hideContextMenu();

                if (action) {
                    this.actions.run(action.name);
                } else {
                    entry.handler();
                }
            }.bind(this));
            popup.appendChild(item);
        }, this);

        return popup;
    };

    /* Attaches a dropdown to the given trigger element. */
    EditorUi.prototype.attachDropdown = function(trigger, entries) {
        var popup = this.createDiv('geMenuDropdown');
        popup.hidden = true;
        popup._menuTrigger = trigger;
        if (!Array.isArray(this.menuPopups)) this.menuPopups = [];
        this.menuPopups.push(popup);
        this.addMenuItems(popup, entries);

        trigger.addEventListener('click', function(event) {
            event.stopPropagation();
            var wasOpen = !popup.hidden;
            this.closeMenus();

            if (!wasOpen) {
                // Portal the popup to the body. Toolbar containers deliberately
                // use overflow:hidden, so an absolutely positioned descendant
                // is clipped regardless of how large its z-index is.
                document.body.appendChild(popup);
                Array.prototype.forEach.call(popup.querySelectorAll('.geMenuItem,.geMenuInputRow'), function(item) {
                    if (typeof item._syncCheck === 'function') item._syncCheck();
                    if (typeof item._syncValue === 'function') item._syncValue();
                });
                var triggerRect = trigger.getBoundingClientRect();
                popup.style.left = Math.max(4, triggerRect.left) + 'px';
                popup.style.top = triggerRect.bottom + 'px';
                popup.hidden = false;
                trigger.classList.add('geMenuActive');

                // Keep the body-level menu inside the viewport and, when there
                // is more room, open it above a trigger near the bottom edge.
                var rect = popup.getBoundingClientRect();
                if (rect.right > window.innerWidth - 4) {
                    popup.style.left = Math.max(4, window.innerWidth - rect.width - 4) + 'px';
                }
                if (rect.bottom > window.innerHeight - 4 && triggerRect.top > rect.height + 4) {
                    popup.style.top = Math.max(4, triggerRect.top - rect.height) + 'px';
                }
            }
        }.bind(this));

        return popup;
    };

    EditorUi.prototype.closeMenus = function() {
        var menus = this.menuPopups || document.querySelectorAll('.geMenuDropdown');

        for (var i = 0; i < menus.length; i++) {
            menus[i].hidden = true;
            if (menus[i]._menuTrigger && menus[i]._menuTrigger.classList) {
                menus[i]._menuTrigger.classList.remove('geMenuActive');
            }
        }
    };

    EditorUi.prototype.buildContextMenu = function() {
        this.contextMenu = this.createDiv('geContextMenu');
        this.contextMenu.hidden = true;
        document.body.appendChild(this.contextMenu);
        this.contextMenuBaseEntries = [
            'delete', '-', 'cut', 'copy', '-', 'duplicate', 'setBookmark', '-',
            'setDefaultStyle', '-', 'toFront', 'toBack', '-',
            'editStyle', 'editData', 'editLink', 'editImage'
        ];
    };

    EditorUi.prototype.showContextMenu = function(data) {
        this.contextPoint = data.point && data.point.world;
        var tableCell = this.editor.graph.getSelectedTableCell();
        this.contextMenu.innerHTML = '';
        var entries = tableCell ? [
            'editCell', '-',
            'tableInsertRowAbove', 'tableInsertRowBelow', 'tableDeleteRow', '-',
            'tableInsertColumnLeft', 'tableInsertColumnRight', 'tableDeleteColumn', '-',
            'tableMergeCells', 'tableSplitCell', '-',
            'delete', 'cut', 'copy', '-', 'editStyle', 'editLink'
        ] : this.contextMenuBaseEntries;
        this.addMenuItems(this.contextMenu, entries);
        this.contextMenu.hidden = false;
        var width = this.contextMenu.offsetWidth;
        var height = this.contextMenu.offsetHeight;
        this.contextMenu.style.left = Math.max(4, Math.min(data.event.clientX, window.innerWidth - width - 4)) + 'px';
        this.contextMenu.style.top = Math.max(4, Math.min(data.event.clientY, window.innerHeight - height - 4)) + 'px';
    };

    EditorUi.prototype.hideContextMenu = function() {
        if (this.contextMenu) this.contextMenu.hidden = true;
    };

    /* ------------------------------------------------------------------ */
    /* Format panel                                                        */
    /* ------------------------------------------------------------------ */

    EditorUi.prototype.createFormatSection = function(panel, title) {
        var section = this.createDiv('geFormatSection');

        if (title != null) {
            var heading = this.createDiv('geFormatTitle');
            heading.textContent = title;
            section.appendChild(heading);
        }

        panel.appendChild(section);
        return section;
    };

    EditorUi.prototype.makeRow = function(section, labelText, input) {
        var row = document.createElement('label');
        row.className = 'geFormatRow';
        var label = document.createElement('span');
        label.textContent = labelText;
        row.appendChild(label);
        row.appendChild(input);
        section.appendChild(row);
        return row;
    };

    /* Diagram-level controls. Bound to input as well as change so dragging a
       colour wheel or a number spinner updates the canvas as it happens. */
    EditorUi.prototype.checkbox = function(section, key, label, handler) {
        var input = document.createElement('input');
        input.type = 'checkbox';
        input.addEventListener('change', function() { handler(input.checked); });
        this.makeRow(section, label, input);
        this.formatFields[key] = input;
        return input;
    };

    EditorUi.prototype.input = function(section, key, label, type, handler, options) {
        var input = document.createElement('input');
        input.type = type;
        options = options || {};
        Object.keys(options).forEach(function(name) { input[name] = options[name]; });
        input.addEventListener('input', function() { handler(input.value); });
        input.addEventListener('change', function() { handler(input.value); });
        this.makeRow(section, label, input);
        this.formatFields[key] = input;
        return input;
    };

    EditorUi.prototype.select = function(section, key, label, values, handler) {
        var select = document.createElement('select');
        values.forEach(function(info) {
            var option = document.createElement('option');
            option.value = info[0];
            option.textContent = info[1];
            select.appendChild(option);
        });
        select.addEventListener('change', function() { handler(select.value); });
        this.makeRow(section, label, select);
        this.formatFields[key] = select;
        return select;
    };

    /* Live style editing against a latched target.
     *
     * A native colour picker reports its value while it is open and again when
     * it closes, and the selection can change in between (the user clicks the
     * canvas, or adds a shape). Reading graph.getSelection() at event time
     * therefore writes to the wrong objects. Instead the target ids are
     * captured when the control is engaged, every intermediate value previews
     * against those ids, and the whole drag lands as one undo step.
     */
    EditorUi.prototype.bindLiveStyle = function(control, build, commitLabel, predicate, read) {
        var graph = this.editor.graph;
        var session = null;
        read = read || function() { return control.value; };

        function begin() {
            if (session != null || control.disabled) return;
            session = {
                ids: graph.getStyleTargetIds(predicate),
                before: graph.snapshot()
            };
            // While a session is open the control owns its own value, so a
            // refresh triggered by the edit cannot write over it.
            control.geLiveEdit = true;
        }

        function preview() {
            begin();
            if (session != null) graph.previewStyle(session.ids, build(read()));
        }

        function commit() {
            if (session == null) return;
            var open = session;
            session = null;
            graph.previewStyle(open.ids, build(read()));
            control.geLiveEdit = false;
            graph.commitPreview(open.before, commitLabel);
        }

        control.addEventListener('pointerdown', begin);
        control.addEventListener('focus', begin);
        control.addEventListener('keydown', begin);
        control.addEventListener('input', preview);
        control.addEventListener('change', commit);
        control.addEventListener('blur', commit);
        return control;
    };

    EditorUi.prototype.styleInput = function(section, key, label, type, build, commitLabel, predicate, options) {
        var input = document.createElement('input');
        input.type = type;
        options = options || {};
        Object.keys(options).forEach(function(name) { input[name] = options[name]; });
        this.makeRow(section, label, input);
        this.formatFields[key] = input;
        return this.bindLiveStyle(input, build, commitLabel, predicate);
    };

    EditorUi.prototype.styleCheckbox = function(section, key, label, build, commitLabel, predicate) {
        var input = document.createElement('input');
        input.type = 'checkbox';
        this.makeRow(section, label, input);
        this.formatFields[key] = input;
        return this.bindLiveStyle(input, build, commitLabel, predicate,
            function() { return input.checked; });
    };

    EditorUi.prototype.styleSelect = function(section, key, label, values, build, commitLabel, predicate) {
        var select = document.createElement('select');
        values.forEach(function(info) {
            var option = document.createElement('option');
            option.value = info[0];
            option.textContent = info[1];
            select.appendChild(option);
        });
        this.makeRow(section, label, select);
        this.formatFields[key] = select;
        return this.bindLiveStyle(select, build, commitLabel, predicate);
    };

    /* Row of classic sprite buttons, e.g. the alignment controls. */
    EditorUi.prototype.spriteRow = function(section, entries) {
        var row = this.createDiv('geFormatRow');
        row.style.justifyContent = 'flex-start';

        entries.forEach(function(entry) {
            var button = document.createElement('a');
            button.className = 'geButton geSprite geSprite-' + entry[0];
            button.style.cssText = 'display:inline-block;width:20px;height:20px;margin:2px;' +
                'opacity:0.6;cursor:pointer;border:1px solid transparent;';
            button.setAttribute('title', entry[1]);
            // Keeping focus in an open label is what lets these commands apply
            // to the selected range instead of closing the editor first.
            button.addEventListener('pointerdown', function(event) { event.preventDefault(); });
            button.addEventListener('mousedown', function(event) { event.preventDefault(); });
            button.addEventListener('click', function() { this.actions.run(entry[2]); }.bind(this));
            button.addEventListener('mouseenter', function() { button.style.opacity = '1'; });
            button.addEventListener('mouseleave', function() { button.style.opacity = '0.6'; });
            row.appendChild(button);
        }, this);

        section.appendChild(row);
        return row;
    };

    EditorUi.prototype.formatButton = function(section, label, handler) {
        var button = document.createElement('button');
        button.className = 'geBtn';
        button.textContent = label;
        button.addEventListener('click', handler);
        section.appendChild(button);
        return button;
    };

    EditorUi.prototype.buildFormat = function() {
        var graph = this.editor.graph;
        var fields = this.formatFields = Object.create(null);
        var nodesOnly = function(item) { return item.type !== 'edge'; };
        var edgesOnly = function(item) { return item.type === 'edge'; };

        this.formatTabs = this.createDiv('geFormatTabs');
        this.formatContainer.appendChild(this.formatTabs);

        this.formatPanels = {};
        this.formatTabButtons = {};

        function makePanel(name) {
            var panel = this.createDiv('geFormatPanel');
            panel.hidden = true;
            this.formatContainer.appendChild(panel);
            this.formatPanels[name] = panel;
            return panel;
        }

        function makeTab(name, label) {
            var tab = this.createDiv('geFormatTab');
            tab.textContent = label;
            tab.addEventListener('mousedown', function(event) { event.preventDefault(); });
            tab.addEventListener('click', function() { this.selectFormatTab(name); }.bind(this));
            this.formatTabs.appendChild(tab);
            this.formatTabButtons[name] = tab;
            return tab;
        }

        makeTab.call(this, 'diagram', 'Diagram');
        makeTab.call(this, 'style', 'Style');
        makeTab.call(this, 'text', 'Text');
        makeTab.call(this, 'arrange', 'Arrange');

        // Classic format-panel close affordance. Keep the original 9px PNG
        // and positioning so the control is familiar and does not consume a
        // full toolbar slot.
        var closeTab = this.createDiv('geFormatClose');
        var closeImage = document.createElement('img');
        closeImage.setAttribute('border', '0');
        closeImage.setAttribute('src', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAkAAAAJAQMAAADaX5RTAAAABlBMVEV7mr3///+wksspAAAAAnRSTlP/AOW3MEoAAAAdSURBVAgdY9jXwCDDwNDRwHCwgeExmASygSL7GgB12QiqNHZZIwAAAABJRU5ErkJggg==');
        closeImage.setAttribute('title', 'Hide');
        closeImage.setAttribute('alt', 'Hide');
        closeImage.style.position = 'absolute';
        closeImage.style.display = 'block';
        closeImage.style.right = '0px';
        closeImage.style.top = '8px';
        closeImage.style.cursor = 'pointer';
        closeImage.style.marginTop = '1px';
        closeImage.style.marginRight = '6px';
        closeImage.style.border = '1px solid transparent';
        closeImage.style.padding = '1px';
        closeImage.style.opacity = '0.5';
        closeImage.addEventListener('mouseenter', function() { closeImage.style.opacity = '1'; });
        closeImage.addEventListener('mouseleave', function() { closeImage.style.opacity = '0.5'; });
        closeImage.addEventListener('click', function(event) {
            event.stopPropagation();
            this.actions.run('formatPanel');
        }.bind(this));
        closeTab.appendChild(closeImage);
        this.formatTabs.appendChild(closeTab);

        var diagramPanel = makePanel.call(this, 'diagram');
        var stylePanel = makePanel.call(this, 'style');
        var textPanel = makePanel.call(this, 'text');
        var arrangePanel = makePanel.call(this, 'arrange');

        /* Diagram ------------------------------------------------------- */
        var view = this.createFormatSection(diagramPanel, 'View');
        this.checkbox(view, 'gridEnabled', 'Grid', function(value) { graph.setDiagramOptions({ gridEnabled: value }); });
        this.input(view, 'gridSize', 'Grid Size', 'number', function(value) {
            graph.setDiagramOptions({ gridSize: Math.max(2, Math.min(200, Number(value) || 10)) });
        }, { min: 2, max: 200, step: 1 });
        this.input(view, 'gridColor', 'Grid Color', 'color', function(value) { graph.setDiagramOptions({ gridColor: value }); });
        this.checkbox(view, 'pageView', 'Page View', function(value) { graph.setDiagramOptions({ pageView: value }); });
        this.input(view, 'backgroundColor', 'Background', 'color', function(value) {
            graph.setDiagramOptions({ backgroundColor: value });
        });

        var options = this.createFormatSection(diagramPanel, 'Options');
        this.checkbox(options, 'connectionArrows', 'Connection Arrows', function(value) {
            graph.setDiagramOptions({ connectionArrows: value }); graph.drawOverlay();
        });
        this.checkbox(options, 'connectionPoints', 'Connection Points', function(value) {
            graph.setDiagramOptions({ connectionPoints: value }); graph.drawOverlay();
        });
        this.checkbox(options, 'guidesEnabled', 'Guides', function(value) { graph.setDiagramOptions({ guidesEnabled: value }); });

        var paper = this.createFormatSection(diagramPanel, 'Paper Size');
        this.paperFormats = [
            ['850,1100', 'US Letter'], ['850,1400', 'US Legal'],
            ['1100,1700', 'US Tabloid'], ['700,1000', 'US Executive'],
            ['3300,4681', 'A0'], ['2339,3300', 'A1'], ['1654,2336', 'A2'],
            ['1169,1654', 'A3'], ['827,1169', 'A4'], ['583,827', 'A5'],
            ['413,583', 'A6'], ['291,413', 'A7'], ['980,1390', 'B4'],
            ['690,980', 'B5'], ['900,1600', '16:9'], ['1200,1920', '16:10'],
            ['1200,1600', '4:3'], ['custom', 'Custom']
        ];
        this.select(paper, 'paperSize', 'Size', this.paperFormats, function(value) {
            if (value === 'custom') return;
            var size = value.split(',');
            var width = Number(size[0]);
            var height = Number(size[1]);
            if (this.formatFields.landscape.checked) {
                var swap = width; width = height; height = swap;
            }
            graph.setDiagramOptions({ pageWidth: width, pageHeight: height });
        }.bind(this));
        this.checkbox(paper, 'landscape', 'Landscape', function(value) {
            var width = graph.pageWidth;
            var height = graph.pageHeight;
            if ((value && width < height) || (!value && width > height)) {
                graph.setDiagramOptions({ pageWidth: height, pageHeight: width });
            }
        });
        this.input(paper, 'pageWidth', 'Width (in)', 'number', function(value) {
            var width = Number(value);
            if (isFinite(width) && width > 0) {
                this.formatFields.paperSize.value = 'custom';
                graph.setDiagramOptions({ pageWidth: Math.round(width * 100) });
            }
        }.bind(this), { min: .5, max: 100, step: .01 });
        this.input(paper, 'pageHeight', 'Height (in)', 'number', function(value) {
            var height = Number(value);
            if (isFinite(height) && height > 0) {
                this.formatFields.paperSize.value = 'custom';
                graph.setDiagramOptions({ pageHeight: Math.round(height * 100) });
            }
        }.bind(this), { min: .5, max: 100, step: .01 });
        this.input(paper, 'pageScale', 'Page Scale (%)', 'number', function(value) {
            var scale = Number(value);
            if (isFinite(scale) && scale > 0) graph.setDiagramOptions({ pageScale: scale / 100 });
        }, { min: 10, max: 400, step: 5 });
        this.formatButton(paper, 'Edit Data…', this.editData.bind(this));
        this.formatButton(paper, 'Clear Default Style', function() { this.actions.run('clearDefaultStyle'); }.bind(this));

        /* Style --------------------------------------------------------- */
        var appearance = this.createFormatSection(stylePanel, 'Appearance');
        this.styleInput(appearance, 'fill', 'Fill', 'color',
            function(value) { return { fill: value }; }, 'Fill', nodesOnly);
        this.styleSelect(appearance, 'gradientDirection', 'Gradient', [
            ['', 'None'], ['vertical', 'Vertical'], ['horizontal', 'Horizontal'],
            ['radial', 'Radial'], ['diagonal', 'Diagonal']
        ], function(value) {
            return { gradientDirection: value || undefined, gradient: value ? undefined : undefined };
        }, 'Gradient', nodesOnly);
        this.styleInput(appearance, 'gradient', 'Gradient Color', 'color',
            function(value) { return { gradient: value }; }, 'Gradient Color', nodesOnly);
        this.styleInput(appearance, 'stroke', 'Line', 'color',
            function(value) { return { stroke: value }; }, 'Line Color');
        this.styleInput(appearance, 'strokeWidth', 'Line Width', 'number',
            function(value) { return { strokeWidth: Math.max(0, Number(value) || 0) }; },
            'Line Width', null, { min: 0, max: 24, step: .5 });
        this.styleInput(appearance, 'opacity', 'Opacity %', 'number',
            function(value) { return { opacity: Math.max(0, Math.min(1, Number(value) / 100)) }; },
            'Opacity', null, { min: 0, max: 100, step: 5 });
        this.styleInput(appearance, 'radius', 'Corner Radius', 'number',
            function(value) { return { radius: Math.max(0, Number(value) || 0) }; },
            'Corner Radius', nodesOnly, { min: 0, max: 80, step: 1 });
        this.styleCheckbox(appearance, 'dashed', 'Dashed',
            function(value) { return { dashed: value }; }, 'Dashed');
        this.styleCheckbox(appearance, 'shadow', 'Shadow',
            function(value) { return { shadow: value }; }, 'Shadow', nodesOnly);

        var connector = this.createFormatSection(stylePanel, 'Connector');
        var connectorRoute = this.styleSelect(connector, 'lineStyle', 'Route', [
            ['orthogonal', 'Orthogonal'], ['straight', 'Straight'], ['curved', 'Curved'],
            ['circular', 'Circular Arc']
        ], function(value) { return { lineStyle: value, route: null }; }, 'Connector Route', edgesOnly);
        var arcSweepInput = this.styleInput(connector, 'arcSweep', 'Arc Degrees', 'number',
            function(value) { return { arcSweep: Math.max(1, Math.min(360, Number(value) || 180)) }; },
            'Circular Arc Degrees', edgesOnly, { min: 1, max: 360, step: 1 });
        var arcSideInput = this.styleSelect(connector, 'arcSide', 'Arc Side', [
            ['1', 'Left / Clockwise'], ['-1', 'Right / Counterclockwise']
        ], function(value) { return { arcSide: Number(value) < 0 ? -1 : 1 }; },
        'Circular Arc Side', edgesOnly);
        fields.arcSweepRow = arcSweepInput.parentElement;
        fields.arcSideRow = arcSideInput.parentElement;
        var updateArcRows = function() {
            var visible = connectorRoute.value === 'circular';
            fields.arcSweepRow.hidden = !visible;
            fields.arcSideRow.hidden = !visible;
        };
        connectorRoute.addEventListener('input', updateArcRows);
        connectorRoute.addEventListener('change', updateArcRows);
        updateArcRows();
        var arrows = [['none', 'None'], ['block', 'Block'], ['open', 'Open'], ['oval', 'Oval'], ['diamond', 'Diamond']];
        this.styleSelect(connector, 'startArrow', 'Start Arrow', arrows,
            function(value) { return { startArrow: value }; }, 'Start Arrow', edgesOnly);
        this.styleSelect(connector, 'endArrow', 'End Arrow', arrows,
            function(value) { return { endArrow: value }; }, 'End Arrow', edgesOnly);
        this.styleInput(connector, 'arrowSize', 'Arrow Size', 'number',
            function(value) { return { arrowSize: Math.max(3, Number(value) || 9) }; },
            'Arrow Size', edgesOnly, { min: 3, max: 30, step: 1 });

        var styleActions = this.createFormatSection(stylePanel, null);

        // Edit Style and Edit Media sit side by side at 100px.
        fields.editStyleButton = this.formatButton(styleActions, 'Edit Style…', this.editStyle.bind(this));
        fields.editImageButton = this.formatButton(styleActions, 'Edit Media',
            function() { this.actions.run('editImage'); }.bind(this));
        fields.editImageButton.setAttribute('title', 'Edit Media');
        fields.editImageButton.style.width = '100px';
        fields.editImageButton.style.marginLeft = '2px';
        fields.editImageButton.hidden = true;

        this.formatButton(styleActions, 'Set as Default Style', function() { this.actions.run('setDefaultStyle'); }.bind(this));

        /* Text ---------------------------------------------------------- */
        var text = this.createFormatSection(textPanel, 'Font');
        this.styleSelect(text, 'fontFamily', 'Font', [
            ['Arial, sans-serif', 'Arial'], ['Helvetica, sans-serif', 'Helvetica'],
            ['Verdana, sans-serif', 'Verdana'], ['Georgia, serif', 'Georgia'],
            ['Courier New, monospace', 'Courier New']
        ], function(value) { return { fontFamily: value }; }, 'Font', nodesOnly);
        this.styleInput(text, 'fontSize', 'Size', 'number',
            function(value) { return { fontSize: Math.max(6, Number(value) || 14) }; },
            'Font Size', nodesOnly, { min: 6, max: 144, step: 1 });
        this.styleInput(text, 'textColor', 'Color', 'color',
            function(value) { return { textColor: value }; }, 'Text Color', nodesOnly);
        this.spriteRow(text, [
            ['bold', 'Bold', 'bold'], ['italic', 'Italic', 'italic'],
            ['underline', 'Underline', 'underline'],
            ['superscript', 'Superscript', 'superscript'],
            ['subscript', 'Subscript', 'subscript'],
            ['removeformat', 'Clear Formatting', 'removeFormat']
        ]);
        // These act on the selected range while a label is open for editing.
        this.spriteRow(text, [
            ['unorderedlist', 'Bulleted List', 'unorderedlist'],
            ['orderedlist', 'Numbered List', 'orderedlist'],
            ['indent', 'Increase Indent', 'indent'],
            ['outdent', 'Decrease Indent', 'outdent'],
            ['fontcolor', 'Text Colour', 'textColor']
        ]);
        this.styleCheckbox(text, 'strikethrough', 'Strikethrough',
            function(value) { return { strikethrough: value }; }, 'Strikethrough', nodesOnly);
        this.styleCheckbox(text, 'wordWrap', 'Word Wrap',
            function(value) { return { wordWrap: value }; }, 'Word Wrap', nodesOnly);

        var align = this.createFormatSection(textPanel, 'Alignment');
        this.styleSelect(align, 'textAlign', 'Horizontal', [
            ['left', 'Left'], ['center', 'Center'], ['right', 'Right']
        ], function(value) { return { textAlign: value }; }, 'Text Align', nodesOnly);
        this.styleSelect(align, 'verticalAlign', 'Vertical', [
            ['top', 'Top'], ['middle', 'Middle'], ['bottom', 'Bottom']
        ], function(value) { return { verticalAlign: value }; }, 'Vertical Align', nodesOnly);
        this.spriteRow(align, [
            ['left', 'Align Text Left', 'textLeft'],
            ['center', 'Align Text Center', 'textCenter'],
            ['right', 'Align Text Right', 'textRight']
        ]);

        /* Arrange ------------------------------------------------------- */
        var arrangeAlign = this.createFormatSection(arrangePanel, 'Align');
        this.spriteRow(arrangeAlign, [
            ['alignleft', 'Align Left', 'alignLeft'],
            ['aligncenter', 'Align Center', 'alignCenter'],
            ['alignright', 'Align Right', 'alignRight'],
            ['aligntop', 'Align Top', 'alignTop'],
            ['alignmiddle', 'Align Middle', 'alignMiddle'],
            ['alignbottom', 'Align Bottom', 'alignBottom']
        ]);
        this.spriteRow(arrangeAlign, [
            ['horizontalelbow', 'Distribute Horizontally', 'distributeHorizontal'],
            ['verticalelbow', 'Distribute Vertically', 'distributeVertical']
        ]);

        var order = this.createFormatSection(arrangePanel, 'Order');
        this.spriteRow(order, [
            ['tofront', 'To Front', 'toFront'],
            ['toback', 'To Back', 'toBack'],
            ['duplicate', 'Duplicate', 'duplicate'],
            ['delete', 'Delete', 'delete']
        ]);

        var group = this.createFormatSection(arrangePanel, 'Group');
        this.formatButton(group, 'Group', function() { this.actions.run('group'); }.bind(this));
        this.formatButton(group, 'Ungroup', function() { this.actions.run('ungroup'); }.bind(this));
        this.formatButton(group, 'Lock / Unlock', function() { this.actions.run('lock'); }.bind(this));

        var size = this.createFormatSection(arrangePanel, 'Size');
        this.styleInput(size, 'width', 'Width', 'number',
            function(value) { return { width: Math.max(1, Number(value) || 1) }; },
            'Width', nodesOnly, { min: 1, step: 1 });
        this.styleInput(size, 'height', 'Height', 'number',
            function(value) { return { height: Math.max(1, Number(value) || 1) }; },
            'Height', nodesOnly, { min: 1, step: 1 });
        this.styleInput(size, 'positionX', 'Position X', 'number',
            function(value) { return { x: Number(value) || 0 }; }, 'Position', nodesOnly, { step: 1 });
        this.styleInput(size, 'positionY', 'Position Y', 'number',
            function(value) { return { y: Number(value) || 0 }; }, 'Position', nodesOnly, { step: 1 });
        this.styleInput(size, 'rotation', 'Angle', 'number',
            function(value) { return { rotation: Number(value) || 0 }; },
            'Angle', nodesOnly, { min: -360, max: 360, step: 1 });

        var flip = this.createFormatSection(arrangePanel, 'Flip');
        this.formatButton(flip, 'Rotate 90°', function() { this.actions.run('rotate90'); }.bind(this));
        this.formatButton(flip, 'Flip Horizontal', function() { this.actions.run('flipHorizontal'); }.bind(this));
        this.formatButton(flip, 'Flip Vertical', function() { this.actions.run('flipVertical'); }.bind(this));

        fields.styleControls = Array.prototype.slice.call(
            stylePanel.querySelectorAll('input,select,button')).concat(
            Array.prototype.slice.call(textPanel.querySelectorAll('input,select,button')),
            Array.prototype.slice.call(arrangePanel.querySelectorAll('input,select,button')));

        this.selectFormatTab('diagram');
    };

    EditorUi.prototype.selectFormatTab = function(name) {
        if (this.formatPanels[name] == null || this.formatPanels[name].dataset.disabled === 'true') return;
        this.activeFormatTab = name;

        Object.keys(this.formatPanels).forEach(function(key) {
            this.formatPanels[key].hidden = key !== name;
            this.formatTabButtons[key].classList.toggle('geActiveTab', key === name);
        }, this);
    };

    /* Shows Diagram when nothing is selected, Style/Text/Arrange otherwise. */
    EditorUi.prototype.updateFormatTabs = function(hasSelection) {
        var visible = hasSelection ? ['style', 'text', 'arrange'] : ['diagram'];

        Object.keys(this.formatTabButtons).forEach(function(key) {
            var shown = visible.indexOf(key) >= 0;
            this.formatTabButtons[key].hidden = !shown;
            this.formatPanels[key].dataset.disabled = shown ? 'false' : 'true';
            if (!shown) this.formatPanels[key].hidden = true;
        }, this);

        if (visible.indexOf(this.activeFormatTab) < 0) {
            this.selectFormatTab(visible[0]);
        } else {
            this.selectFormatTab(this.activeFormatTab);
        }
    };

    /* ------------------------------------------------------------------ */
    /* Wiring                                                              */
    /* ------------------------------------------------------------------ */

    EditorUi.prototype.bind = function() {
        var graph = this.editor.graph;
        graph.on('stats', this.updateStatus.bind(this));
        graph.on('zoomchange', function() { this.updateStatus(); }.bind(this));
        graph.on('selectionchange', function(selection) {
            this.statusLeft.textContent = selection.length ?
                selection.length + ' object' + (selection.length === 1 ? '' : 's') + ' selected' : 'Ready';
            this.setStatusText(selection.length ? selection.length + ' selected' : '');
            this.updateFormat();
        }.bind(this));
        graph.on('diagramchange', this.updateFormat.bind(this));
        graph.on('toast', this.toast.bind(this));
        graph.on('contextmenu', this.showContextMenu.bind(this));

        this.fileInput.addEventListener('change', function() {
            if (this.fileInput.files[0]) this.editor.openFile(this.fileInput.files[0]);
            this.fileInput.value = '';
        }.bind(this));

        document.addEventListener('pointerdown', function(event) {
            if (event.target.closest('.geMenuWrapper') == null &&
                event.target.closest('.geMenuDropdown') == null) this.closeMenus();
            if (event.target.closest('.geContextMenu') == null) this.hideContextMenu();
        }.bind(this));

        document.addEventListener('keydown', function(event) {
            var mod = event.ctrlKey || event.metaKey;
            if (!mod || event.target.matches('input,textarea,select,[contenteditable]')) return;
            var key = event.key.toLowerCase();
            if (key === 's') { this.actions.run('save'); event.preventDefault(); }
            if (key === 'o') { this.actions.run('open'); event.preventDefault(); }
            if (key === 'n') { this.actions.run('new'); event.preventDefault(); }
            if (key === 'g') { this.actions.run(event.shiftKey ? 'ungroup' : 'group'); event.preventDefault(); }
            if (key === 'l') { this.actions.run('lock'); event.preventDefault(); }
            if (event.shiftKey && key === 'c') { this.actions.run('copyStyle'); event.preventDefault(); }
            if (event.shiftKey && key === 'v') { this.actions.run('pasteStyle'); event.preventDefault(); }
        }.bind(this));

        window.addEventListener('resize', this.refresh.bind(this, true));
    };

    EditorUi.prototype.setStatusText = function(value) {
        if (this.statusContainer) this.statusContainer.textContent = value || '';
    };

    EditorUi.prototype.updateFormat = function() {
        if (!this.formatFields) return;
        var graph = this.editor.graph;
        var f = this.formatFields;
        f.gridEnabled.checked = graph.gridEnabled;
        f.gridSize.value = graph.gridSize;
        f.gridColor.value = graph.gridColor;
        f.pageView.checked = graph.pageView;
        f.backgroundColor.value = graph.backgroundColor;
        f.connectionArrows.checked = graph.connectionArrows;
        f.connectionPoints.checked = graph.connectionPoints;
        f.guidesEnabled.checked = graph.guidesEnabled;
        f.landscape.checked = graph.pageWidth > graph.pageHeight;
        f.pageWidth.value = Math.round(graph.pageWidth) / 100;
        f.pageHeight.value = Math.round(graph.pageHeight) / 100;
        f.pageScale.value = Math.round(graph.pageScale * 100);

        var portraitWidth = Math.min(Math.round(graph.pageWidth), Math.round(graph.pageHeight));
        var portraitHeight = Math.max(Math.round(graph.pageWidth), Math.round(graph.pageHeight));
        var formatValue = portraitWidth + ',' + portraitHeight;
        var formatFound = (this.paperFormats || []).some(function(info) { return info[0] === formatValue; });
        f.paperSize.value = formatFound ? formatValue : 'custom';

        var selection = graph.getSelection();
        this.updateFormatTabs(selection.length > 0);
        f.styleControls.forEach(function(control) { control.disabled = selection.length === 0; });

        // Edit Media appears only for media, and then the pair splits the
        // row 100px/100px the way the classic panel did.
        var single = selection.length === 1 ? selection[0] : null;
        var isImage = single != null && (single.shape === 'image' || single.src != null);
        if (f.editImageButton) {
            f.editImageButton.hidden = !isImage;
            f.editStyleButton.style.width = isImage ? '100px' : '';
        }

        if (!selection.length) return;

        function common(key, fallback) { return graph.getCommonStyle(key, fallback); }

        // Never overwrite a control the user is holding open; a native colour
        // picker would otherwise be reset mid-drag.
        function busy(field) {
            return field == null || field.geLiveEdit === true || field === document.activeElement;
        }
        function set(field, value) { if (!busy(field)) field.value = value; }
        function toggle(field, value) { if (!busy(field)) field.checked = value; }
        function color(field, value) {
            if (/^#[0-9a-f]{6}$/i.test(value || '')) set(field, value);
        }

        color(f.fill, common('fill', '#ffffff'));
        color(f.gradient, common('gradient', '#ffffff'));
        set(f.gradientDirection, common('gradientDirection', '') || '');
        color(f.stroke, common('stroke', '#4a5564'));
        color(f.textColor, common('textColor', '#172033'));
        set(f.strokeWidth, common('strokeWidth', 1.5));
        set(f.opacity, Math.round(Number(common('opacity', 1)) * 100));
        set(f.radius, Math.round(Number(common('radius', 0))));
        toggle(f.dashed, common('dashed', false) === true);
        toggle(f.shadow, common('shadow', false) === true);
        set(f.fontFamily, common('fontFamily', 'Arial, sans-serif'));
        set(f.fontSize, common('fontSize', 14));
        toggle(f.strikethrough, common('strikethrough', false) === true);
        toggle(f.wordWrap, common('wordWrap', true) !== false);
        set(f.textAlign, common('textAlign', 'center'));
        set(f.verticalAlign, common('verticalAlign', 'middle'));
        set(f.lineStyle, common('lineStyle', 'orthogonal'));
        var circularRoute = common('lineStyle', 'orthogonal') === 'circular';
        if (f.arcSweepRow) f.arcSweepRow.hidden = !circularRoute;
        if (f.arcSideRow) f.arcSideRow.hidden = !circularRoute;
        set(f.arcSweep, Math.round(Number(common('arcSweep', 180))));
        set(f.arcSide, Number(common('arcSide', 1)) < 0 ? '-1' : '1');
        set(f.startArrow, common('startArrow', 'none'));
        set(f.endArrow, common('endArrow', 'block'));
        set(f.arrowSize, common('arrowSize', 9));
        set(f.width, Math.round(Number(common('width', 0))));
        set(f.height, Math.round(Number(common('height', 0))));
        set(f.positionX, Math.round(Number(common('x', 0))));
        set(f.positionY, Math.round(Number(common('y', 0))));
        set(f.rotation, Math.round(Number(common('rotation', 0))));
    };

    EditorUi.prototype.updateStatus = function(stats) {
        stats = stats || (this.editor && this.editor.graph.stats);
        if (!this.statusRight || !this.editor) return;
        var graph = this.editor.graph;
        var text = Math.round(graph.zoom * 100) + '%  •  SVG objects: 0';

        if (stats) {
            var memory = stats.pixelWidth * stats.pixelHeight * 4 / (1024 * 1024);
            text += '  •  ' + String(stats.backend || 'canvas').toUpperCase();
            text += stats.realtime ? ' realtime rAF' : stats.worker ? ' + Worker' : ' main thread';
            text += '  •  ' + stats.visible + '/' + stats.total + ' visible';
            text += '  •  ' + memory.toFixed(1) + ' MB framebuffer';
            text += '  •  ' + stats.renderMs + ' ms';
        }

        this.statusRight.textContent = text;
    };

    EditorUi.prototype.toast = function(message) {
        clearTimeout(this.toastTimer);
        this.toastElement.textContent = message;
        this.toastElement.hidden = false;
        this.toastTimer = setTimeout(function() { this.toastElement.hidden = true; }.bind(this), 2200);
    };

    EditorUi.prototype.showDialog = function(title, message) {
        var backdrop = this.createDiv('geDialogBackdrop');
        var dialog = this.createDiv('geDialog');
        var heading = document.createElement('h2');
        heading.textContent = title;
        var body = document.createElement('p');
        body.textContent = message;
        var close = document.createElement('button');
        close.className = 'geBtn gePrimaryBtn';
        close.style.float = 'right';
        close.textContent = 'Close';
        close.addEventListener('click', function() { backdrop.remove(); });
        dialog.appendChild(heading);
        dialog.appendChild(body);
        dialog.appendChild(close);
        backdrop.appendChild(dialog);
        document.body.appendChild(backdrop);
    };

    EditorUi.prototype.editStyle = function() {
        var graph = this.editor.graph;
        var item = graph.getSelection()[0];
        if (!item) return;
        var selectedCell = graph.getSelectedTableCell();
        var source = selectedCell ? selectedCell.cell : item;
        var style = {};
        Object.keys(source).forEach(function(key) {
            if (['id', 'type', 'x', 'y', 'width', 'height', 'sourceId', 'targetId',
                'route', 'text', 'tasks', 'groups', 'groupId'].indexOf(key) < 0) {
                style[key === 'align' && selectedCell ? 'textAlign' : key] = source[key];
            }
        });
        var value = prompt('Style JSON', JSON.stringify(style, null, 2));
        if (value == null) return;
        try { graph.applyStyle(JSON.parse(value), 'Edit Style'); }
        catch (error) { this.toast('Invalid style JSON: ' + error.message); }
    };

    /* ------------------------------------------------------------------ */
    /* Floating windows                                                    */
    /* ------------------------------------------------------------------ */

    /* Small draggable panel, the canvas stand-in for mxWindow. */
    EditorUi.prototype.createWindow = function(title, width, height, right, top) {
        var win = this.createDiv('geCanvasWindow');
        win.style.width = width + 'px';
        win.style.right = right + 'px';
        win.style.top = top + 'px';

        var bar = this.createDiv('geCanvasWindowTitle');
        bar.textContent = title;
        var close = document.createElement('button');
        close.className = 'geCanvasWindowClose';
        close.textContent = '×';
        close.setAttribute('title', 'Close');
        close.addEventListener('click', function() { win.hidden = true; });
        bar.appendChild(close);

        var body = this.createDiv('geCanvasWindowBody');
        if (height) body.style.height = height + 'px';
        win.appendChild(bar);
        win.appendChild(body);
        this.container.appendChild(win);

        // Drag by the title bar, kept inside the viewport.
        var start = null;
        bar.addEventListener('pointerdown', function(event) {
            if (event.target === close) return;
            var rect = win.getBoundingClientRect();
            start = { x: event.clientX, y: event.clientY, left: rect.left, top: rect.top };
            bar.setPointerCapture(event.pointerId);
        });
        bar.addEventListener('pointermove', function(event) {
            if (start == null) return;
            win.style.right = 'auto';
            win.style.left = Math.max(0, start.left + event.clientX - start.x) + 'px';
            win.style.top = Math.max(0, start.top + event.clientY - start.y) + 'px';
        });
        bar.addEventListener('pointerup', function() { start = null; });

        win.body = body;
        return win;
    };

    /* Layers ------------------------------------------------------------ */

    EditorUi.prototype.showLayers = function() {
        if (this.layersWindow == null) {
            this.layersWindow = this.createWindow('Layers', 230, 0, 260, 110);
            var footer = this.createDiv('geLayerButtons');
            var add = document.createElement('button');
            add.className = 'geBtn';
            add.textContent = 'Add';
            add.addEventListener('click', function() { this.editor.graph.addLayer(); }.bind(this));
            var move = document.createElement('button');
            move.className = 'geBtn';
            move.textContent = 'Move Here';
            move.setAttribute('title', 'Move the selection to the active layer');
            move.addEventListener('click', function() {
                this.editor.graph.moveSelectionToLayer(this.editor.graph.activeLayer);
            }.bind(this));
            footer.appendChild(add);
            footer.appendChild(move);
            this.layersWindow.appendChild(footer);
            this.editor.graph.on('layerchange', this.refreshLayers.bind(this));
        }

        this.layersWindow.hidden = false;
        this.refreshLayers();
    };

    EditorUi.prototype.refreshLayers = function() {
        if (this.layersWindow == null) return;
        var graph = this.editor.graph;
        var body = this.layersWindow.body;
        body.innerHTML = '';

        // Topmost layer first, matching how the classic dialog reads.
        graph.layers.slice().reverse().forEach(function(layer) {
            var row = this.createDiv('geLayerRow' + (layer.id === graph.activeLayer ? ' geLayerActive' : ''));

            var visible = document.createElement('input');
            visible.type = 'checkbox';
            visible.checked = layer.visible !== false;
            visible.title = 'Visible';
            visible.addEventListener('change', function() {
                graph.updateLayer(layer.id, { visible: visible.checked });
            });

            var name = document.createElement('span');
            name.className = 'geLayerName';
            name.textContent = layer.name + ' (' +
                graph.items.filter(function(item) { return item.layer === layer.id; }).length + ')';
            name.addEventListener('click', function() {
                graph.activeLayer = layer.id;
                this.refreshLayers();
            }.bind(this));
            name.addEventListener('dblclick', function() {
                var value = prompt('Layer name', layer.name);
                if (value) graph.updateLayer(layer.id, { name: value });
            });

            var lock = document.createElement('button');
            lock.className = 'geLayerIcon';
            lock.textContent = layer.locked ? '🔒' : '🔓';
            lock.title = 'Lock layer';
            lock.addEventListener('click', function() {
                graph.updateLayer(layer.id, { locked: !layer.locked });
            });

            var up = document.createElement('button');
            up.className = 'geLayerIcon';
            up.textContent = '▲';
            up.title = 'Move layer up';
            up.addEventListener('click', function() { graph.moveLayer(layer.id, 1); });

            var down = document.createElement('button');
            down.className = 'geLayerIcon';
            down.textContent = '▼';
            down.title = 'Move layer down';
            down.addEventListener('click', function() { graph.moveLayer(layer.id, -1); });

            var remove = document.createElement('button');
            remove.className = 'geLayerIcon';
            remove.textContent = '✕';
            remove.title = 'Delete layer and its objects';
            remove.addEventListener('click', function() { graph.removeLayer(layer.id); });

            row.appendChild(visible);
            row.appendChild(name);
            row.appendChild(lock);
            row.appendChild(up);
            row.appendChild(down);
            row.appendChild(remove);
            body.appendChild(row);
        }, this);
    };

    /* Outline ----------------------------------------------------------- */

    EditorUi.prototype.toggleOutline = function() {
        if (this.outlineWindow == null) {
            this.outlineWindow = this.createWindow('Outline', 220, 160, 260, 300);
            this.outlineCanvas = document.createElement('canvas');
            this.outlineCanvas.className = 'geOutlineCanvas';
            this.outlineWindow.body.appendChild(this.outlineCanvas);

            // Click or drag inside the thumbnail to scroll the diagram.
            var scrollTo = function(event) {
                var graph = this.editor.graph;
                var rect = this.outlineCanvas.getBoundingClientRect();
                var map = this.outlineMapping;
                if (map == null || rect.width === 0) return;
                var world = {
                    x: map.x + (event.clientX - rect.left) / map.scale,
                    y: map.y + (event.clientY - rect.top) / map.scale
                };
                var worldOriginX = graph.pageView ? 0 : (graph.worldOriginX || 0);
                var worldOriginY = graph.pageView ? 0 : (graph.worldOriginY || 0);
                graph.container.scrollLeft = (world.x + worldOriginX) * graph.zoom - graph.container.clientWidth / 2;
                graph.container.scrollTop = (world.y + worldOriginY) * graph.zoom - graph.container.clientHeight / 2;
            }.bind(this);

            var dragging = false;
            this.outlineCanvas.addEventListener('pointerdown', function(event) {
                dragging = true;
                this.outlineCanvas.setPointerCapture(event.pointerId);
                scrollTo(event);
            }.bind(this));
            this.outlineCanvas.addEventListener('pointermove', function(event) {
                if (dragging) scrollTo(event);
            });
            this.outlineCanvas.addEventListener('pointerup', function() { dragging = false; });

            var graph = this.editor.graph;
            var redraw = this.refreshOutline.bind(this);
            graph.on('change', redraw);
            graph.on('zoomchange', redraw);
            graph.on('stats', redraw);
            graph.container.addEventListener('scroll', redraw, { passive: true });
        } else {
            this.outlineWindow.hidden = !this.outlineWindow.hidden;
        }

        this.outlineWindow.hidden = false;
        this.refreshOutline();
    };

    EditorUi.prototype.refreshOutline = function() {
        if (this.outlineWindow == null || this.outlineWindow.hidden) return;
        var graph = this.editor.graph;
        var canvas = this.outlineCanvas;
        var width = canvas.clientWidth || 200;
        var height = canvas.clientHeight || 140;
        var ratio = Math.min(2, window.devicePixelRatio || 1);
        canvas.width = Math.round(width * ratio);
        canvas.height = Math.round(height * ratio);

        var ctx = canvas.getContext('2d');
        if (ctx == null) return;
        ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
        ctx.fillStyle = graph.backgroundColor || '#ffffff';
        ctx.fillRect(0, 0, width, height);

        var bounds = graph.getAllBounds();
        var margin = 12;
        var scale = Math.min((width - margin * 2) / Math.max(1, bounds.width),
            (height - margin * 2) / Math.max(1, bounds.height));
        var originX = bounds.x - margin / scale;
        var originY = bounds.y - margin / scale;
        this.outlineMapping = { x: originX, y: originY, scale: scale };

        if (this.outlinePainter == null) this.outlinePainter = new root.PixelScenePainter();
        var items = graph.items;
        this.outlinePainter.sync(items);
        ctx.save();
        ctx.scale(scale, scale);
        ctx.translate(-originX, -originY);
        var hidden = graph.hiddenLayerIds();

        this.outlinePainter.drawItems(ctx, items.filter(function(item) {
            if (item.visible === false || item.foldedAway) return false;
            return !(item.layer != null && hidden.indexOf(item.layer) >= 0);
        }));

        ctx.restore();

        // Viewport rectangle.
        var view = {
            x: graph.container.scrollLeft / graph.zoom -
                (graph.pageView ? 0 : (graph.worldOriginX || 0)),
            y: graph.container.scrollTop / graph.zoom -
                (graph.pageView ? 0 : (graph.worldOriginY || 0)),
            width: graph.container.clientWidth / graph.zoom,
            height: graph.container.clientHeight / graph.zoom
        };
        ctx.strokeStyle = '#00a8ff';
        ctx.lineWidth = 1.5;
        ctx.fillStyle = 'rgba(0, 168, 255, .12)';
        var rect = [(view.x - originX) * scale, (view.y - originY) * scale,
            view.width * scale, view.height * scale];
        ctx.fillRect(rect[0], rect[1], rect[2], rect[3]);
        ctx.strokeRect(rect[0], rect[1], rect[2], rect[3]);
    };

    /* Images and autosave ------------------------------------------------ */

    /* Edit Media.
     *
     * The classic button was a bare mxUtils.prompt for a URL: no file picker,
     * no preview, no way to tell a broken link from a slow one, and no control
     * over how the picture sits in its box. This dialog replaces it with a
     * live preview that reports load failures, a file picker and drop target
     * alongside the URL field, fit and alignment controls, and a one-click
     * reset to the image's natural aspect ratio.
     */
    EditorUi.prototype.editMedia = function(target) {
        var graph = this.editor.graph;
        var node = target || graph.getSelection().filter(function(item) {
            return item.shape === 'image';
        })[0] || graph.getSelection()[0];

        if (node == null) {
            this.toast('Select a shape to give it media');
            return;
        }

        var ui = this;
        var backdrop = this.createDiv('geDialogBackdrop');
        var dialog = this.createDiv('geDialog geMediaDialog');
        dialog.style.width = 'min(720px, calc(100vw - 32px))';

        var heading = document.createElement('h2');
        heading.textContent = 'Edit Media';

        function cleanLayer(layer) {
            layer = layer || {};
            var layerOpacity = layer.opacity == null ? 1 : Number(layer.opacity);
            return {
                src: String(layer.src || ''),
                mediaType: String(layer.mediaType || ''),
                depth: Math.max(0, Math.min(1, Number(layer.depth) || 0)),
                opacity: Math.max(0, Math.min(1, isFinite(layerOpacity) ? layerOpacity : 1)),
                scrollX: Number(layer.scrollX) || 0,
                scrollY: Number(layer.scrollY) || 0,
                previewSrc: null,
                previewObjectUrl: null,
                encoding: null,
                sourceLabel: ''
            };
        }

        var draft = {
            src: node.src || '',
            imageFit: node.imageFit || 'contain',
            imageAlign: node.imageAlign || 'center',
            imageVerticalAlign: node.imageVerticalAlign || 'middle',
            imageOpacity: node.imageOpacity == null ? 1 : node.imageOpacity,
            mediaType: node.mediaType || (root.PixelMedia ? root.PixelMedia.typeFor(node.src) : ''),
            mediaLoop: node.mediaLoop !== false,
            mediaVolume: node.mediaVolume == null ? 1 : node.mediaVolume,
            mediaLayers: (Array.isArray(node.mediaLayers) ? node.mediaLayers : []).map(cleanLayer),
            previewSrc: null,
            previewObjectUrl: null,
            encoding: null,
            sourceLabel: '',
            tooltip: node.tooltip || ''
        };
        var natural = null;

        function humanBytes(bytes) {
            bytes = Math.max(0, Number(bytes) || 0);
            if (bytes < 1024) return bytes + ' B';
            if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
            return (bytes / 1024 / 1024).toFixed(1) + ' MB';
        }

        function embeddedSize(src) {
            var comma = String(src || '').indexOf(',');
            return comma < 0 ? 0 : Math.round((src.length - comma - 1) * .75);
        }

        function sourceType(src, explicitType) {
            return explicitType || (root.PixelMedia ? root.PixelMedia.typeFor(src) : '');
        }

        function isYouTubeSource(src) {
            return root.PixelMedia != null && root.PixelMedia.isYouTube(src || '');
        }

        function isVideoSource(src, explicitType) {
            return root.PixelMedia != null && root.PixelMedia.isVideo(src || '', sourceType(src, explicitType));
        }

        function sourceSummary(src, explicitType, label) {
            if (label) return label;
            if (/^data:/i.test(src || '')) {
                var raw = String(src || '');
                var end = raw.indexOf(';') > 0 ? raw.indexOf(';') : raw.indexOf(',');
                var type = explicitType || raw.slice(5, end) || 'embedded media';
                return 'Embedded ' + type + ' · ' + humanBytes(embeddedSize(src)) + ' · source text hidden';
            }
            return String(src || '');
        }

        var url = document.createElement('input');
        url.className = 'geServerPathInput';
        url.type = 'text';
        url.placeholder = 'YouTube, MP4, WebM, image or GIF URL';

        function syncSourceField() {
            var locked = !!draft.sourceLabel || /^data:/i.test(draft.src);
            url.value = sourceSummary(draft.src, draft.mediaType, draft.sourceLabel);
            url.readOnly = locked;
            url.classList.toggle('geMediaSourceSummary', locked);
        }

        var replaceUrl = document.createElement('button');
        replaceUrl.className = 'geBtn geMediaReplaceButton';
        replaceUrl.textContent = 'Replace URL…';

        var sourceRow = this.createDiv('geMediaSourceRow');
        sourceRow.appendChild(url);
        sourceRow.appendChild(replaceUrl);
        syncSourceField();

        var picker = document.createElement('input');
        picker.type = 'file';
        picker.accept = 'image/*,video/mp4,video/webm,.mp4,.webm';
        picker.hidden = true;

        var layerPicker = document.createElement('input');
        layerPicker.type = 'file';
        layerPicker.accept = 'image/*,video/mp4,video/webm,.mp4,.webm';
        layerPicker.multiple = true;
        layerPicker.hidden = true;

        var preview = this.createDiv('geImagePreview');
        var previewCanvas = document.createElement('canvas');
        var previewNote = this.createDiv('geImageNote');
        preview.appendChild(previewCanvas);
        preview.appendChild(previewNote);

        var previewPainter = new root.PixelScenePainter();
        var previewFrame = null;
        var previewState = null;
        var previewDirty = true;
        var lastPreviewPaint = 0;
        this.editImagePreviewPainter = previewPainter;
        previewPainter.playback = graph.playback || null;
        previewPainter.mediaPlayback = graph.mediaPlayback || null;

        function activeSource() { return draft.previewSrc || draft.src; }
        function activeMediaType() { return sourceType(activeSource(), draft.mediaType); }
        function isVideo() { return isVideoSource(activeSource(), activeMediaType()); }

        function previewLayers() {
            return draft.mediaLayers.filter(function(layer) {
                return !!(layer.previewSrc || layer.src);
            }).map(function(layer) {
                return {
                    src: layer.previewSrc || layer.src,
                    mediaType: sourceType(layer.previewSrc || layer.src, layer.mediaType),
                    depth: layer.depth,
                    opacity: layer.opacity,
                    scrollX: layer.scrollX,
                    scrollY: layer.scrollY
                };
            });
        }

        function persistentLayers() {
            return draft.mediaLayers.filter(function(layer) { return !!layer.src; }).map(function(layer) {
                return {
                    src: layer.src,
                    mediaType: sourceType(layer.src, layer.mediaType),
                    depth: Math.max(0, Math.min(1, Number(layer.depth) || 0)),
                    opacity: Math.max(0, Math.min(1, layer.opacity == null ? 1 : Number(layer.opacity) || 0)),
                    scrollX: Number(layer.scrollX) || 0,
                    scrollY: Number(layer.scrollY) || 0
                };
            });
        }

        function describe(state, message) {
            previewNote.textContent = message;
            previewNote.className = 'geImageNote ' + state;
        }

        function layerPlaybackBusy(layer) {
            var src = layer.previewSrc || layer.src;
            if (!src) return false;
            if (isVideoSource(src, layer.mediaType)) return true;
            if ((Number(layer.scrollX) || Number(layer.scrollY))) return true;
            var loaded = previewPainter.images.get(src);
            return loaded == null || previewPainter.isAnimated(src);
        }

        function paintPreview() {
            var ratio = Math.min(2, window.devicePixelRatio || 1);
            var width = preview.clientWidth || 640;
            var height = preview.clientHeight || 210;
            var boxWidth = Math.max(20, width - 16);
            var boxHeight = Math.max(20, height - 32);

            if (previewCanvas.width !== Math.round(width * ratio) ||
                previewCanvas.height !== Math.round(height * ratio)) {
                previewCanvas.width = Math.round(width * ratio);
                previewCanvas.height = Math.round(height * ratio);
                previewCanvas.style.width = width + 'px';
                previewCanvas.style.height = height + 'px';
            }

            var ctx = previewCanvas.getContext('2d');
            if (ctx == null) return;
            ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
            ctx.clearRect(0, 0, width, height);
            var source = activeSource();
            if (!source) return;

            var layers = previewLayers();
            if (isYouTubeSource(source)) {
                ctx.fillStyle = '#111';
                ctx.fillRect(8, 8, boxWidth, boxHeight);
                ctx.fillStyle = '#ff0033';
                ctx.font = 'bold 22px Arial, sans-serif';
                ctx.textAlign = 'center';
                ctx.textBaseline = 'middle';
                ctx.fillText('YouTube', 8 + boxWidth / 2, 8 + boxHeight / 2 - 8);
                ctx.fillStyle = '#fff';
                ctx.font = '11px Arial, sans-serif';
                ctx.fillText(layers.length ? 'Parallax layers require image/MP4/WebM base media' :
                    'Streams in real time after Apply', 8 + boxWidth / 2, 8 + boxHeight / 2 + 16);
                natural = { width: 16, height: 9 };
                previewState = 'ok';
                describe(layers.length ? 'geImageError' : 'geImageOk', layers.length ?
                    'YouTube cannot be canvas-composited with parallax layers. Use MP4/WebM instead.' :
                    'YouTube · real-time streaming · no download');
                return;
            }

            previewPainter.scanForAnimation([{
                id: 'media-preview', src: source, mediaType: activeMediaType(), mediaLayers: layers
            }]);
            previewPainter.drawImageNode(ctx, {
                x: 8, y: 8, width: boxWidth, height: boxHeight,
                src: source, mediaType: activeMediaType(), mediaLoop: draft.mediaLoop,
                imageFit: draft.imageFit,
                imageAlign: draft.imageAlign,
                imageVerticalAlign: draft.imageVerticalAlign,
                imageOpacity: draft.imageOpacity,
                mediaLayers: layers
            });

            var mediaState = isVideo() && previewPainter.mediaPlayback ?
                previewPainter.mediaPlayback.stateFor(source) : null;
            var loaded = isVideo() ? (mediaState && mediaState.ready ? mediaState.video :
                (mediaState && mediaState.failed ? false : null)) : previewPainter.images.get(source);
            var nextState = loaded === false ? 'error' : (loaded ? 'ok' : 'loading');

            if (nextState !== previewState || previewDirty) {
                previewState = nextState;
                if (nextState === 'error') {
                    describe('geImageError', 'That base media could not be loaded. Check the URL or choose a file.');
                } else if (nextState === 'loading') {
                    describe('geImageEmpty', 'Loading base media' + (layers.length ? ' + ' + layers.length + ' layer(s)…' : '…'));
                } else {
                    natural = {
                        width: loaded.videoWidth || loaded.naturalWidth || loaded.width,
                        height: loaded.videoHeight || loaded.naturalHeight || loaded.height
                    };
                    describe('geImageOk', natural.width + ' × ' + natural.height + ' px' +
                        (isVideo() ? ' · streaming video' :
                            (previewPainter.isAnimated(source) ? ' · animated' : '')) +
                        (layers.length ? ' · ' + layers.length + ' parallax layer(s)' : ''));
                }
            }
        }

        function tick(now) {
            previewFrame = requestAnimationFrame(tick);
            var source = activeSource();
            var loaded = source ? previewPainter.images.get(source) : false;
            var animated = source && (isVideo() || previewPainter.isAnimated(source));
            var layerBusy = draft.mediaLayers.some(layerPlaybackBusy);
            var easing = Math.abs(previewPainter.parallaxTarget.x - previewPainter.parallax.x) > .001 ||
                Math.abs(previewPainter.parallaxTarget.y - previewPainter.parallax.y) > .001;
            if ((animated || layerBusy) && previewPainter.playback != null) previewPainter.playback.tick();
            var busy = source && (loaded == null || animated || layerBusy || easing);
            if (previewDirty || (busy && (!lastPreviewPaint || now - lastPreviewPaint >= 66))) {
                previewDirty = false;
                lastPreviewPaint = now || 0;
                paintPreview();
            }
        }

        var loopRow = null;
        var volumeRow = null;
        function loadPreview() {
            natural = null;
            previewState = null;
            previewDirty = true;
            if (loopRow) loopRow.hidden = !isVideo();
            if (volumeRow) volumeRow.hidden = !isVideo();

            if (!activeSource()) {
                describe('geImageEmpty', 'No base media yet — paste a URL or choose an image, GIF, MP4 or WebM file.');
                paintPreview();
                return;
            }
            paintPreview();
        }

        function cleanupDraftSource(owner) {
            if (owner.previewSrc && graph.mediaPlayback) graph.mediaPlayback.remove(owner.previewSrc);
            if (owner.previewObjectUrl) URL.revokeObjectURL(owner.previewObjectUrl);
            owner.previewSrc = null;
            owner.previewObjectUrl = null;
            owner.encoding = null;
            owner.sourceLabel = '';
        }

        function validMediaFile(file) {
            return file != null && (/^(image\/|video\/(?:mp4|webm)$)/i.test(file.type || '') ||
                /\.(mp4|webm)$/i.test(file.name || ''));
        }

        function encodeFileInto(owner, file, after) {
            if (!validMediaFile(file)) {
                describe('geImageError', 'Choose an image, GIF, MP4 or WebM file.');
                return;
            }
            cleanupDraftSource(owner);
            owner.previewObjectUrl = URL.createObjectURL(file);
            owner.previewSrc = owner.previewObjectUrl;
            owner.mediaType = file.type || sourceType(file.name, '');
            owner.sourceLabel = file.name + ' · ' + humanBytes(file.size) + ' · buffering in worker';
            if (!draft.tooltip) draft.tooltip = file.name;
            if (after) after();
            loadPreview();

            var encoder = root.PixelMedia ? root.PixelMedia.encodeFile(file) : Promise.reject();
            owner.encoding = encoder.then(function(result) {
                owner.src = String(result || '');
                owner.sourceLabel = file.name + ' · ' + humanBytes(file.size) + ' · embedded';
                owner.encoding = null;
                if (after) after();
                previewDirty = true;
                return owner.src;
            }).catch(function() {
                return new Promise(function(resolve, reject) {
                    var reader = new FileReader();
                    reader.onload = function() {
                        owner.src = String(reader.result || '');
                        owner.sourceLabel = file.name + ' · ' + humanBytes(file.size) + ' · embedded';
                        owner.encoding = null;
                        if (after) after();
                        previewDirty = true;
                        resolve(owner.src);
                    };
                    reader.onerror = reject;
                    reader.readAsDataURL(file);
                });
            });
        }

        url.addEventListener('change', function() {
            if (url.readOnly) return;
            draft.src = url.value.trim();
            draft.mediaType = sourceType(draft.src, '');
            draft.sourceLabel = '';
            loadPreview();
        });
        url.addEventListener('input', function() {
            if (url.readOnly) return;
            draft.src = url.value.trim();
            draft.mediaType = sourceType(draft.src, '');
            previewDirty = true;
        });

        replaceUrl.addEventListener('click', function() {
            cleanupDraftSource(draft);
            draft.src = '';
            draft.mediaType = '';
            syncSourceField();
            url.focus();
            loadPreview();
        });

        picker.addEventListener('change', function() {
            encodeFileInto(draft, picker.files[0], syncSourceField);
            picker.value = '';
        });
        preview.addEventListener('dragover', function(event) {
            event.preventDefault();
            preview.classList.add('geImageDropActive');
        });
        preview.addEventListener('dragleave', function() {
            preview.classList.remove('geImageDropActive');
        });
        preview.addEventListener('drop', function(event) {
            event.preventDefault();
            preview.classList.remove('geImageDropActive');
            encodeFileInto(draft, event.dataTransfer.files && event.dataTransfer.files[0], syncSourceField);
        });
        preview.addEventListener('click', function() { picker.click(); });
        preview.addEventListener('pointermove', function(event) {
            var rect = preview.getBoundingClientRect();
            if (!rect.width || !rect.height) return;
            previewPainter.setParallaxTarget(
                Math.max(-1, Math.min(1, ((event.clientX - rect.left) / rect.width - .5) * 2)),
                Math.max(-1, Math.min(1, ((event.clientY - rect.top) / rect.height - .5) * 2))
            );
            previewDirty = true;
        });
        preview.addEventListener('pointerleave', function() {
            previewPainter.setParallaxTarget(0, 0);
            previewDirty = true;
        });

        function row(labelText, control) {
            var line = document.createElement('label');
            line.className = 'geFormatRow';
            var caption = document.createElement('span');
            caption.textContent = labelText;
            line.appendChild(caption);
            line.appendChild(control);
            return line;
        }

        function select(values, current, handler) {
            var element = document.createElement('select');
            values.forEach(function(entry) {
                var option = document.createElement('option');
                option.value = entry[0];
                option.textContent = entry[1];
                element.appendChild(option);
            });
            element.value = current;
            element.addEventListener('change', function() {
                handler(element.value);
                previewDirty = true;
            });
            return element;
        }

        var options = this.createDiv('geImageOptions');
        options.appendChild(row('Fit', select([
            ['contain', 'Fit inside (keep ratio)'],
            ['cover', 'Fill box (crop)'],
            ['stretch', 'Stretch to box'],
            ['none', 'Natural size'],
            ['tile', 'Tile']
        ], draft.imageFit, function(value) { draft.imageFit = value; })));
        options.appendChild(row('Horizontal', select([
            ['center', 'Centre'], ['left', 'Left'], ['right', 'Right']
        ], draft.imageAlign, function(value) { draft.imageAlign = value; })));
        options.appendChild(row('Vertical', select([
            ['middle', 'Middle'], ['top', 'Top'], ['bottom', 'Bottom']
        ], draft.imageVerticalAlign, function(value) { draft.imageVerticalAlign = value; })));

        var opacity = document.createElement('input');
        opacity.type = 'number';
        opacity.min = 0;
        opacity.max = 100;
        opacity.step = 5;
        opacity.value = Math.round(draft.imageOpacity * 100);
        opacity.addEventListener('input', function() {
            draft.imageOpacity = Math.max(0, Math.min(100, Number(opacity.value) || 0)) / 100;
            previewDirty = true;
        });
        options.appendChild(row('Base opacity %', opacity));

        var volume = document.createElement('input');
        volume.type = 'number';
        volume.min = 0;
        volume.max = 100;
        volume.step = 5;
        volume.value = Math.round(draft.mediaVolume * 100);
        volume.addEventListener('input', function() {
            draft.mediaVolume = Math.max(0, Math.min(100, Number(volume.value) || 0)) / 100;
        });
        volumeRow = row('Initial volume %', volume);
        options.appendChild(volumeRow);

        var loop = document.createElement('input');
        loop.type = 'checkbox';
        loop.checked = draft.mediaLoop;
        loop.addEventListener('change', function() {
            draft.mediaLoop = loop.checked;
            previewDirty = true;
        });
        loopRow = row('Loop video', loop);
        options.appendChild(loopRow);

        var alt = document.createElement('input');
        alt.type = 'text';
        alt.value = draft.tooltip;
        alt.addEventListener('input', function() { draft.tooltip = alt.value; });
        options.appendChild(row('Alt text', alt));

        var layersSection = this.createDiv('geMediaLayers');
        var layersHeader = this.createDiv('geMediaLayersHeader');
        var layersTitle = document.createElement('div');
        layersTitle.className = 'geMediaLayersTitle';
        layersTitle.innerHTML = '<strong>Parallax Layers</strong><span>Back → front. Depth reacts to pointer; scroll values are px/s.</span>';
        var layerActions = this.createDiv('geMediaLayerActions');
        var addLayerUrl = document.createElement('button');
        addLayerUrl.className = 'geBtn';
        addLayerUrl.textContent = '+ URL Layer';
        var addLayerFile = document.createElement('button');
        addLayerFile.className = 'geBtn';
        addLayerFile.textContent = '+ File Layer…';
        layerActions.appendChild(addLayerUrl);
        layerActions.appendChild(addLayerFile);
        layersHeader.appendChild(layersTitle);
        layersHeader.appendChild(layerActions);
        layersSection.appendChild(layersHeader);
        var layersList = this.createDiv('geMediaLayerList');
        layersSection.appendChild(layersList);

        function layerNumberInput(value, min, max, step, handler) {
            var input = document.createElement('input');
            input.type = 'number';
            if (min != null) input.min = min;
            if (max != null) input.max = max;
            input.step = step;
            input.value = value;
            input.addEventListener('input', function() {
                handler(Number(input.value) || 0);
                previewDirty = true;
            });
            return input;
        }

        function cleanupLayer(layer) {
            cleanupDraftSource(layer);
        }

        function renderLayers(focusIndex) {
            layersList.innerHTML = '';
            if (draft.mediaLayers.length === 0) {
                var empty = ui.createDiv('geMediaLayerEmpty');
                empty.textContent = 'No extra layers. Add images/GIFs/MP4/WebM for depth or moving scenery.';
                layersList.appendChild(empty);
                previewDirty = true;
                return;
            }

            draft.mediaLayers.forEach(function(layer, index) {
                var card = ui.createDiv('geMediaLayerCard');
                var header = ui.createDiv('geMediaLayerCardHeader');
                var name = document.createElement('strong');
                name.textContent = 'Layer ' + (index + 1) + (index === 0 ? ' · back' :
                    (index === draft.mediaLayers.length - 1 ? ' · front' : ''));
                var buttons = ui.createDiv('geMediaLayerCardButtons');

                function mini(label, title, handler, disabled) {
                    var button = document.createElement('button');
                    button.type = 'button';
                    button.className = 'geBtn geMediaLayerMiniBtn';
                    button.textContent = label;
                    button.title = title;
                    button.disabled = !!disabled;
                    button.addEventListener('click', handler);
                    return button;
                }

                buttons.appendChild(mini('↑', 'Move layer toward the back', function() {
                    if (index <= 0) return;
                    var moved = draft.mediaLayers.splice(index, 1)[0];
                    draft.mediaLayers.splice(index - 1, 0, moved);
                    renderLayers(index - 1);
                }, index === 0));
                buttons.appendChild(mini('↓', 'Move layer toward the front', function() {
                    if (index >= draft.mediaLayers.length - 1) return;
                    var moved = draft.mediaLayers.splice(index, 1)[0];
                    draft.mediaLayers.splice(index + 1, 0, moved);
                    renderLayers(index + 1);
                }, index === draft.mediaLayers.length - 1));
                buttons.appendChild(mini('Remove', 'Remove this media layer', function() {
                    cleanupLayer(layer);
                    draft.mediaLayers.splice(index, 1);
                    renderLayers();
                    loadPreview();
                }, false));
                header.appendChild(name);
                header.appendChild(buttons);
                card.appendChild(header);

                var sourceLine = ui.createDiv('geMediaLayerSourceRow');
                var sourceInput = document.createElement('input');
                sourceInput.type = 'text';
                sourceInput.className = 'geServerPathInput';
                sourceInput.placeholder = 'Image, GIF, MP4 or WebM URL';
                var embedded = /^data:/i.test(layer.src);
                var locked = !!layer.sourceLabel || embedded;
                sourceInput.value = sourceSummary(layer.src, layer.mediaType, layer.sourceLabel);
                sourceInput.readOnly = locked;
                sourceInput.classList.toggle('geMediaSourceSummary', locked);
                sourceInput.addEventListener('input', function() {
                    if (sourceInput.readOnly) return;
                    layer.src = sourceInput.value.trim();
                    layer.mediaType = sourceType(layer.src, '');
                    previewDirty = true;
                });
                sourceInput.addEventListener('change', loadPreview);
                sourceLine.appendChild(sourceInput);

                var replace = document.createElement('button');
                replace.className = 'geBtn geMediaLayerReplaceBtn';
                replace.textContent = locked ? 'Replace URL…' : 'Clear';
                replace.addEventListener('click', function() {
                    cleanupLayer(layer);
                    layer.src = '';
                    layer.mediaType = '';
                    renderLayers(index);
                    loadPreview();
                });
                sourceLine.appendChild(replace);
                card.appendChild(sourceLine);

                var controls = ui.createDiv('geMediaLayerControls');
                function control(label, input) {
                    var item = document.createElement('label');
                    var caption = document.createElement('span');
                    caption.textContent = label;
                    item.appendChild(caption);
                    item.appendChild(input);
                    controls.appendChild(item);
                }
                control('Depth %', layerNumberInput(Math.round(layer.depth * 100), 0, 100, 5, function(value) {
                    layer.depth = Math.max(0, Math.min(100, value)) / 100;
                }));
                control('Opacity %', layerNumberInput(Math.round(layer.opacity * 100), 0, 100, 5, function(value) {
                    layer.opacity = Math.max(0, Math.min(100, value)) / 100;
                }));
                control('Scroll X', layerNumberInput(layer.scrollX, -2000, 2000, 5, function(value) {
                    layer.scrollX = value;
                }));
                control('Scroll Y', layerNumberInput(layer.scrollY, -2000, 2000, 5, function(value) {
                    layer.scrollY = value;
                }));
                card.appendChild(controls);
                layersList.appendChild(card);

                if (focusIndex === index && !sourceInput.readOnly) {
                    setTimeout(function() { sourceInput.focus(); }, 0);
                }
            });
            previewDirty = true;
            loadPreview();
        }

        addLayerUrl.addEventListener('click', function() {
            var depth = Math.min(1, .25 + draft.mediaLayers.length * .2);
            draft.mediaLayers.push(cleanLayer({ depth: depth, opacity: 1 }));
            renderLayers(draft.mediaLayers.length - 1);
        });
        addLayerFile.addEventListener('click', function() { layerPicker.click(); });
        layerPicker.addEventListener('change', function() {
            var files = Array.prototype.slice.call(layerPicker.files || []);
            layerPicker.value = '';
            files.forEach(function(file) {
                if (!validMediaFile(file)) return;
                var depth = Math.min(1, .25 + draft.mediaLayers.length * .2);
                var layer = cleanLayer({ depth: depth, opacity: 1 });
                draft.mediaLayers.push(layer);
                encodeFileInto(layer, file, renderLayers);
            });
            renderLayers();
        });

        function close() {
            if (previewFrame != null) cancelAnimationFrame(previewFrame);
            previewFrame = null;
            cleanupDraftSource(draft);
            draft.mediaLayers.forEach(cleanupLayer);
            backdrop.remove();
        }

        var chooseFile = document.createElement('button');
        chooseFile.className = 'geBtn';
        chooseFile.textContent = 'Choose Base File…';
        chooseFile.addEventListener('click', function() { picker.click(); });

        var resetRatio = document.createElement('button');
        resetRatio.className = 'geBtn';
        resetRatio.textContent = 'Reset Ratio';
        resetRatio.setAttribute('title', 'Resize the shape to the base media aspect ratio');
        resetRatio.addEventListener('click', function() {
            if (natural == null) {
                ui.toast('Load base media first');
                return;
            }
            var scale = node.width / natural.width;
            node.height = Math.max(1, Math.round(natural.height * scale));
            graph.updateItem(node.id, { height: node.height });
            ui.toast('Height set to ' + node.height + ' px');
        });

        var remove = document.createElement('button');
        remove.className = 'geBtn';
        remove.textContent = 'Remove Media';
        remove.addEventListener('click', function() {
            var changes = {
                src: undefined, mediaType: undefined, mediaLoop: undefined,
                mediaVolume: undefined, mediaLayers: undefined
            };
            if (node.shape === 'image') changes.shape = 'rect';
            graph.updateItem(node.id, changes, 'Remove Media', true);
            if (graph.mediaPlayback && typeof graph.mediaPlayback.retain === 'function') {
                graph.mediaPlayback.retain(graph.items);
            }
            close();
            ui.toast('Media removed');
        });

        var cancel = document.createElement('button');
        cancel.className = 'geBtn';
        cancel.textContent = 'Cancel';
        cancel.addEventListener('click', close);

        var apply = document.createElement('button');
        apply.className = 'geBtn gePrimaryBtn';
        apply.textContent = 'OK';
        apply.addEventListener('click', function() {
            function commitMedia() {
                if (!draft.src) {
                    ui.toast('Choose base media first');
                    return;
                }
                if (isYouTubeSource(draft.src) && persistentLayers().length > 0) {
                    ui.toast('Parallax layers need an image, GIF, MP4 or WebM base — not YouTube');
                    return;
                }
                var layers = persistentLayers();
                var changes = {
                    shape: 'image',
                    src: draft.src,
                    mediaType: sourceType(draft.src, draft.mediaType),
                    mediaLoop: draft.mediaLoop,
                    mediaVolume: draft.mediaVolume,
                    imageFit: draft.imageFit,
                    imageAlign: draft.imageAlign,
                    imageVerticalAlign: draft.imageVerticalAlign,
                    imageOpacity: draft.imageOpacity,
                    tooltip: draft.tooltip,
                    mediaLayers: layers.length ? layers : undefined
                };
                if (node.fill == null || node.fill === '#ffffff') changes.fill = 'transparent';
                graph.updateItem(node.id, changes, 'Edit Media', true);
                if (graph.mediaPlayback && typeof graph.mediaPlayback.retain === 'function') {
                    graph.mediaPlayback.retain(graph.items);
                }
                graph.emit('selectionchange', graph.getSelection());
                close();
                ui.toast(layers.length ? 'Media + ' + layers.length + ' parallax layer(s) updated' : 'Media updated');
            }

            var encodings = [];
            if (draft.encoding) encodings.push(draft.encoding);
            draft.mediaLayers.forEach(function(layer) {
                if (layer.encoding) encodings.push(layer.encoding);
            });
            if (encodings.length) {
                apply.disabled = true;
                apply.textContent = 'Buffering…';
                Promise.all(encodings).then(commitMedia).catch(function() {
                    apply.disabled = false;
                    apply.textContent = 'OK';
                    ui.toast('Could not buffer one of the media files');
                });
            } else {
                commitMedia();
            }
        });

        var footer = this.createDiv('geDialogButtons geMediaDialogButtons');
        footer.appendChild(chooseFile);
        footer.appendChild(resetRatio);
        footer.appendChild(remove);
        footer.appendChild(cancel);
        footer.appendChild(apply);

        dialog.appendChild(heading);
        dialog.appendChild(sourceRow);
        dialog.appendChild(preview);
        dialog.appendChild(options);
        dialog.appendChild(layersSection);
        dialog.appendChild(picker);
        dialog.appendChild(layerPicker);
        dialog.appendChild(footer);
        backdrop.appendChild(dialog);
        document.body.appendChild(backdrop);
        renderLayers();
        url.focus();
        loadPreview();
        if (typeof requestAnimationFrame === 'function') tick();
    };


    // Compatibility alias for extensions which still call editImage.
    EditorUi.prototype.editImage = EditorUi.prototype.editMedia;

    EditorUi.prototype.insertMedia = function() {
        if (this.imageInput == null) {
            this.imageInput = document.createElement('input');
            this.imageInput.type = 'file';
            this.imageInput.accept = 'image/*,video/mp4,video/webm,.mp4,.webm';
            this.imageInput.hidden = true;
            this.container.appendChild(this.imageInput);
            this.imageInput.addEventListener('change', function() {
                var file = this.imageInput.files[0];
                this.imageInput.value = '';
                if (!file) return;
                this.toast('Buffering ' + file.name + '…');
                var encode = root.PixelMedia ? root.PixelMedia.encodeFile(file) : Promise.reject();
                encode.then(function(result) {
                    this.editor.graph.insertMedia(String(result), file.name, null, file.type);
                    this.toast('Media inserted');
                }.bind(this)).catch(function() {
                    var reader = new FileReader();
                    reader.onload = function() {
                        this.editor.graph.insertMedia(String(reader.result), file.name, null, file.type);
                    }.bind(this);
                    reader.readAsDataURL(file);
                }.bind(this));
            }.bind(this));
        }

        var url = prompt('Media URL — image, GIF, MP4 or WebM (leave empty to choose a file)', '');
        if (url == null) return;
        if (url.trim() === '') this.imageInput.click();
        else this.editor.graph.insertMedia(url.trim(), url.trim(), null,
            root.PixelMedia ? root.PixelMedia.typeFor(url.trim()) : '');
    };

    EditorUi.prototype.insertImage = EditorUi.prototype.insertMedia;

    EditorUi.prototype.toggleAutosave = function() {
        this.autosaveEnabled = !this.autosaveEnabled;

        if (this.autosaveEnabled) {
            var graph = this.editor.graph;
            if (this.autosaveHandler == null) {
                // Debounced so a burst of edits writes once.
                this.autosaveHandler = function() {
                    if (!this.autosaveEnabled) return;
                    clearTimeout(this.autosaveTimer);
                    this.autosaveTimer = setTimeout(function() {
                        try {
                            localStorage.setItem('pixel-graph-document', graph.toJSON());
                            this.setStatusText('Autosaved ' + new Date().toLocaleTimeString());
                        } catch (error) {
                            this.toast('Autosave failed: ' + error.message);
                        }
                    }.bind(this), 1500);
                }.bind(this);
                graph.on('change', this.autosaveHandler);
            }
            this.toast('Autosave on');
        } else {
            clearTimeout(this.autosaveTimer);
            this.toast('Autosave off');
        }
    };

    /* HTML block editor. The canvas cannot host a DOM subtree, so the markup
       is parsed into the rich text model and painted; the source is kept on
       the node so it can be edited again. */
    EditorUi.prototype.editHtml = function(target) {
        var graph = this.editor.graph;
        var node = target && target.shape === 'html' ? target : null;
        var creating = node == null;

        var backdrop = this.createDiv('geDialogBackdrop');
        var dialog = this.createDiv('geDialog');
        dialog.style.width = 'min(680px, calc(100vw - 32px))';

        var heading = document.createElement('h2');
        heading.textContent = creating ? 'Insert HTML Block' : 'Edit HTML';

        var hint = document.createElement('p');
        hint.textContent = 'Headings, paragraphs, lists, bold, italic, underline, ' +
            'colours and font sizes are rendered on the canvas. Scripts and embeds are ignored.';

        var area = document.createElement('textarea');
        area.className = 'geDiagramSource';
        area.style.height = '32vh';
        area.spellcheck = false;
        area.value = node ? (node.html || '') :
            '<h3>Title</h3><p>Some <b>rich</b> text.</p><ul><li>One</li><li>Two</li></ul>';

        var preview = this.createDiv('geHtmlPreview');
        var previewCanvas = document.createElement('canvas');
        preview.appendChild(previewCanvas);

        function refresh() {
            if (root.PixelRichText == null) return;
            var model = root.PixelRichText.fromHtml(area.value);
            var ratio = Math.min(2, window.devicePixelRatio || 1);
            var width = preview.clientWidth || 600;
            var height = 130;
            previewCanvas.width = Math.round(width * ratio);
            previewCanvas.height = Math.round(height * ratio);
            previewCanvas.style.width = width + 'px';
            previewCanvas.style.height = height + 'px';
            var ctx = previewCanvas.getContext('2d');
            if (ctx == null) return;
            ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
            ctx.clearRect(0, 0, width, height);
            root.PixelRichText.draw(ctx, model, { x: 0, y: 0, width: width, height: height }, {
                fontSize: 13, fontFamily: 'Arial, sans-serif', color: '#172033',
                align: 'left', verticalAlign: 'top', wrap: true, padding: 8
            });
        }

        area.addEventListener('input', refresh);

        var cancel = document.createElement('button');
        cancel.className = 'geBtn';
        cancel.textContent = 'Cancel';
        cancel.addEventListener('click', function() { backdrop.remove(); });

        var apply = document.createElement('button');
        apply.className = 'geBtn gePrimaryBtn';
        apply.textContent = creating ? 'Insert' : 'OK';
        apply.addEventListener('click', function() {
            var model = root.PixelRichText.fromHtml(area.value);
            var before = graph.snapshot();

            if (creating) {
                var template = Object.assign({}, root.PixelNodeTemplates.html, {
                    html: area.value, richText: model
                });
                this.editor.addTemplateAtCenter(template);
            } else {
                graph.updateItem(node.id, {
                    html: area.value, richText: model,
                    text: root.PixelRichText.toPlain(model)
                }, 'Edit HTML', true);
            }

            backdrop.remove();
        }.bind(this));

        var footer = this.createDiv('geDialogButtons');
        footer.appendChild(cancel);
        footer.appendChild(apply);
        dialog.appendChild(heading);
        dialog.appendChild(hint);
        dialog.appendChild(area);
        dialog.appendChild(preview);
        dialog.appendChild(footer);
        backdrop.appendChild(dialog);
        document.body.appendChild(backdrop);
        area.focus();
        refresh();
    };

    /* Drops a set of freshly imported items into the diagram, centred on the
     * viewport, as one undo step.
     *
     * Imported items carry ids from whatever produced them, which can collide
     * with what is already on the canvas, so every id is reissued and each
     * reference between them (terminals, containers, groups, the mx round-trip
     * record) is remapped to match. Shared by the SVG importer and the Office
     * clipboard paste.
     */
    EditorUi.prototype.insertImportedItems = function(items, options) {
        var graph = this.editor.graph;
        options = options || {};
        if (!items || items.length === 0) return [];

        var importedById = Object.create(null);
        items.forEach(function(item) { importedById[item.id] = item; });
        var bounds = items.map(function(item) {
            return root.PixelGeometry.itemBounds(item, importedById);
        });
        var minX = Math.min.apply(Math, bounds.map(function(b) { return b.x; }));
        var minY = Math.min.apply(Math, bounds.map(function(b) { return b.y; }));
        var maxX = Math.max.apply(Math, bounds.map(function(b) { return b.x + b.width; }));
        var maxY = Math.max.apply(Math, bounds.map(function(b) { return b.y + b.height; }));

        var zoom = Math.max(0.2, graph.zoom || 1);
        var target = options.point || {
            x: (graph.container.scrollLeft + graph.container.clientWidth / 2) / zoom -
                (graph.worldOriginX || 0),
            y: (graph.container.scrollTop + graph.container.clientHeight / 2) / zoom -
                (graph.worldOriginY || 0)
        };
        var dx = target.x - (minX + maxX) / 2;
        var dy = target.y - (minY + maxY) / 2;

        var before = graph.snapshot();
        var created = [];
        var idMap = Object.create(null);
        var used = Object.create(null);
        graph.items.forEach(function(item) { used[item.id] = true; });

        items.forEach(function(item, index) {
            var base = (options.idPrefix || 'import') + '-' + (index + 1);
            var id = base;
            var suffix = 1;
            while (used[id]) id = base + '-' + (++suffix);
            used[id] = true;
            idMap[item.id] = id;
        });

        /* Group ids live in their own namespace, not the item one, so they get
           their own map. Reissuing them matters as much as reissuing item ids:
           an imported group whose id happened to match one already on the
           canvas would silently merge the two into a single group. */
        var usedGroups = Object.create(null);
        graph.items.forEach(function(item) {
            (item.groups || []).forEach(function(group) { usedGroups[group] = true; });
        });
        var groupMap = Object.create(null);
        function mapGroup(group) {
            if (!groupMap[group]) {
                var base = (options.idPrefix || 'import') + '-group';
                var id = base + '-1';
                var suffix = 1;
                while (usedGroups[id]) id = base + '-' + (++suffix);
                usedGroups[id] = true;
                groupMap[group] = id;
            }
            return groupMap[group];
        }

        function offsetPoint(point) {
            return point ? { x: Number(point.x) + dx, y: Number(point.y) + dy } : point;
        }

        items.forEach(function(source) {
            var item = JSON.parse(JSON.stringify(source));
            item.id = idMap[source.id];
            // groupId is deliberately not in this list: it names a group, not
            // an item, and is rebuilt from the remapped group path below.
            ['sourceId', 'targetId', 'containerId'].forEach(function(key) {
                if (item[key] && idMap[item[key]]) item[key] = idMap[item[key]];
            });
            if (Array.isArray(item.groups) && item.groups.length > 0) {
                item.groups = item.groups.map(mapGroup);
                item.groupId = item.groups[0];
            } else {
                delete item.groups;
                delete item.groupId;
            }
            if (item.mx) {
                item.mx.id = item.id;
                if (item.mx.parent && idMap[item.mx.parent]) item.mx.parent = idMap[item.mx.parent];
            }
            if (item.type === 'edge') {
                item.sourcePoint = offsetPoint(item.sourcePoint);
                item.targetPoint = offsetPoint(item.targetPoint);
                item.previewPoints = (item.previewPoints || []).map(offsetPoint);
                if (Array.isArray(item.route)) item.route = item.route.map(offsetPoint);
                created.push(graph.addEdge(item, false));
            } else {
                item.x += dx;
                item.y += dy;
                created.push(graph.addNode(item, false));
            }
        });

        graph.setSelection(created.map(function(item) { return item.id; }), true);
        graph.commit(before, options.label || 'Insert');
        return created;
    };

    EditorUi.prototype.showSvgToMxGraphDialog = function() {
        var ui = this;
        var backdrop = this.createDiv('geDialogBackdrop');
        var dialog = this.createDiv('geDialog');
        dialog.style.width = 'min(760px, calc(100vw - 32px))';

        var heading = document.createElement('h2');
        heading.textContent = 'SVG to mxGraph';
        var description = document.createElement('p');
        description.textContent = 'Paste SVG markup or choose an SVG file. Supported elements are inserted as editable diagram objects.';

        var file = document.createElement('input');
        file.type = 'file';
        file.accept = '.svg,image/svg+xml';
        file.style.display = 'block';
        file.style.marginBottom = '10px';

        var area = document.createElement('textarea');
        area.className = 'geDiagramSource';
        area.placeholder = '<svg viewBox="0 0 300 200">…</svg>';
        area.spellcheck = false;

        var status = document.createElement('div');
        status.style.minHeight = '20px';
        status.style.marginTop = '8px';
        status.style.whiteSpace = 'pre-wrap';
        status.style.fontSize = '12px';

        function inspect() {
            if (!area.value.trim()) {
                status.textContent = 'Enter SVG markup to continue.';
                status.style.color = '';
                return null;
            }
            try {
                var result = root.SvgMxGraphConverter.convert(area.value);
                status.style.color = '';
                status.textContent = result.width + ' × ' + result.height + ' · ' + result.items.length +
                    ' editable object' + (result.items.length === 1 ? '' : 's') +
                    (result.warnings.length ? '\nWarnings:\n• ' + result.warnings.join('\n• ') : '');
                return result;
            } catch (error) {
                status.style.color = '#c62828';
                status.textContent = 'Invalid SVG: ' + error.message;
                return null;
            }
        }

        file.addEventListener('change', function() {
            if (!file.files || !file.files[0]) return;
            var reader = new FileReader();
            reader.onload = function() { area.value = String(reader.result || ''); inspect(); };
            reader.onerror = function() { status.textContent = 'Could not read the selected SVG file.'; };
            reader.readAsText(file.files[0]);
        });
        area.addEventListener('input', inspect);

        var cancel = document.createElement('button');
        cancel.className = 'geBtn';
        cancel.textContent = 'Cancel';
        cancel.addEventListener('click', function() { backdrop.remove(); });

        var insert = document.createElement('button');
        insert.className = 'geBtn gePrimaryBtn';
        insert.textContent = 'Insert into Diagram';
        insert.addEventListener('click', function() {
            var result = inspect();
            if (!result) return;
            var created = ui.insertImportedItems(result.items, {
                idPrefix: 'svg-import', label: 'Insert SVG'
            });
            backdrop.remove();
            ui.toast('Inserted ' + created.length + ' SVG object' + (created.length === 1 ? '' : 's'));
        });

        var footer = this.createDiv('geDialogButtons');
        footer.appendChild(cancel);
        footer.appendChild(insert);
        dialog.appendChild(heading);
        dialog.appendChild(description);
        dialog.appendChild(file);
        dialog.appendChild(area);
        dialog.appendChild(status);
        dialog.appendChild(footer);
        backdrop.appendChild(dialog);
        document.body.appendChild(backdrop);
        area.focus();
        inspect();
    };

    /* Whole-document editor, the canvas equivalent of Extras > Edit Diagram. */
    EditorUi.prototype.editDiagram = function() {
        var graph = this.editor.graph;
        var backdrop = this.createDiv('geDialogBackdrop');
        var dialog = this.createDiv('geDialog');
        dialog.style.width = 'min(760px, calc(100vw - 32px))';

        var heading = document.createElement('h2');
        heading.textContent = 'Edit Diagram';
        var area = document.createElement('textarea');
        area.className = 'geDiagramSource';
        area.value = graph.toJSON();
        area.spellcheck = false;

        var cancel = document.createElement('button');
        cancel.className = 'geBtn';
        cancel.textContent = 'Cancel';
        cancel.addEventListener('click', function() { backdrop.remove(); });

        var apply = document.createElement('button');
        apply.className = 'geBtn gePrimaryBtn';
        apply.textContent = 'OK';
        apply.addEventListener('click', function() {
            try {
                graph.fromJSON(area.value);
                backdrop.remove();
                this.toast('Diagram replaced');
            } catch (error) {
                this.toast('Invalid document: ' + error.message);
            }
        }.bind(this));

        var footer = this.createDiv('geDialogButtons');
        footer.appendChild(cancel);
        footer.appendChild(apply);
        dialog.appendChild(heading);
        dialog.appendChild(area);
        dialog.appendChild(footer);
        backdrop.appendChild(dialog);
        document.body.appendChild(backdrop);
        area.focus();
    };

    EditorUi.prototype.editData = function() {
        var graph = this.editor.graph;
        var item = graph.getSelection()[0];

        if (!item) {
            this.showDialog('Diagram Data', 'Select an object to edit its custom JSON data. Diagram settings are available in the Diagram panel.');
            return;
        }

        var text = prompt('Object JSON', JSON.stringify(item, null, 2));
        if (text == null) return;

        try {
            var parsed = JSON.parse(text);
            parsed.id = item.id;
            parsed.type = item.type;
            graph.call('replaceItem', [item.id, parsed, 'Edit Data']);
        } catch (error) { this.toast('Invalid JSON: ' + error.message); }
    };

    root.EditorUi = EditorUi;
})(window);
