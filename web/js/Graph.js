/*
 * Graph -- the page side of the QGraph diagram engine.
 *
 * The scene model, selection, handles, connectors, groups, layers, tables,
 * undo history and painting all live in the Nim engine (qgraph.wasm, see
 * src/graph*.nim). This class keeps the public API the editor chrome was
 * written against and owns the parts that need the DOM: the scrolling
 * container and its two canvases, pointer/keyboard/drag input, the label
 * editor, tooltips, media playback, stencil loading and export.
 */
(function(root) {
    'use strict';

    var HOST = {
        EMIT: 1, RENDER: 2, SPACER: 3, RENDERER_SYNC: 4, RENDERER_UPSERT: 5,
        RENDERER_REMOVE: 6, OVERLAY: 7, CURSOR: 8, TOOLTIP: 9, OPEN_LINK: 10,
        TEXT_EDITOR_OPEN: 11, TEXT_EDITOR_CLOSE: 12, RICH_FROM_HTML: 13, TIMER: 14
    };
    var FLAG_PREVENT = 1;
    var FLAG_CAPTURE = 2;
    var FLAG_RELEASE = 4;
    /* JSON cannot carry `undefined`; the engine reads this marker as it. */
    var UNDEFINED = '\u0001undefined';

    function encodeArgs(args) {
        return JSON.stringify(args, function(key, value) {
            return value === undefined && key !== '' ? UNDEFINED : value;
        });
    }

    function idOf(value) {
        if (value == null) return null;
        if (typeof value === 'object') return value.id == null ? null : value.id;
        return value;
    }

    function modifierFlags(event) {
        return (event.shiftKey ? 1 : 0) | (event.ctrlKey ? 2 : 0) | (event.metaKey ? 4 : 0) |
            (event.altKey ? 8 : 0) | (event.pointerType === 'touch' ? 16 : 0);
    }

    function Graph(container, options) {
        options = options || {};
        this.container = container;
        this.engine = root.QGraphWasm && root.QGraphWasm.engine;
        if (!this.engine) throw new Error('The QGraph engine must be loaded before creating a Graph');
        this.listeners = Object.create(null);
        this.destroyed = false;
        this.mobileMode = options.mobileMode === true;
        this.selectionIds = [];
        this.lastClient = { x: 0, y: 0 };
        this.textEditor = null;

        this.painterHandle = this.engine.exports.qg_graph_new(this.mobileMode ? 1 : 0);
        this.installHost();
        this.createSurface(options);
        // A decoded image arrives after the frame that asked for it.
        if (this.renderer && this.renderer.realtimePainter) {
            this.renderer.realtimePainter.onImageLoad = this.render.bind(this, false);

            // GIF frames are decoded by us, not by the browser's image
            // animation, which does not run for pictures that are only ever
            // sampled through drawImage.
            if (typeof root.GifPlayback === 'function' && typeof Worker !== 'undefined') {
                this.playback = new root.GifPlayback({
                    workerUrl: (options && options.gifWorkerUrl) || 'js/gif-worker.js',
                    onFrame: function() { this.render(true); }.bind(this)
                });
                this.renderer.realtimePainter.playback = this.playback;
                if (this.renderer.fallbackPainter) this.renderer.fallbackPainter.playback = this.playback;
            }
            if (typeof root.MediaPlayback === 'function') {
                this.mediaPlayback = new root.MediaPlayback({
                    onFrame: function() {
                        if (!this.hasAction()) this.render(true);
                    }.bind(this)
                });
                this.renderer.realtimePainter.mediaPlayback = this.mediaPlayback;
                if (this.renderer.fallbackPainter) {
                    this.renderer.fallbackPainter.mediaPlayback = this.mediaPlayback;
                }
            }
            if (typeof root.MediaOverlayManager === 'function' && this.mediaLayer) {
                this.mediaOverlay = new root.MediaOverlayManager({
                    graph: this,
                    layer: this.mediaLayer
                });
            }
        }
        this.installEvents();
        if (typeof ResizeObserver !== 'undefined') {
            this.resizeObserver = new ResizeObserver(function() {
                this.updateWorldSize();
                this.render();
            }.bind(this));
            this.resizeObserver.observe(container);
        } else {
            this.boundWindowResize = function() {
                this.updateWorldSize();
                this.render();
            }.bind(this);
            window.addEventListener('resize', this.boundWindowResize);
        }
        this.engine.exports.qg_graph_start();
    }

    /* ------------------------------------------------------------------ */
    /* Engine bridge                                                       */
    /* ------------------------------------------------------------------ */

    Graph.prototype.call = function(method, args) {
        var engine = this.engine;
        var out = engine.callOut('qg_call', [], encodeArgs({ m: method, a: args || [] }));
        var reply = out ? JSON.parse(out) : {};
        if (reply.error) throw new Error(reply.error);
        return reply.r;
    };

    Graph.prototype.installHost = function() {
        var graph = this;
        var engine = this.engine;
        var handlers = engine.hostHandlers;

        engine.viewMetrics = function() {
            var c = graph.container;
            return [c.clientWidth, c.clientHeight, Number(c.scrollLeft) || 0,
                Number(c.scrollTop) || 0, window.devicePixelRatio || 1];
        };
        engine.setScroll = function(left, top) {
            if (!isNaN(left)) graph.container.scrollLeft = left;
            if (!isNaN(top)) graph.container.scrollTop = top;
        };

        handlers[HOST.EMIT] = function(payload) {
            var message = JSON.parse(payload);
            if (message.name === 'selectionchange') {
                graph.selectionIds = (message.data || []).map(function(item) { return item.id; });
            }
            graph.emit(message.name, message.data);
        };
        handlers[HOST.RENDER] = function(payload) {
            var message = JSON.parse(payload);
            graph.renderFrame(message.view, message.realtime === true);
        };
        handlers[HOST.SPACER] = function(payload) {
            var size = JSON.parse(payload);
            graph.spacer.style.width = size.width + 'px';
            graph.spacer.style.height = size.height + 'px';
        };
        handlers[HOST.RENDERER_SYNC] = function(payload) {
            if (!graph.renderer) return;
            graph.renderer.sync(JSON.parse(payload).media || []);
        };
        handlers[HOST.RENDERER_UPSERT] = function(payload) {
            if (!graph.renderer) return;
            var message = JSON.parse(payload);
            graph.renderer.upsert(message.ids || [], message.defer === true, message.media || null);
        };
        handlers[HOST.RENDERER_REMOVE] = function(payload) {
            if (!graph.renderer) return;
            graph.renderer.remove(JSON.parse(payload).ids || [], graph.mediaItems());
        };
        handlers[HOST.OVERLAY] = function() {
            if (graph.overlayContext) engine.replay(graph.overlayContext, null);
        };
        handlers[HOST.CURSOR] = function(payload) {
            graph.overlayCanvas.style.cursor = JSON.parse(payload).cursor;
        };
        handlers[HOST.TOOLTIP] = function(payload) {
            graph.showTooltip(JSON.parse(payload));
        };
        handlers[HOST.OPEN_LINK] = function(payload) {
            window.open(graph.getAbsoluteUrl(JSON.parse(payload).href), '_blank', 'noopener,noreferrer');
        };
        handlers[HOST.TEXT_EDITOR_OPEN] = function(payload) {
            graph.openTextEditor(JSON.parse(payload));
        };
        handlers[HOST.TEXT_EDITOR_CLOSE] = function() {
            return graph.closeTextEditor();
        };
        handlers[HOST.RICH_FROM_HTML] = function(html) {
            if (root.PixelRichText == null) return null;
            return JSON.stringify(root.PixelRichText.fromHtml(html));
        };
        handlers[HOST.TIMER] = function(payload) {
            var message = JSON.parse(payload);
            if (message.name !== 'autoscroll') return;
            clearTimeout(graph.dragAutoScrollTimer);
            graph.dragAutoScrollTimer = null;
            if (message.cancel) return;
            graph.dragAutoScrollTimer = setTimeout(function() {
                graph.dragAutoScrollTimer = null;
                if (!graph.destroyed) engine.call('qg_timer', [], 'autoscroll');
            }, message.ms || 30);
        };
    };

    /* ------------------------------------------------------------------ */
    /* Surface                                                             */
    /* ------------------------------------------------------------------ */

    Graph.prototype.createSurface = function(options) {
        this.container.innerHTML = '';
        this.container.classList.add('pixel-diagram-container');
        this.container.setAttribute('tabindex', '0');

        this.spacer = document.createElement('div');
        this.spacer.className = 'pixel-world-spacer';
        this.container.appendChild(this.spacer);

        this.baseCanvas = document.createElement('canvas');
        this.baseCanvas.className = 'pixel-base-canvas';
        this.baseCanvas.setAttribute('aria-label', 'Pixel diagram');
        this.container.appendChild(this.baseCanvas);

        this.mediaLayer = document.createElement('div');
        this.mediaLayer.className = 'pixel-media-layer';
        this.container.appendChild(this.mediaLayer);

        this.overlayCanvas = document.createElement('canvas');
        this.overlayCanvas.className = 'pixel-overlay-canvas';
        this.overlayCanvas.setAttribute('aria-label', 'Diagram interactions');
        this.container.appendChild(this.overlayCanvas);
        this.overlayContext = this.overlayCanvas.getContext('2d', {
            alpha: true,
            desynchronized: true
        });

        var graph = this;
        this.renderer = new CanvasRenderer(this.baseCanvas, {
            workerUrl: options.workerUrl || 'js/renderer-worker.js',
            painterHandle: this.painterHandle,
            itemsJson: function(ids) {
                if (ids == null) return graph.engine.callOut('qg_items', []);
                return graph.engine.callOut('qg_items_by_ids', [], JSON.stringify(ids));
            },
            onStats: function(stats) {
                this.stats = stats;
                this.emit('stats', stats);
            }.bind(this)
        });
    };

    Graph.prototype.on = function(name, listener) {
        if (!this.listeners[name]) this.listeners[name] = [];
        this.listeners[name].push(listener);
        return listener;
    };

    Graph.prototype.emit = function(name, data) {
        var listeners = this.listeners[name] || [];
        for (var i = 0; i < listeners.length; i++) listeners[i](data);
    };

    /* Scene items that carry pictures or video. */
    Graph.prototype.mediaItems = function() {
        var out = this.engine.callOut('qg_media_items', []);
        return out ? JSON.parse(out) : [];
    };

    Graph.prototype.updateCanvasPositions = function(view) {
        // Canvases follow the physical DOM scroll position. view.scrollX/Y are
        // logical painter offsets and may be negative on an infinite canvas.
        var left = (Number(this.container.scrollLeft) || 0) + 'px';
        var top = (Number(this.container.scrollTop) || 0) + 'px';
        var width = view.width + 'px';
        var height = view.height + 'px';
        this.baseCanvas.style.left = left;
        this.baseCanvas.style.top = top;
        this.baseCanvas.style.width = width;
        this.baseCanvas.style.height = height;
        this.overlayCanvas.style.left = left;
        this.overlayCanvas.style.top = top;
        this.overlayCanvas.style.width = width;
        this.overlayCanvas.style.height = height;

        var dpr = view.dpr;
        var pixelWidth = Math.max(1, Math.floor(view.width * dpr));
        var pixelHeight = Math.max(1, Math.floor(view.height * dpr));
        if (this.overlayCanvas.width !== pixelWidth) this.overlayCanvas.width = pixelWidth;
        if (this.overlayCanvas.height !== pixelHeight) this.overlayCanvas.height = pixelHeight;
    };

    /* Animated sources (GIF, APNG, animated WebP) only move if something keeps
       redrawing them, and only the main-thread painter holds the live <img>:
       a worker ImageBitmap is one frozen frame. So while an animated picture
       is on screen the scene repaints on a capped timer through the realtime
       path. The timer stops as soon as none is visible, so a still diagram
       costs nothing. */
    Graph.prototype.ANIMATION_FPS = 15;

    Graph.prototype.syncAnimation = function(view) {
        var painter = this.renderer && this.renderer.realtimePainter;
        var animationState = painter != null && typeof painter.visibleAnimationState === 'function' ?
            painter.visibleAnimationState(view || this.getViewState()) : null;
        var animating = animationState != null ? animationState.any : false;
        var parallaxAnimating = animationState != null && animationState.parallax === true;
        if (this.renderer) {
            this.renderer.animating = animating;
            this.renderer.parallaxAnimating = parallaxAnimating;
        }

        if (!animating) {
            if (this.animationTimer != null) {
                if (this.animationUsesFrames) cancelAnimationFrame(this.animationTimer);
                else clearTimeout(this.animationTimer);
                this.animationTimer = null;
            }
            return false;
        }

        var decoding = this.playback != null && this.playback.players.size > 0;

        if (this.animationTimer == null) {
            if (parallaxAnimating) {
                this.animationTimer = requestAnimationFrame(function(now) {
                    this.animationTimer = null;
                    if (this.destroyed) return;
                    if (decoding) this.playback.tick(now);
                    this.renderAnimationFrame();
                }.bind(this));
                this.animationUsesFrames = true;
            } else if (decoding) {
                this.animationTimer = requestAnimationFrame(function() {
                    this.animationTimer = null;
                    if (this.destroyed) return;
                    this.playback.tick();
                    this.syncAnimation();
                }.bind(this));
                this.animationUsesFrames = true;
            } else {
                this.animationUsesFrames = false;
                this.animationTimer = setTimeout(function() {
                    this.animationTimer = null;
                    if (this.destroyed) return;
                    if (!this.hasAction()) this.render(true);
                    else this.syncAnimation();
                }.bind(this), Math.round(1000 / this.ANIMATION_FPS));
            }
        }

        return true;
    };

    /* Called by the engine's render(): present the scene and sync overlays.
       The engine then redraws the interaction overlay itself. */
    Graph.prototype.renderFrame = function(view, realtime) {
        if (this.destroyed) return;
        this.lastView = view;
        this.updateCanvasPositions(view);
        var animating = this.syncAnimation(view);
        this.renderer.requestFrame(view, realtime || animating);
        if (this.mediaOverlay) this.mediaOverlay.sync(this.mediaItems(), view);
    };

    Graph.prototype.render = function(forceRealtime) {
        if (this.destroyed) return;
        this.engine.exports.qg_render(forceRealtime === true ? 1 : 0);
    };

    /* Lightweight scene-only frame for cursor parallax/scrolling layers. */
    Graph.prototype.renderAnimationFrame = function() {
        if (this.destroyed) return;
        var view = this.getViewState();
        this.updateCanvasPositions(view);
        this.syncAnimation(view);
        this.renderer.requestFrame(view, true);
    };

    Graph.prototype.renderScrollFrame = function() {
        this.render(true);
        clearTimeout(this.scrollSettleTimer);
        this.scrollSettleTimer = setTimeout(function() {
            if (!this.hasAction()) this.render(false);
        }.bind(this), 90);
    };

    Graph.prototype.drawOverlay = function() {
        this.engine.exports.qg_draw_overlay();
    };

    Graph.prototype.hasAction = function() {
        return this.call('get', ['action']) != null;
    };

    /* ------------------------------------------------------------------ */
    /* Input                                                               */
    /* ------------------------------------------------------------------ */

    Graph.prototype.screenPoint = function(event) {
        var rect = this.overlayCanvas.getBoundingClientRect();
        return { x: event.clientX - rect.left, y: event.clientY - rect.top };
    };

    Graph.prototype.eventPoint = function(event) {
        var screen = this.screenPoint(event);
        return { screen: screen, world: this.call('screenToWorld', [screen]) };
    };

    Graph.prototype.pointer = function(kind, event) {
        var p = this.screenPoint(event);
        return this.engine.exports.qg_pointer(kind, p.x, p.y, event.button || 0, modifierFlags(event));
    };

    Graph.prototype.installEvents = function() {
        this.boundScroll = this.renderScrollFrame.bind(this);
        this.boundParallaxPointerMove = this.updateParallaxPointer.bind(this);
        this.container.addEventListener('scroll', this.boundScroll, { passive: true });
        window.addEventListener('pointermove', this.boundParallaxPointerMove, { passive: true, capture: true });
        this.overlayCanvas.addEventListener('pointerdown', this.pointerDown.bind(this));
        this.overlayCanvas.addEventListener('pointermove', this.pointerMove.bind(this));
        this.overlayCanvas.addEventListener('pointerleave', this.pointerLeave.bind(this));
        this.overlayCanvas.addEventListener('pointerup', this.pointerUp.bind(this));
        this.overlayCanvas.addEventListener('pointercancel', this.pointerUp.bind(this));
        this.overlayCanvas.addEventListener('dblclick', this.doubleClick.bind(this));
        this.overlayCanvas.addEventListener('contextmenu', this.contextMenu.bind(this));
        this.container.addEventListener('wheel', this.wheel.bind(this), { passive: false });
        this.container.addEventListener('dragover', this.dragOver.bind(this));
        this.container.addEventListener('dragleave', this.dragLeave.bind(this));
        this.container.addEventListener('drop', this.drop.bind(this));
        this.boundDragEnd = this.clearReplaceTarget.bind(this);
        window.addEventListener('dragend', this.boundDragEnd);
        this.container.addEventListener('keydown', this.keyDown.bind(this));
        this.container.addEventListener('keyup', this.keyUp.bind(this));
    };

    Graph.prototype.pointerDown = function(event) {
        this.container.focus({ preventScroll: true });
        this.lastClient = { x: event.clientX, y: event.clientY };
        var flags = this.pointer(0, event);
        if (flags & FLAG_CAPTURE) {
            try { this.overlayCanvas.setPointerCapture(event.pointerId); } catch (error) { /* synthetic */ }
        }
        if (flags & FLAG_PREVENT) event.preventDefault();
    };

    Graph.prototype.pointerMove = function(event) {
        this.lastClient = { x: event.clientX, y: event.clientY };
        var flags = this.pointer(1, event);
        if (flags & FLAG_PREVENT) event.preventDefault();
    };

    Graph.prototype.pointerUp = function(event) {
        var flags = this.pointer(2, event);
        if (flags & FLAG_RELEASE) {
            try { this.overlayCanvas.releasePointerCapture(event.pointerId); } catch (error) { /* not captured */ }
        }
        if (flags & FLAG_PREVENT) event.preventDefault();
    };

    Graph.prototype.pointerLeave = function(event) {
        this.pointer(4, event);
    };

    Graph.prototype.doubleClick = function(event) {
        var flags = this.pointer(3, event);
        if (flags & FLAG_PREVENT) event.preventDefault();
    };

    Graph.prototype.contextMenu = function(event) {
        var p = this.screenPoint(event);
        var data = this.engine.callOutJson('qg_context_menu', [p.x, p.y, modifierFlags(event)]) || {};
        this.emit('contextmenu', { event: event, item: data.item || null, point: data.point });
        event.preventDefault();
    };

    Graph.prototype.wheel = function(event) {
        if (event.ctrlKey || event.metaKey || event.altKey) {
            var rect = this.container.getBoundingClientRect();
            var screen = { x: event.clientX - rect.left, y: event.clientY - rect.top };
            this.setZoom(this.zoom * (event.deltaY < 0 ? 1.12 : 1 / 1.12), screen);
            event.preventDefault();
        }
    };

    Graph.prototype.keyDown = function(event) {
        var flags = this.engine.call('qg_key', [1, modifierFlags(event)],
            String(event.key || '') + '\t' + String(event.code || ''));
        if (flags & FLAG_PREVENT) event.preventDefault();
    };

    Graph.prototype.keyUp = function(event) {
        this.engine.call('qg_key', [0, modifierFlags(event)],
            String(event.key || '') + '\t' + String(event.code || ''));
    };

    /* True while a palette or scratchpad entry is being dragged. */
    Graph.prototype.isShapeDrag = function(event) {
        var types = event.dataTransfer ? event.dataTransfer.types : null;
        if (types == null) return false;
        return Array.prototype.indexOf.call(types, 'application/x-pixel-shape') >= 0 ||
            Array.prototype.indexOf.call(types, 'application/x-pixel-shape-data') >= 0;
    };

    Graph.prototype.dragOver = function(event) {
        event.preventDefault();
        var p = this.screenPoint(event);
        this.engine.exports.qg_drag_over(p.x, p.y, this.isShapeDrag(event) ? 1 : 0);
    };

    Graph.prototype.dragLeave = function(event) {
        // Crossing between the canvas and its own children also fires this.
        if (event != null && event.relatedTarget != null &&
            this.container.contains(event.relatedTarget)) return;
        this.clearReplaceTarget();
    };

    Graph.prototype.clearReplaceTarget = function() {
        if (this.destroyed) return;
        this.engine.exports.qg_drag_clear();
    };

    Graph.prototype.drop = function(event) {
        event.preventDefault();
        var screen = this.screenPoint(event);
        var files = event.dataTransfer.files;

        if (files != null && files.length > 0 && /^image\//.test(files[0].type)) {
            this.clearReplaceTarget();
            var world = this.call('screenToWorld', [screen]);
            var reader = new FileReader();
            reader.onload = function() {
                this.insertImage(String(reader.result), files[0].name,
                    { x: world.x - 90, y: world.y - 60 });
            }.bind(this);
            reader.readAsDataURL(files[0]);
            return;
        }

        // Scratchpad entries carry their whole definition on the drag.
        var literal = event.dataTransfer.getData('application/x-pixel-shape-data');
        var type = event.dataTransfer.getData('application/x-pixel-shape') || 'process';
        var templates = root.PixelNodeTemplates || {};
        var data = literal ? JSON.parse(literal) :
            JSON.parse(JSON.stringify(templates[type] || templates.process || {}));
        this.engine.callOut('qg_drop', [screen.x, screen.y], encodeArgs(data));
    };

    /* ------------------------------------------------------------------ */
    /* Cursor parallax                                                     */
    /* ------------------------------------------------------------------ */

    Graph.prototype.setParallaxPointer = function(x, y) {
        var renderer = this.renderer;
        var painter = renderer && renderer.realtimePainter;
        if (!painter || !painter.hasLayeredItems) return false;

        if (typeof renderer.setParallaxTarget === 'function') {
            renderer.setParallaxTarget(x, y);
        } else if (typeof painter.setParallaxTarget === 'function') {
            painter.setParallaxTarget(x, y);
        }

        if (this.parallaxPointerFrame == null && typeof requestAnimationFrame === 'function') {
            this.parallaxPointerFrame = requestAnimationFrame(function() {
                this.parallaxPointerFrame = null;
                if (!this.destroyed) this.render(true);
            }.bind(this));
        } else if (typeof requestAnimationFrame !== 'function') {
            this.render(true);
        }
        return true;
    };

    Graph.prototype.updateParallaxPointer = function(event) {
        var painter = this.renderer && this.renderer.realtimePainter;
        if (!painter || !painter.hasLayeredItems || !event) return;
        if (event.pointerType === 'touch' || event.isPrimary === false) return;
        var rect = this.overlayCanvas.getBoundingClientRect();
        if (!rect.width || !rect.height) return;
        var x = ((event.clientX - rect.left) / rect.width - .5) * 2;
        var y = ((event.clientY - rect.top) / rect.height - .5) * 2;
        this.setParallaxPointer(Math.max(-1, Math.min(1, x)), Math.max(-1, Math.min(1, y)));
    };

    /* ------------------------------------------------------------------ */
    /* Tooltip and links                                                   */
    /* ------------------------------------------------------------------ */

    Graph.prototype.showTooltip = function(request) {
        clearTimeout(this.tooltipTimer);
        if (request.hide) {
            this.tooltipFor = null;
            if (this.tooltipElement) this.tooltipElement.style.display = 'none';
            return;
        }
        if (this.tooltipElement && this.tooltipFor === request.id) return;
        var x = this.lastClient.x + 12;
        var y = this.lastClient.y + 18;
        this.tooltipTimer = setTimeout(function() {
            if (!this.tooltipElement) {
                this.tooltipElement = document.createElement('div');
                this.tooltipElement.className = 'mxTooltip geCanvasTooltip';
                document.body.appendChild(this.tooltipElement);
            }
            this.tooltipFor = request.id;
            this.tooltipElement.textContent = request.text;
            this.tooltipElement.style.left = x + 'px';
            this.tooltipElement.style.top = y + 'px';
            this.tooltipElement.style.display = 'block';
        }.bind(this), 500);
    };

    Graph.prototype.hideTooltip = function() {
        this.showTooltip({ hide: true });
    };

    /* Resolves a relative link against the page, as the classic
       Graph.getAbsoluteUrl did, so "notes/a.html" works from a diagram. */
    Graph.prototype.getAbsoluteUrl = function(href) {
        href = String(href == null ? '' : href).trim();
        if (!href || /^[a-z][a-z0-9+.-]*:/i.test(href) || href.charAt(0) === '#') return href;
        try {
            return new URL(href, window.location.href).href;
        } catch (error) {
            return href;
        }
    };

    Graph.prototype.openLink = function(href) {
        return this.call('openLink', [href]);
    };

    /* ------------------------------------------------------------------ */
    /* Label editor                                                        */
    /* ------------------------------------------------------------------ */

    /* Browser headings use different scales from PixelRichText, and an
       absolute font-size on a run would otherwise bypass the heading scale.
       Temporarily scale those runs for editing, then restore their logical
       sizes before parsing the edited HTML back into the canvas model. */
    Graph.prototype.prepareRichEditorStyles = function(field) {
        var scales = { H1: 1.7, H2: 1.4, H3: 1.2 };
        var sized = field.querySelectorAll('span[style*="font-size"]');
        for (var i = 0; i < sized.length; i++) {
            var value = parseFloat(sized[i].style.fontSize);
            if (!isFinite(value)) continue;
            var block = sized[i].closest('h1,h2,h3');
            var scale = block ? (scales[block.tagName] || 1) : 1;
            sized[i].dataset.pixelLogicalFontSize = String(value);
            sized[i].style.fontSize = (value * scale) + 'px';
        }
    };

    Graph.prototype.restoreRichEditorStyles = function(field) {
        var sized = field.querySelectorAll('[data-pixel-logical-font-size]');
        for (var i = 0; i < sized.length; i++) {
            sized[i].style.fontSize = sized[i].dataset.pixelLogicalFontSize + 'px';
            delete sized[i].dataset.pixelLogicalFontSize;
        }
    };

    Graph.prototype.openTextEditor = function(d) {
        var editor = document.createElement('div');
        editor.className = 'pixel-text-editor';
        // The editor is an absolutely-positioned child of the scrolling world
        // spacer, so it uses DOM-world coordinates, not viewport coordinates.
        editor.style.left = d.left + 'px';
        editor.style.top = d.top + 'px';
        editor.style.width = d.width + 'px';
        editor.style.height = d.height + 'px';
        // The box grows with the text instead of scrolling it.
        editor.style.minHeight = d.height + 'px';
        editor.style.height = 'auto';
        editor.style.alignItems = d.alignItems;

        var field = document.createElement('div');
        field.className = 'pixel-text-input';
        field.setAttribute('contenteditable', 'true');
        field.setAttribute('spellcheck', 'false');
        if (d.html != null) {
            field.innerHTML = d.html;
            this.prepareRichEditorStyles(field);
        } else {
            field.textContent = d.text || '';
        }
        // Explicit sizes matter: .geDiagramContainer sets font-size to 0.
        field.style.fontFamily = d.fontFamily;
        field.style.fontSize = d.fontSize + 'px';
        field.style.fontWeight = d.fontWeight;
        field.style.fontStyle = d.fontStyle;
        field.style.color = d.color;
        field.style.textAlign = d.textAlign;
        field.style.lineHeight = '1.28';
        field.style.width = d.fieldWidth + 'px';
        field.style.paddingLeft = d.padding + 'px';
        field.style.paddingRight = d.padding + 'px';
        field.style.zoom = d.zoom;
        field.style.textDecoration = d.textDecoration;
        if (d.transform) {
            editor.style.transformOrigin = d.transformOrigin;
            editor.style.transform = d.transform;
        }
        editor.appendChild(field);
        this.container.appendChild(editor);
        this.textEditor = { element: editor, field: field, tabbable: d.tabbable === true };

        field.focus({ preventScroll: true });
        var range = document.createRange();
        range.selectNodeContents(field);
        var selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);

        var graph = this;
        field.addEventListener('keydown', function(event) {
            if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') graph.finishTextEdit(true);
            else if (event.key === 'Escape') graph.finishTextEdit(false);
            else if (event.key === 'Tab' && graph.textEditor && graph.textEditor.tabbable) {
                // Tab walks to the next cell, as in a spreadsheet.
                event.preventDefault();
                graph.engine.exports.qg_text_editor_tab(event.shiftKey ? 1 : 0);
                return;
            }
            event.stopPropagation();
        });
        field.addEventListener('pointerdown', function(event) { event.stopPropagation(); });
        field.addEventListener('blur', function() { graph.finishTextEdit(true); }, { once: true });
        this.emit('texteditstart', this.textEditor);
    };

    /* The engine is committing or cancelling the edit: hand it the field's
       text and parsed rich model, and take the editor down. */
    Graph.prototype.closeTextEditor = function() {
        var data = this.textEditor;
        this.textEditor = null;
        if (!data) return JSON.stringify({ plain: '', model: null });
        // innerText keeps the visual line breaks; textContent is the fallback.
        var raw = data.field.innerText;
        if (raw == null) raw = data.field.textContent;
        var plain = String(raw || '')
            .replace(/\r\n?/g, '\n')
            .replace(/ /g, ' ')
            .replace(/\n+$/, '');
        // Undo temporary visual heading scaling before the HTML bridge turns
        // inline sizes back into logical rich-text run sizes.
        this.restoreRichEditorStyles(data.field);
        var model = root.PixelRichText ? root.PixelRichText.fromHtml(data.field.innerHTML) : null;
        if (data.element.parentNode) data.element.parentNode.removeChild(data.element);
        return JSON.stringify({ plain: plain, model: model });
    };

    Graph.prototype.startTextEdit = function(node) {
        this.call('startTextEdit', [idOf(node)]);
    };

    Graph.prototype.finishTextEdit = function(commit) {
        if (this.destroyed) return;
        this.engine.exports.qg_text_editor_finish(commit === false ? 0 : 1);
    };

    Graph.prototype.isEditingText = function() {
        return this.textEditor != null;
    };

    /* Runs a browser editing command inside the open label. */
    Graph.prototype.execTextCommand = function(command, value) {
        if (this.textEditor == null) return false;
        this.textEditor.field.focus({ preventScroll: true });
        try {
            document.execCommand(command, false, value == null ? null : value);
        } catch (error) {
            return false;
        }
        return true;
    };

    /* ------------------------------------------------------------------ */
    /* Model API (forwarded to the engine)                                 */
    /* ------------------------------------------------------------------ */

    function forward(name, convert) {
        Graph.prototype[name] = function() {
            var args = Array.prototype.slice.call(arguments);
            if (convert) args = convert.apply(this, args);
            return this.call(name, args);
        };
    }

    [
        'snapshot', 'undo', 'redo', 'canUndo', 'canRedo', 'toJSON', 'rebuildIndex',
        'getSelection', 'getSelectedTableCell', 'removeSelection', 'copy', 'cut', 'duplicate',
        'changeZ', 'previewStyle', 'commitPreview', 'getCommonStyle', 'selectByType',
        'groupSelection', 'ungroupSelection', 'enterGroup', 'exitGroup', 'removeFromGroup',
        'getLayer', 'addLayer', 'removeLayer', 'updateLayer', 'moveLayer', 'moveSelectionToLayer',
        'hiddenLayerIds', 'createTable', 'autosizeSelection', 'copySize', 'pasteSize',
        'clearLabels', 'deleteAll', 'resetView', 'fitPage', 'toggleLock', 'alignSelection',
        'distributeSelection', 'rotateSelection', 'nudgeSelection', 'flipSelection',
        'resetWaypoints', 'addWaypointToSelection', 'reverseEdges', 'flipCircularArc',
        'copyStyle', 'pasteStyle', 'setDefaultStyle', 'clearDefaultStyle', 'setDiagramOptions',
        'getViewState', 'updateWorldSize', 'zoomIn', 'zoomOut', 'zoomActual', 'fit',
        'getAllBounds', 'worldToScreen', 'clearTableCellSelection', 'getGroupMembers',
        'getSelectedGroups', 'layoutStackContainers'
    ].forEach(function(name) { forward(name); });

    forward('commit', function(before, label) { return [before == null ? null : before, label]; });
    forward('paste', function(target) { return [target || null]; });
    forward('setSelection', function(ids, exact) {
        return [(ids || []).map(idOf), exact === true];
    });
    forward('toggleSelection', function(id) { return [idOf(id)]; });
    forward('isSelected', function(id) { return [idOf(id)]; });
    forward('getItem', function(id) { return [idOf(id)]; });
    forward('reindexNodeAndEdges', function(node) { return [idOf(node)]; });
    forward('effectiveGroup', function(item) { return [idOf(item)]; });
    forward('isLayerLocked', function(item) { return [idOf(item)]; });
    forward('toggleContainerFold', function(node) { return [idOf(node)]; });
    forward('tableCellAt', function(node, world) { return [idOf(node), world]; });
    forward('getCell', function(node, row, column) { return [idOf(node), row, column]; });
    forward('setCell', function(node, row, column, value, label) {
        return [idOf(node), row, column, value, label];
    });
    forward('getTableCell', function(table, row, column) { return [idOf(table), row, column]; });
    forward('setTableCell', function(table, row, column, value, style) {
        return [idOf(table), row, column, value, style];
    });
    ['insertTableRow', 'deleteTableRow', 'insertTableColumn', 'deleteTableColumn'].forEach(function(name) {
        forward(name, function(table, index) { return [idOf(table), index]; });
    });
    forward('mergeTableCells', function(table, a, b, c, d) { return [idOf(table), a, b, c, d]; });
    forward('unmergeTableCell', function(table, row, column) { return [idOf(table), row, column]; });
    forward('splitTableCell', function(table, row, column) { return [idOf(table), row, column]; });
    forward('changeTableSize', function(node, rows, columns) { return [idOf(node), rows, columns]; });
    forward('selectTableCell', function(node, cell, extend) { return [idOf(node), cell, extend === true]; });
    forward('connectVertex', function(source, side, dropPoint, before) {
        return [idOf(source), side, dropPoint || null, before || null];
    });
    forward('hitTest', function(point, ignoreId) { return [point, ignoreId || null]; });
    forward('toggleFold', function() { return []; });

    Graph.prototype.loadItems = function(items, resetHistory, layers) {
        return this.call('loadItems', [items || [], resetHistory !== false, layers || null]);
    };

    Graph.prototype.fromJSON = function(text) {
        return this.call('fromJSON', [typeof text === 'string' ? JSON.parse(text) : text]);
    };

    Graph.prototype.addNode = function(data, select) {
        return this.call('addNode', [data || {}, select !== false]);
    };

    Graph.prototype.addTemplate = function(template, position, select) {
        return this.call('addTemplate', [template || {}, position || null, select !== false]);
    };

    Graph.prototype.addEdge = function(data, select) {
        return this.call('addEdge', [data || {}, select !== false]);
    };

    /* Writes properties onto one live item (what the chrome used to do by
       mutating the object it held) and refreshes it. */
    Graph.prototype.updateItem = function(id, changes, label, record) {
        return this.call('updateItem', [idOf(id), changes || {}, label || '', record === true]);
    };

    Graph.prototype.getStyleTargetIds = function(predicate) {
        return this.call('getStyleTargetIds', [this.allowedIds(predicate)]);
    };

    /* The ids of selected items a JavaScript predicate accepts (null = all). */
    Graph.prototype.allowedIds = function(predicate) {
        if (typeof predicate !== 'function') return null;
        return this.getSelection().filter(predicate).map(function(item) { return item.id; });
    };

    Graph.prototype.applyStyle = function(changes, label, predicate) {
        return this.call('applyStyle', [changes || {}, label || '', this.allowedIds(predicate)]);
    };

    Graph.prototype.replaceShape = function(targets, template, label) {
        return this.call('replaceShape', [(targets || []).map(idOf), template || {}, label || '']);
    };

    Graph.prototype.setZoom = function(value, screenPoint) {
        return this.call('setZoom', [value, screenPoint || null]);
    };

    Graph.prototype.insertMedia = function(src, name, point, mediaType) {
        if (!src) return null;
        var resolvedMediaType = mediaType ||
            (root.PixelMedia ? root.PixelMedia.typeFor(src) : '');
        return this.call('insertMedia', [src, name || '', point || null, resolvedMediaType]);
    };

    Graph.prototype.insertImage = function(src, name, point) {
        return this.insertMedia(src, name, point, 'image');
    };

    /* ------------------------------------------------------------------ */
    /* Properties                                                          */
    /* ------------------------------------------------------------------ */

    [
        'zoom', 'gridSize', 'gridEnabled', 'gridColor', 'backgroundColor', 'pageView',
        'pageWidth', 'pageHeight', 'pageMargin', 'pageColumns', 'pageRows', 'pageStartColumn',
        'pageStartRow', 'infiniteWorldWidth', 'infiniteWorldHeight', 'worldOriginX',
        'worldOriginY', 'connectionArrows', 'connectionPoints', 'allowLoops',
        'defaultEdgeLength', 'guidesEnabled', 'portMode', 'pageScale', 'tooltipsEnabled',
        'layers', 'activeLayer', 'readOnly', 'defaultNodeStyle', 'defaultEdgeStyle',
        'styleClipboard', 'spacePressed', 'enteredGroups', 'hoverId'
    ].forEach(function(name) {
        Object.defineProperty(Graph.prototype, name, {
            get: function() { return this.call('get', [name]); },
            set: function(value) { this.call('set', [name, value]); },
            configurable: true
        });
    });

    Object.defineProperty(Graph.prototype, 'items', {
        get: function() {
            var out = this.engine.callOut('qg_items', []);
            return out ? JSON.parse(out) : [];
        },
        configurable: true
    });

    Object.defineProperty(Graph.prototype, 'selection', {
        get: function() { return this.selectionIds.slice(); },
        configurable: true
    });

    Object.defineProperty(Graph.prototype, 'action', {
        get: function() { return this.call('get', ['action']); },
        configurable: true
    });

    /* ------------------------------------------------------------------ */
    /* Stencils, export, storage                                           */
    /* ------------------------------------------------------------------ */

    /* Fetches and registers stencil libraries, then hands the parsed draw
       programs to the renderer so the worker can paint them as well. */
    Graph.prototype.loadStencils = function(urls) {
        if (typeof fetch !== 'function' || root.PixelStencils == null) return Promise.resolve([]);

        return Promise.all((urls || []).map(function(url) {
            return fetch(url).then(function(response) {
                if (!response.ok) throw new Error(response.status + ' ' + url);
                return response.text();
            }).then(function(xml) {
                var name = String(url).split('/').pop().replace(/\.xml$/i, '');
                return root.PixelStencils.parse(xml, 'mxgraph.' + name);
            }).catch(function() { return []; });
        })).then(function(groups) {
            var shapes = groups.reduce(function(all, group) { return all.concat(group); }, []);
            if (shapes.length > 0) {
                this.renderer.sendStencils(root.PixelStencils.all());
                this.render();
                this.emit('stencilsloaded', shapes);
            }
            return shapes;
        }.bind(this));
    };

    /* Shared context for text measurement outside the render path. */
    Graph.prototype.measureContext = function() {
        if (!this.measureCanvas) this.measureCanvas = document.createElement('canvas');
        return this.measureCanvas.getContext('2d');
    };

    /* Paints the whole scene into a detached canvas, for export and print. */
    Graph.prototype.renderToCanvas = function(scale, margin) {
        scale = scale || 1;
        margin = (margin == null) ? 20 : margin;

        var bounds = this.getAllBounds();
        var painter = new root.PixelScenePainter();
        this.engine.exports.qg_painter_sync_graph(painter.handle);
        painter.refreshLayered();
        painter.playback = this.playback || null;
        painter.mediaPlayback = this.mediaPlayback || null;

        var canvas = document.createElement('canvas');
        painter.render(canvas, {
            zoom: scale, dpr: 1,
            width: Math.ceil((bounds.width + margin * 2) * scale),
            height: Math.ceil((bounds.height + margin * 2) * scale),
            scrollX: (bounds.x - margin) * scale,
            scrollY: (bounds.y - margin) * scale,
            background: this.backgroundColor || '#ffffff',
            grid: false, pageView: false
        });
        painter.destroy();

        return canvas;
    };

    Graph.prototype.print = function() {
        var canvas = this.renderToCanvas(2);
        var win = window.open('', '_blank');

        if (!win) {
            this.emit('toast', 'Allow pop-ups to print this diagram');
            return;
        }

        win.document.write('<!DOCTYPE html><title>Diagram</title>' +
            '<style>@page{margin:12mm}body{margin:0}img{width:100%}</style>' +
            '<img onload="window.focus();window.print()" src="' + canvas.toDataURL('image/png') + '">');
        win.document.close();
    };

    /* Exports the whole diagram at 2x, not just the visible viewport. */
    Graph.prototype.exportPng = function(filename) {
        this.renderToCanvas(2).toBlob(function(blob) {
            if (!blob) return;
            var link = document.createElement('a');
            link.href = URL.createObjectURL(blob);
            link.download = filename || 'pixel-diagram.png';
            link.click();
            setTimeout(function() { URL.revokeObjectURL(link.href); }, 1000);
        }, 'image/png');
    };

    Graph.prototype.saveLocal = function() {
        localStorage.setItem('pixel-graph-document', this.toJSON());
        this.emit('toast', 'Saved in this browser');
    };

    Graph.prototype.loadLocal = function() {
        var data = localStorage.getItem('pixel-graph-document');
        if (data) this.fromJSON(data);
        else this.emit('toast', 'No saved diagram found');
    };

    Graph.prototype.destroy = function() {
        this.destroyed = true;
        clearTimeout(this.dragAutoScrollTimer);
        if (this.animationTimer != null) {
            if (this.animationUsesFrames) cancelAnimationFrame(this.animationTimer);
            else clearTimeout(this.animationTimer);
        }
        if (this.parallaxPointerFrame != null && typeof cancelAnimationFrame === 'function') {
            cancelAnimationFrame(this.parallaxPointerFrame);
            this.parallaxPointerFrame = null;
        }
        if (this.mediaOverlay != null) this.mediaOverlay.destroy();
        if (this.playback != null) this.playback.destroy();
        if (this.mediaPlayback != null) this.mediaPlayback.destroy();
        if (this.resizeObserver) this.resizeObserver.disconnect();
        if (this.boundWindowResize) window.removeEventListener('resize', this.boundWindowResize);
        if (this.boundParallaxPointerMove) {
            window.removeEventListener('pointermove', this.boundParallaxPointerMove, true);
            this.boundParallaxPointerMove = null;
        }
        if (this.boundDragEnd) {
            window.removeEventListener('dragend', this.boundDragEnd);
            this.boundDragEnd = null;
        }
        this.container.removeEventListener('scroll', this.boundScroll);
        this.renderer.destroy();
        this.container.innerHTML = '';
    };

    root.Graph = Graph;
})(window);
