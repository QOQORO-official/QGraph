/*
 * Classic mxGraph-style sidebar for the pixel-native canvas editor.
 *
 * The DOM is intentionally kept close to the old GraphEditor sidebar:
 * Original / Visual Script tabs, collapsible palettes, search and scratchpad.
 * Palette thumbnails use the same SVG/HTML DOM approach as the old editor.
 * The diagram surface remains pixel-native canvas.
 */
(function(root) {
    'use strict';

    var COLLAPSED_IMAGE = "data:image/svg+xml;utf8," + encodeURIComponent(
        "<svg xmlns='http://www.w3.org/2000/svg' width='13' height='13'><path fill='#999999' d='M4 3 L9 6.5 L4 10 Z'/></svg>");
    var EXPANDED_IMAGE = "data:image/svg+xml;utf8," + encodeURIComponent(
        "<svg xmlns='http://www.w3.org/2000/svg' width='13' height='13'><path fill='#999999' d='M3 4 L10 4 L6.5 9 Z'/></svg>");
    var SCRATCHPAD_KEY = 'pixel-graph-scratchpad';

    function Sidebar(ui) {
        this.ui = ui;
        // These are the original GraphEditor compact inventory dimensions.
        this.thumbWidth = 32;
        this.thumbHeight = 30;
        this.thumbPadding = 1;
        this.thumbBorder = 1;
        this.scratchpadBodies = [];
        this.panelSections = { original: [], visual: [] };
        this.stencilHosts = Object.create(null);
        this.loadedStencilLibraries = Object.create(null);

        // Same high-level palette order as the old mxGraph GraphEditor.
        this.originalPalettes = [
            // The exact General and Misc inventory of the classic sidebar,
            // built from the original mxGraph style strings.
            { id: 'general', name: 'General', expanded: true, classic: 'general', items: [] },
            { id: 'misc', name: 'Misc', expanded: false, classic: 'misc', items: [] },
            { id: 'advanced', name: 'Advanced', expanded: false, classic: 'advanced', items: [] },
            { id: 'basic', name: 'Basic', expanded: false, stencilLibrary: 'mxgraph.basic', items: [] },
            { id: 'arrows', name: 'Arrows', expanded: false, stencilLibrary: 'mxgraph.arrows', items: [] },
            { id: 'uml', name: 'UML', expanded: false, classic: 'uml', items: [] },
            { id: 'bpmn', name: 'BPMN General', expanded: false, classic: 'bpmn', items: [] },
            { id: 'flowchart', name: 'Flowchart', expanded: false, stencilLibrary: 'mxgraph.flowchart', items: [] }
        ];

        // The original extension used one "Script Nodes" palette in this tab.
        // Its entries come from the shared Visual Script card descriptions,
        // never from similarly named generic flowchart templates.
        var visualItems = (root.PixelVisualScriptDefinitions || []).map(function(definition) {
            return [definition.key, definition.label];
        });
        this.visualPalettes = [
            { id: 'visualScript', name: 'Script Nodes', expanded: true, items: visualItems }
        ];
    }

    /* Builds a diagram template from a classic mxGraph style string.
     *
     * This runs the entry through the same importer that reads .qochart, so a
     * palette shape and the same shape loaded from a document go through one
     * mapping instead of two that can drift apart. Results are cached because
     * every thumbnail asks for its template.
     */
    Sidebar.prototype.classicTemplate = function(entry) {
        if (this.classicCache == null) this.classicCache = Object.create(null);
        // Value is part of the template identity: ordered and unordered lists
        // deliberately share geometry/style but not their HTML content.
        var key = entry.kind + '|' + entry.style + '|' + entry.width + 'x' +
            entry.height + '|' + (entry.value || '') + '|' + (entry.xml || '') +
            '|' + (entry.extra ? JSON.stringify(entry.extra) : '') +
            '|' + (entry.processBar ? 'processBar' : '') +
            '|' + (entry.listTemplate ? 'list' : '') +
            '|' + (entry.containerTemplate ? 'container' : '') +
            '|' + (entry.listItemTemplate ? 'listItem' : '') +
            '|' + (entry.titledTable || '');
        if (this.classicCache[key] !== undefined) return this.classicCache[key];

        var template = null;
        var importer = root.Editor && root.Editor.importLegacyGraph;

        // Entries the classic sidebar stored as a compressed diagram (pools,
        // cross-functional flowcharts, tables, UML class stacks) are plain
        // mxGraph documents. Import one and rebuild the parent/child nesting
        // as a template tree, so a single drop recreates the whole group.
        if (entry.xml && typeof importer === 'function') {
            try {
                var documentItems = (importer(entry.xml).items || []).map(function(item) {
                    var copy = JSON.parse(JSON.stringify(item));
                    ['z', 'layer', 'groups', 'groupId', 'mx'].forEach(function(name) {
                        delete copy[name];
                    });
                    return copy;
                });
                var roots = documentItems.filter(function(item) { return !item.containerId; });
                if (roots.length > 0) {
                    var byParent = Object.create(null);
                    documentItems.forEach(function(item) {
                        if (!item.containerId) return;
                        (byParent[item.containerId] || (byParent[item.containerId] = [])).push(item);
                    });
                    var nest = function(item) {
                        var kids = byParent[item.id] || [];
                        if (kids.length > 0) {
                            item.children = kids.map(function(kid) {
                                kid.x -= item.x;
                                kid.y -= item.y;
                                return nest(kid);
                            });
                        }
                        delete item.containerId;
                        delete item.id;
                        return item;
                    };
                    template = nest(roots[0]);
                    template.x = 0;
                    template.y = 0;
                    if (entry.extra) Object.assign(template, entry.extra);
                }
            } catch (error) {
                template = null;
            }
            this.classicCache[key] = template;
            return template;
        }

        if (typeof importer === 'function') {
            var value = (entry.value || '').replace(/&/g, '&amp;').replace(/</g, '&lt;')
                .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
            var body = entry.kind === 'edge' ?
                '<mxCell id="t" value="' + value + '" style="' + entry.style.replace(/"/g, '&quot;') +
                    '" edge="1" parent="1">' +
                    '<mxGeometry relative="1" as="geometry">' +
                    '<mxPoint x="0" y="0" as="sourcePoint"/>' +
                    '<mxPoint x="' + entry.width + '" y="' + entry.height + '" as="targetPoint"/>' +
                    '</mxGeometry></mxCell>' :
                '<mxCell id="t" value="' + value + '" style="' + entry.style.replace(/"/g, '&quot;') +
                    '" vertex="1" parent="1">' +
                    '<mxGeometry x="0" y="0" width="' + entry.width + '" height="' + entry.height +
                    '" as="geometry"/></mxCell>';

            try {
                var scene = importer('<mxGraphModel><root><mxCell id="0"/>' +
                    '<mxCell id="1" parent="0"/>' + body + '</root></mxGraphModel>');
                var item = (scene.items || [])[0];

                if (item != null) {
                    template = JSON.parse(JSON.stringify(item));
                    ['id', 'z', 'mx', 'layer', 'groups', 'groupId'].forEach(function(name) {
                        delete template[name];
                    });
                    if (entry.kind === 'edge') {
                        template.type = 'edge';
                        delete template.sourceId;
                        delete template.targetId;
                    } else if (entry.processBar) {
                        template.shape = 'text';
                        template.fill = 'transparent';
                        template.stroke = 'transparent';
                        template.strokeWidth = 0;
                        template.text = 'Process Bar';
                        template.verticalAlign = 'top';
                        template.children = [
                            { shape: 'step', text: 'Step 1', x: 10, y: 33, width: 100, height: 57 },
                            { shape: 'step', text: 'Step 2', x: 98, y: 33, width: 100, height: 57 },
                            { shape: 'step', text: 'Step 3', x: 186, y: 33, width: 100, height: 57 }
                        ];
                    } else if (entry.listTemplate) {
                        template.kind = 'list';
                        template.container = true;
                        template.containerRole = 'list';
                        template.collapsible = true;
                        template.fill = 'transparent';
                        template.children = ['Item 1', 'Item 2', 'Item 3'].map(function(label, index) {
                            return {
                                kind: 'listItem', shape: 'text', text: label, x: 0, y: 26 + index * 26,
                                width: 140, height: 26, fill: 'transparent', stroke: 'transparent',
                                strokeWidth: 0, textAlign: 'left', verticalAlign: 'top',
                                textPadding: 4, rotatable: false
                            };
                        });
                    } else if (entry.containerTemplate) {
                        template.kind = 'container';
                        template.container = true;
                        template.containerRole = 'container';
                        template.collapsible = true;
                        template.headerHeight = template.headerHeight == null ? 26 : template.headerHeight;
                    } else if (entry.listItemTemplate) {
                        template.kind = 'listItem';
                        template.container = false;
                    } else if (entry.titledTable) {
                        var second = Number(entry.titledTable) === 2;
                        template = {
                            type: 'node', kind: 'table', shape: 'table', sourceType: 'htmlTable',
                            width: 180, height: 150, fill: '#ffffff', stroke: '#4a5564',
                            strokeWidth: 1, radius: 0, text: '', tableTitle: 'Table',
                            tableTitleHeight: 30, tableBorder: 1, gridStroke: '#4a5564',
                            fontSize: 11, fontFamily: 'Arial, Helvetica, sans-serif',
                            fontWeight: 400, textColor: '#172033', cellAlign: second ? 'left' : 'center',
                            rows: 3, columns: second ? 2 : 3,
                            rowWeights: second ? [30, 30, 30] : [40, 40, 40],
                            columnWeights: second ? [40, 140] : [60, 60, 60],
                            fixedRows: second, rowLines: !second,
                            firstRowLine: second, reorderRows: true,
                            rowIndexColumn: second ? 0 : null, cells: {}
                        };
                        if (second) {
                            template.cells = {
                                '0,0': { text: '1', align: 'center' },
                                '0,1': { text: 'Value 1', align: 'left' },
                                '1,0': { text: '2', align: 'center' },
                                '1,1': { text: 'Value 2', align: 'left' },
                                '2,0': { text: '3', align: 'center' },
                                '2,1': { text: 'Value 3', align: 'left' }
                            };
                        }
                    }

                    // Properties no mxGraph style string can carry: the end
                    // labels and symbol on a connector, a hyperlink. Applied
                    // after the chain above, not as one of its arms, because
                    // an edge entry always takes the edge arm.
                    if (entry.extra) Object.assign(template, entry.extra);
                }
            } catch (error) {
                template = null;
            }
        }

        this.classicCache[key] = template;
        return template;
    };

    /* Expands a palette declared with `classic` into real entries. */
    Sidebar.prototype.classicEntries = function(name) {
        var source = (root.PixelClassicPalette || {})[name] || [];
        var entries = [];

        for (var i = 0; i < source.length; i++) {
            var template = this.classicTemplate(source[i]);
            if (template == null) continue;
            entries.push({
                title: source[i].title,
                template: template,
                // Keep the authored value/style for a faithful SVG/HTML
                // preview. The imported template is still what gets added to
                // the canvas when the item is clicked or dragged.
                previewSource: source[i]
            });
        }

        return entries;
    };

    /* Palette previews are SVG.
     *
     * The diagram is canvas, but the sidebar is ordinary DOM and the classic
     * inventory was drawn as SVG. A compact raster looks soft and its outlines
     * thin out; SVG stays sharp at any device pixel ratio. HTML labels are
     * placed in SVG foreignObjects, just as they were in the old inventory.
     */
    Sidebar.prototype.createThumb = function(shapeName, custom, previewSource) {
        var template = custom || (root.PixelNodeTemplates || {})[shapeName];

        if (template != null && root.PixelShapeSvg != null) {
            try {
                var svg = root.PixelShapeSvg.preview(template, this.thumbWidth,
                    this.thumbHeight, previewSource);
                if (svg != null) {
                    svg.setAttribute('class', 'geShapeSvg');
                    return svg;
                }
            } catch (svgError) {}
        }

        // Never rasterize the inventory. Unknown/custom entries use a small
        // ordinary HTML preview so the sidebar remains DOM-native.
        var fallback = document.createElement('div');
        fallback.className = 'geShapeHtml';
        fallback.textContent = (template && (template.text || template.shape)) || 'Shape';
        fallback.style.width = this.thumbWidth + 'px';
        fallback.style.height = this.thumbHeight + 'px';
        return fallback;
    };

    Sidebar.prototype.loadScratchpad = function() {
        try {
            var stored = JSON.parse(localStorage.getItem(SCRATCHPAD_KEY) || '[]');
            return Array.isArray(stored) ? stored : [];
        } catch (error) { return []; }
    };

    Sidebar.prototype.saveScratchpad = function(entries) {
        try { localStorage.setItem(SCRATCHPAD_KEY, JSON.stringify(entries)); }
        catch (error) { this.ui.toast('Scratchpad is full'); }
    };

    Sidebar.prototype.addToScratchpad = function(node) {
        var graph = this.ui.editor.graph;
        var source = node || graph.getSelection().filter(function(item) { return item.type !== 'edge'; })[0];
        if (!source) {
            this.ui.toast('Select a shape to add to the scratchpad');
            return;
        }
        var entry = JSON.parse(JSON.stringify(source));
        ['id', 'x', 'y', 'z', 'groups', 'groupId', 'layer', 'foldedAway', 'foldedBy'].forEach(function(key) {
            delete entry[key];
        });
        var entries = this.loadScratchpad();
        entries.push({ name: (source.text || source.shape || 'Shape').replace(/<[^>]*>/g, '').slice(0, 24), data: entry });
        this.saveScratchpad(entries);
        this.renderScratchpad();
        this.ui.toast('Added to scratchpad');
    };

    Sidebar.prototype.removeScratchpad = function(index) {
        var entries = this.loadScratchpad();
        if (index < 0 || index >= entries.length) return;
        entries.splice(index, 1);
        this.saveScratchpad(entries);
        this.renderScratchpad();
    };

    Sidebar.prototype.renderScratchpad = function() {
        var entries = this.loadScratchpad();
        this.scratchpadBodies.forEach(function(body) {
            body.innerHTML = '';
            if (entries.length === 0) {
                var empty = document.createElement('div');
                empty.className = 'geDropTarget';
                empty.textContent = 'Drop a shape here to reuse it';
                body.appendChild(empty);
                return;
            }
            entries.forEach(function(entry, index) {
                var item = this.createItem(null, entry.name, entry.data, null, true);
                item.addEventListener('contextmenu', function(event) {
                    event.preventDefault();
                    this.removeScratchpad(index);
                }.bind(this));
                body.appendChild(item);
            }, this);
        }, this);
    };

    /* Changes what the selected objects are drawn as, keeping their position,
       size, colours and labels. This is the classic editor's Shift-click on a
       palette entry; dragging the entry onto an object's replace badge does
       the same thing for one object. */
    Sidebar.prototype.replaceSelectionShape = function(template, title) {
        var graph = this.ui.editor.graph;

        if (template == null) return;
        if (graph.getSelection().length === 0) {
            this.ui.toast('Select something first to change its shape');
            return;
        }

        var replaced = graph.replaceShape(graph.getSelection(), template);

        if (replaced.length === 0) {
            this.ui.toast(template.type === 'edge' ?
                'Select a connector to change it' : 'Select a shape to change it');
            return;
        }

        this.ui.toast('Changed ' + replaced.length + ' object' +
            (replaced.length === 1 ? '' : 's') + ' to ' + (title || 'the selected shape'));
    };

    Sidebar.prototype.createItem = function(shapeName, title, custom, previewSource, scratchpadItem) {
        var elt = document.createElement('a');
        elt.className = 'geItem';
        elt.setAttribute('title', title + ' — Shift+click to change the shape of the selection' +
            (scratchpadItem ? ', right-click to remove from Scratchpad' : ''));
        if (shapeName) elt.dataset.shape = shapeName;
        elt.dataset.search = String(title || '').toLowerCase();
        elt.style.overflow = 'hidden';
        elt.style.width = (this.thumbWidth + 2 * this.thumbBorder) + 'px';
        elt.style.height = (this.thumbHeight + 2 * this.thumbBorder) + 'px';
        elt.style.padding = this.thumbPadding + 'px';
        elt.draggable = true;
        elt.appendChild(this.createThumb(shapeName, custom, previewSource));

        elt.addEventListener('dragstart', function(event) {
            if (custom) event.dataTransfer.setData('application/x-pixel-shape-data', JSON.stringify(custom));
            else event.dataTransfer.setData('application/x-pixel-shape', shapeName);
            event.dataTransfer.effectAllowed = 'copy';
        });
        elt.addEventListener('click', function(event) {
            event.preventDefault();
            if (event.shiftKey) {
                this.replaceSelectionShape(custom ||
                    (root.PixelNodeTemplates || {})[shapeName], title);
            } else if (custom) {
                this.ui.editor.addTemplateAtCenter(custom);
            } else {
                this.ui.editor.addAtCenter(shapeName);
            }
        }.bind(this));
        return elt;
    };

    Sidebar.prototype.createTitle = function(label) {
        var elt = document.createElement('a');
        elt.className = 'geTitle';
        elt.textContent = label;
        elt.style.backgroundRepeat = 'no-repeat';
        elt.style.backgroundPosition = '0% 50%';
        return elt;
    };

    Sidebar.prototype.addFoldingHandler = function(title, content) {
        function sync() {
            title.style.backgroundImage = 'url(\'' +
                ((content.style.display === 'none') ? COLLAPSED_IMAGE : EXPANDED_IMAGE) + '\')';
        }
        sync();
        title.addEventListener('click', function() {
            content.style.display = (content.style.display === 'none') ? 'block' : 'none';
            sync();
        });
    };

    Sidebar.prototype.createScratchpad = function(panel) {
        var title = this.createTitle('Scratchpad');
        var body = document.createElement('div');
        body.className = 'geSidebar geScratchpadPalette';
        body.style.touchAction = 'none';
        panel.appendChild(title);
        var outer = document.createElement('div');
        outer.appendChild(body);
        panel.appendChild(outer);
        this.addFoldingHandler(title, body);
        this.scratchpadBodies.push(body);

        body.addEventListener('dragover', function(event) {
            event.preventDefault();
            body.classList.add('geSidebarDropActive');
        });
        body.addEventListener('dragleave', function() { body.classList.remove('geSidebarDropActive'); });
        body.addEventListener('drop', function(event) {
            event.preventDefault();
            body.classList.remove('geSidebarDropActive');
            var shape = event.dataTransfer.getData('application/x-pixel-shape');
            var data = event.dataTransfer.getData('application/x-pixel-shape-data');
            if (data) this.addToScratchpad(JSON.parse(data));
            else if (shape) this.addToScratchpad((root.PixelNodeTemplates || {})[shape]);
            else this.addToScratchpad();
        }.bind(this));
    };

    Sidebar.prototype.createSearch = function(panel, mode) {
        var wrap = document.createElement('div');
        wrap.className = 'geSearchWrap';
        var search = document.createElement('input');
        search.className = 'geSearchBox';
        search.type = 'search';
        search.placeholder = 'Search Shapes';
        wrap.appendChild(search);
        panel.appendChild(wrap);
        search.addEventListener('input', function() {
            var query = search.value.trim().toLowerCase();
            this.panelSections[mode].forEach(function(section) {
                var matched = 0;
                section.items.forEach(function(item) {
                    var hit = !query || (item.dataset.search || '').indexOf(query) >= 0;
                    item.hidden = !hit;
                    if (hit) matched++;
                });
                var visible = !query || matched > 0;
                section.title.hidden = !visible;
                section.outer.hidden = !visible;
                if (query && visible) section.body.style.display = 'block';
            });
        }.bind(this));
    };

    Sidebar.prototype.addPalette = function(panel, mode, palette) {
        var title = this.createTitle(palette.name);
        var body = document.createElement('div');
        body.className = 'geSidebar';
        body.style.touchAction = 'none';
        if (!palette.expanded) body.style.display = 'none';
        panel.appendChild(title);
        var outer = document.createElement('div');
        outer.appendChild(body);
        panel.appendChild(outer);
        this.addFoldingHandler(title, body);

        var section = { title: title, outer: outer, body: body, items: [], palette: palette };
        this.panelSections[mode].push(section);
        if (palette.stencilLibrary) this.stencilHosts[palette.stencilLibrary.toLowerCase()] = section;

        // A classic palette carries its shapes as mxGraph styles.
        if (palette.classic) {
            this.classicEntries(palette.classic).forEach(function(entry) {
                var item = this.createItem(null, entry.title, entry.template,
                    entry.previewSource);
                body.appendChild(item);
                section.items.push(item);
            }, this);
            return section;
        }

        (palette.items || []).forEach(function(info) {
            if (!(root.PixelNodeTemplates || {})[info[0]]) return;
            var item = this.createItem(info[0], info[1]);
            body.appendChild(item);
            section.items.push(item);
        }, this);
        return section;
    };

    Sidebar.prototype.buildPanel = function(panel, mode, palettes) {
        this.createScratchpad(panel);
        this.createSearch(panel, mode);
        palettes.forEach(function(palette) { this.addPalette(panel, mode, palette); }, this);
    };

    Sidebar.prototype.addStencilPalettes = function() {
        if (root.PixelStencils == null) return;
        var libraries = root.PixelStencils.byLibrary();
        Object.keys(libraries).forEach(function(library) {
            var key = String(library).toLowerCase();
            var host = this.stencilHosts[key];
            if (!host) return;
            var already = this.loadedStencilLibraries[key] || Object.create(null);
            this.loadedStencilLibraries[key] = already;
            libraries[library].forEach(function(shape) {
                if (already[shape.key]) return;
                already[shape.key] = true;
                var template = {
                    shape: 'stencil', stencil: shape.key, text: '',
                    width: Math.max(60, Math.round(shape.w)), height: Math.max(40, Math.round(shape.h)),
                    fill: '#ffffff',
                    stroke: key === 'mxgraph.basic' ? '#000000' : '#4a5564',
                    strokeWidth: key === 'mxgraph.basic' ? 2 : 1.5
                };
                var item = this.createItem(null, shape.name, template);
                // Stencil entries are templates, but not scratchpad entries; keep their search metadata.
                item.setAttribute('title', shape.name);
                host.body.appendChild(item);
                host.items.push(item);
            }, this);

            if (key === 'mxgraph.basic' && !already.__partialRectangles) {
                already.__partialRectangles = true;
                [
                    { top: false, bottom: false },
                    { right: false, top: false, bottom: false },
                    { bottom: false, right: false },
                    { top: false, left: false }
                ].forEach(function(sides) {
                    var template = Object.assign({
                        shape: 'partialRectangle', text: '', width: 120, height: 60,
                        fill: 'transparent', stroke: '#000000', strokeWidth: 1
                    }, sides);
                    var item = this.createItem(null, 'Partial Rectangle', template);
                    host.body.appendChild(item);
                    host.items.push(item);
                }, this);
            }
        }, this);
    };

    Sidebar.prototype.build = function(container) {
        this.container = container;
        container.innerHTML = '';

        var tabs = document.createElement('div');
        tabs.className = 'geSidebarTabs';
        var tabOriginal = document.createElement('div');
        tabOriginal.className = 'geSidebarTab active';
        tabOriginal.textContent = 'Original';
        var tabVisual = document.createElement('div');
        tabVisual.className = 'geSidebarTab';
        tabVisual.textContent = 'Visual Script';
        tabs.appendChild(tabOriginal);
        tabs.appendChild(tabVisual);
        container.appendChild(tabs);

        var panelOriginal = document.createElement('div');
        panelOriginal.className = 'geSidebarTabPanel active';
        panelOriginal.id = 'originalMxGraphObj';
        var panelVisual = document.createElement('div');
        panelVisual.className = 'geSidebarTabPanel';
        panelVisual.id = 'visualScript';
        container.appendChild(panelOriginal);
        container.appendChild(panelVisual);

        this.originalPanel = panelOriginal;
        this.visualScriptPanel = panelVisual;
        this.buildPanel(panelOriginal, 'original', this.originalPalettes);
        // In the classic extension Scratchpad and Search belonged to the
        // original mxGraph inventory. The Visual Script tab started directly
        // with its script cards.
        this.visualPalettes.forEach(function(palette) {
            this.addPalette(panelVisual, 'visual', palette);
        }, this);
        this.renderScratchpad();
        this.addStencilPalettes();

        function switchTab(showOriginal) {
            tabOriginal.className = 'geSidebarTab' + (showOriginal ? ' active' : '');
            tabVisual.className = 'geSidebarTab' + (!showOriginal ? ' active' : '');
            panelOriginal.className = 'geSidebarTabPanel' + (showOriginal ? ' active' : '');
            panelVisual.className = 'geSidebarTabPanel' + (!showOriginal ? ' active' : '');
        }
        tabOriginal.addEventListener('click', function() { switchTab(true); });
        tabVisual.addEventListener('click', function() { switchTab(false); });
    };

    root.Sidebar = Sidebar;
})(window);
