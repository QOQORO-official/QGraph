/*
 * qweb -- the browser host for the QGraph Nim/WebAssembly application.
 *
 * All application logic (the editor UI, the diagram engine, file formats,
 * media decoding, rendering) is Nim compiled to WebAssembly. This file is the
 * generic host it runs on, in the spirit of bindweb
 * (https://github.com/benagastov/bindweb-nim-WASM-compiler):
 *
 *   - DOM: Nim batches DOM mutations into a byte command buffer that is
 *     executed here on flush; elements are opaque integer handles that Nim
 *     allocates itself, so creating UI never waits on a round trip.
 *   - Reflection: typed get/set/invoke on any handle, for the long tail of
 *     browser APIs (video, iframes, fullscreen, selection, clipboard...).
 *   - Events: listeners registered from Nim; the event is dispatched into the
 *     module synchronously, so Nim decides preventDefault/stopPropagation.
 *   - Canvas: Nim records Canvas2D calls into a float64 list replayed here.
 *   - Timers, animation frames, fetch, files, storage, downloads.
 *   - Workers: every worker runs this same file and the same compiled
 *     module (the application picks each worker's role); messages carry
 *     raw bytes plus transferable objects such as ImageBitmaps.
 *   - Automation: window.<name> proxies whose reads and calls are answered
 *     by the module, for scripts and tests.
 *
 * Nothing in here knows about diagrams.
 */
(function(root) {
    'use strict';

    var isWorker = typeof document === 'undefined';
    var encoder = new TextEncoder();
    var decoder = new TextDecoder('utf-8');
    var sharedDecoder = null;

    var TEXT_ALIGNS = ['start', 'end', 'left', 'right', 'center'];
    var BASELINES = ['top', 'hanging', 'middle', 'alphabetic', 'ideographic', 'bottom'];
    var LINE_CAPS = ['butt', 'round', 'square'];
    var LINE_JOINS = ['round', 'bevel', 'miter'];
    var REPEATS = ['repeat', 'repeat-x', 'repeat-y', 'no-repeat'];

    var MATH1 = [Math.sin, Math.cos, Math.tan, Math.atan, Math.asin, Math.acos, Math.exp,
        Math.log, Math.log10, Math.log2, Math.cbrt, Math.sinh, Math.cosh, Math.tanh];
    var MATH2 = [Math.atan2, Math.pow, Math.hypot, function(a, b) { return a % b; }];

    function Host(options) {
        options = options || {};
        this.options = options;
        this.exports = null;
        this.memory = null;
        this.strings = [];
        // Handles: Nim allocates ids from 1 << 24 upwards for the nodes it
        // creates; ids below that are handed out here for objects the page
        // produces (event targets, query results, files, bitmaps...).
        this.handles = new Map();
        this.nextHandle = 64;
        this.listeners = new Map();
        this.currentEvent = null;
        this.eventStack = [];
        this.timers = new Map();
        this.frames = new Map();
        this.patterns = new WeakMap();
        this.measureContext = null;
        this.measureFont = null;
        this.workers = new Map();
        this.reply = '';
        this.replyBytes = null;
        this.threadId = options.threadId || 0;
        this.workerId = options.workerId || 0;
        this.shared = false;
        this.presenters = new Map();
        this.initGlobals();
    }

    Host.prototype.initGlobals = function() {
        var g = typeof self !== 'undefined' ? self : root;
        this.handles.set(1, g);
        if (!isWorker) {
            this.handles.set(2, document);
            this.handles.set(3, document.body);
            this.handles.set(4, document.head);
            this.handles.set(5, document.documentElement);
        }
        try { this.handles.set(6, g.localStorage || null); } catch (error) { this.handles.set(6, null); }
        this.handles.set(7, g.navigator || null);
        this.handles.set(8, g.location || null);
        this.handles.set(9, g.console || null);
        this.handles.set(10, g.performance || null);
    };

    /* ------------------------------------------------------------------ */
    /* Memory helpers                                                      */
    /* ------------------------------------------------------------------ */

    Host.prototype.u8 = function() { return new Uint8Array(this.memory.buffer); };

    Host.prototype.decode = function(ptr, len) {
        if (!len) return '';
        var view = new Uint8Array(this.memory.buffer, ptr, len);
        if (this.shared) {
            // TextDecoder refuses views of a SharedArrayBuffer.
            return decoder.decode(view.slice());
        }
        return decoder.decode(view);
    };

    /* Copies bytes into a fresh engine allocation; returns the pointer. */
    Host.prototype.alloc = function(bytes) {
        var ptr = this.exports.qw_alloc(bytes.length);
        if (bytes.length) new Uint8Array(this.memory.buffer, ptr, bytes.length).set(bytes);
        return ptr;
    };

    Host.prototype.setReply = function(text) {
        this.replyBytes = encoder.encode(text == null ? '' : String(text));
        return this.replyBytes.length;
    };

    Host.prototype.setReplyBytes = function(bytes) {
        this.replyBytes = bytes;
        return bytes.length;
    };

    Host.prototype.handle = function(value) {
        if (value == null) return 0;
        if (typeof value === 'object' || typeof value === 'function') {
            var existing = value.__qh;
            if (existing && this.handles.get(existing) === value) return existing;
            var id = this.nextHandle++;
            while (this.handles.has(id)) id = this.nextHandle++;
            if (this.nextHandle >= 16777216) this.nextHandle = 64;
            this.handles.set(id, value);
            try { value.__qh = id; } catch (error) { /* frozen */ }
            return id;
        }
        return 0;
    };

    Host.prototype.obj = function(h) { return h === 0 ? null : this.handles.get(h); };

    Host.prototype.bind = function(h, value) {
        this.handles.set(h, value);
        if (value != null && (typeof value === 'object')) {
            try { value.__qh = h; } catch (error) { /* frozen */ }
        }
    };

    Host.prototype.release = function(h) {
        var value = this.handles.get(h);
        if (value != null && value.__qh === h) {
            try { delete value.__qh; } catch (error) { /* frozen */ }
        }
        this.handles.delete(h);
    };

    /* Removes an element and forgets every handle and listener inside it. */
    Host.prototype.dropTree = function(h) {
        this.dropNode(this.obj(h));
    };

    Host.prototype.dropNode = function(node) {
        if (node == null) return;
        if (node.parentNode) node.parentNode.removeChild(node);
        var released = [];
        var self = this;
        function forget(n) {
            if (n.__qh) { self.handles.delete(n.__qh); delete n.__qh; }
            if (n.__ql) {
                n.__ql.forEach(function(id) {
                    var entry = self.listeners.get(id);
                    if (entry) {
                        entry.target.removeEventListener(entry.type, entry.fn, entry.capture);
                        self.listeners.delete(id);
                        released.push(id);
                    }
                });
                delete n.__ql;
            }
            for (var c = n.firstChild; c; c = c.nextSibling) forget(c);
        }
        forget(node);
        if (released.length && this.exports.qw_listeners_released) {
            var ptr = this.exports.qw_alloc(released.length * 4);
            new Int32Array(this.memory.buffer, ptr, released.length).set(released);
            this.exports.qw_listeners_released(ptr, released.length);
        }
    };

    /* ------------------------------------------------------------------ */
    /* Values                                                              */
    /* ------------------------------------------------------------------ */

    // Tagged values used by reflection calls, in the same byte layout as the
    // command buffer: 0 undefined, 1 null, 2 number, 3 string, 4 bool,
    // 5 handle, 6 bytes (Uint8Array copy).
    Host.prototype.readValue = function(view, p) {
        var tag = view.getInt32(p, true);
        p += 4;
        switch (tag) {
            case 0: return [undefined, p];
            case 1: return [null, p];
            case 2: return [view.getFloat64(p, true), p + 8];
            case 3: {
                var len = view.getInt32(p, true);
                var s = this.decode(view.byteOffset + p + 4, len);
                return [s, p + 4 + ((len + 3) & ~3)];
            }
            case 4: return [view.getInt32(p, true) !== 0, p + 4];
            case 5: return [this.obj(view.getInt32(p, true)), p + 4];
            case 6: {
                var n = view.getInt32(p, true);
                var bytes = new Uint8Array(this.memory.buffer, view.byteOffset + p + 4, n).slice();
                return [bytes, p + 4 + ((n + 3) & ~3)];
            }
            case 7: {
                // A JSON literal: option bags such as { preventScroll: true }.
                var jlen = view.getInt32(p, true);
                var json = this.decode(view.byteOffset + p + 4, jlen);
                return [JSON.parse(json), p + 4 + ((jlen + 3) & ~3)];
            }
            default: throw new Error('qweb: bad value tag ' + tag);
        }
    };

    // Stores a result for the engine to read back; returns its tag.
    Host.prototype.storeResult = function(value) {
        if (value === undefined) return 0;
        if (value === null) return 1;
        if (typeof value === 'number') { this.resultNumber = value; return 2; }
        if (typeof value === 'string') { this.setReply(value); return 3; }
        if (typeof value === 'boolean') { this.resultNumber = value ? 1 : 0; return 4; }
        if (typeof value === 'bigint') { this.resultNumber = Number(value); return 2; }
        if (value instanceof ArrayBuffer) { this.setReplyBytes(new Uint8Array(value)); return 6; }
        if (ArrayBuffer.isView(value)) {
            this.setReplyBytes(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
            return 6;
        }
        this.resultNumber = this.handle(value);
        return 5;
    };

    /* ------------------------------------------------------------------ */
    /* DOM command buffer                                                  */
    /* ------------------------------------------------------------------ */

    Host.prototype.flush = function(ptr, len) {
        if (!len) return;
        var view = new DataView(this.memory.buffer, ptr, len);
        var p = 0;
        var self = this;
        function i32() { var v = view.getInt32(p, true); p += 4; return v; }
        function f64() { var v = view.getFloat64(p, true); p += 8; return v; }
        function str() {
            var n = view.getInt32(p, true);
            var s = self.decode(ptr + p + 4, n);
            p += 4 + ((n + 3) & ~3);
            return s;
        }
        function sid() { return self.strings[i32()]; }
        function val() { var r = self.readValue(view, p); p = r[1]; return r[0]; }

        while (p < len) {
            var op = i32();
            var h, node, name, value;
            switch (op) {
                case 1: h = i32(); this.bind(h, document.createElement(sid())); break;
                case 2: h = i32(); name = sid(); this.bind(h, document.createElementNS(name, sid())); break;
                case 3: h = i32(); this.bind(h, document.createTextNode(str())); break;
                case 4: h = i32(); node = this.obj(i32()); if (node) this.obj(h).appendChild(node); break;
                case 5: {
                    var parent = this.obj(i32());
                    node = this.obj(i32());
                    var ref = this.obj(i32());
                    if (parent && node) parent.insertBefore(node, ref || null);
                    break;
                }
                case 6: node = this.obj(i32()); if (node && node.parentNode) node.parentNode.removeChild(node); break;
                case 7: node = this.obj(i32()); name = sid(); value = str(); if (node) node.setAttribute(name, value); break;
                case 8: node = this.obj(i32()); name = sid(); if (node) node.removeAttribute(name); break;
                case 9: node = this.obj(i32()); name = sid(); value = val(); if (node) node[name] = value; break;
                case 10: node = this.obj(i32()); name = sid(); value = str(); if (node) node.style[name] = value; break;
                case 11: node = this.obj(i32()); name = sid(); if (node) node.classList.add(name); break;
                case 12: node = this.obj(i32()); name = sid(); if (node) node.classList.remove(name); break;
                case 13: node = this.obj(i32()); name = sid(); value = i32(); if (node) node.classList.toggle(name, value !== 0); break;
                case 14: {
                    h = i32();
                    var type = sid();
                    var id = i32();
                    var flags = i32();
                    this.listen(h, type, id, flags);
                    break;
                }
                case 15: this.unlisten(i32()); break;
                case 16: {
                    node = this.obj(i32());
                    name = sid();
                    var argc = i32();
                    var args = [];
                    for (var a = 0; a < argc; a++) args.push(val());
                    if (node && typeof node[name] === 'function') {
                        try {
                            var r = node[name].apply(node, args);
                            if (r && typeof r.catch === 'function') r.catch(function() {});
                        } catch (error) { /* a failed void call is not fatal */ }
                    }
                    break;
                }
                case 17: this.release(i32()); break;
                case 18: this.dropTree(i32()); break;
                case 19: node = this.obj(i32()); value = str(); if (node) node.textContent = value; break;
                case 20: node = this.obj(i32()); value = str(); if (node) node.innerHTML = value; break;
                case 21: node = this.obj(i32()); name = sid(); value = i32(); if (node) node.hidden = value !== 0; void name; break;
                case 22: node = this.obj(i32()); value = str(); if (node) node.className = value; break;
                case 23: node = this.obj(i32()); name = sid(); value = str(); if (node) node.dataset[name] = value; break;
                case 24: node = this.obj(i32()); name = sid(); if (node) delete node.dataset[name]; break;
                case 25: node = this.obj(i32()); value = str(); if (node) node.style.cssText = value; break;
                case 26: {
                    // Set a property on a property: node[a][b] = value.
                    node = this.obj(i32());
                    name = sid();
                    var inner = sid();
                    value = val();
                    if (node && node[name] != null) node[name][inner] = value;
                    break;
                }
                case 27: this.bind(i32(), this.obj(i32())); break;
                case 28: {
                    // Empty an element, forgetting every handle and listener inside.
                    node = this.obj(i32());
                    while (node && node.firstChild) this.dropNode(node.firstChild);
                    break;
                }
                default:
                    throw new Error('qweb: unknown DOM op ' + op + ' at ' + (p - 4));
            }
        }
    };

    Host.prototype.listen = function(h, type, id, flags) {
        var target = this.obj(h);
        if (target == null) return;
        var self = this;
        var capture = (flags & 1) !== 0;
        var fn = function(event) { self.dispatch(id, event); };
        var options = { capture: capture, passive: (flags & 2) !== 0, once: (flags & 4) !== 0 };
        target.addEventListener(type, fn, options);
        this.listeners.set(id, { target: target, type: type, fn: fn, capture: capture });
        if (!target.__ql) {
            try { target.__ql = []; } catch (error) { /* window */ }
        }
        if (target.__ql) target.__ql.push(id);
    };

    Host.prototype.unlisten = function(id) {
        var entry = this.listeners.get(id);
        if (!entry) return;
        entry.target.removeEventListener(entry.type, entry.fn, entry.capture);
        this.listeners.delete(id);
        if (entry.target.__ql) {
            var index = entry.target.__ql.indexOf(id);
            if (index >= 0) entry.target.__ql.splice(index, 1);
        }
    };

    Host.prototype.dispatch = function(id, event) {
        this.eventStack.push(this.currentEvent);
        this.currentEvent = event;
        try {
            this.exports.qw_event(id);
        } finally {
            this.currentEvent = this.eventStack.pop();
        }
    };

    /* ------------------------------------------------------------------ */
    /* Canvas command replay                                               */
    /* ------------------------------------------------------------------ */

    Host.prototype.replay = function(ctx, ptr, len) {
        if (!ctx || !len) return;
        var b = new Float64Array(this.memory.buffer, ptr, len);
        var s = this.strings;
        var gradients = [];
        var i = 0;
        while (i < len) {
            switch (b[i]) {
                case 0: return;
                case 1: ctx.save(); i += 1; break;
                case 2: ctx.restore(); i += 1; break;
                case 3: ctx.beginPath(); i += 1; break;
                case 4: ctx.moveTo(b[i + 1], b[i + 2]); i += 3; break;
                case 5: ctx.lineTo(b[i + 1], b[i + 2]); i += 3; break;
                case 6: ctx.quadraticCurveTo(b[i + 1], b[i + 2], b[i + 3], b[i + 4]); i += 5; break;
                case 7: ctx.bezierCurveTo(b[i + 1], b[i + 2], b[i + 3], b[i + 4], b[i + 5], b[i + 6]); i += 7; break;
                case 8: ctx.arc(b[i + 1], b[i + 2], b[i + 3], b[i + 4], b[i + 5], b[i + 6] === 1); i += 7; break;
                case 9: ctx.ellipse(b[i + 1], b[i + 2], b[i + 3], b[i + 4], b[i + 5], b[i + 6], b[i + 7], b[i + 8] === 1); i += 9; break;
                case 10: ctx.rect(b[i + 1], b[i + 2], b[i + 3], b[i + 4]); i += 5; break;
                case 11:
                    if (typeof ctx.roundRect === 'function') ctx.roundRect(b[i + 1], b[i + 2], b[i + 3], b[i + 4], b[i + 5]);
                    else ctx.rect(b[i + 1], b[i + 2], b[i + 3], b[i + 4]);
                    i += 6;
                    break;
                case 12: ctx.closePath(); i += 1; break;
                case 13: ctx.fill(); i += 1; break;
                case 14: ctx.stroke(); i += 1; break;
                case 15: ctx.clip(); i += 1; break;
                case 16: ctx.fillRect(b[i + 1], b[i + 2], b[i + 3], b[i + 4]); i += 5; break;
                case 17: ctx.strokeRect(b[i + 1], b[i + 2], b[i + 3], b[i + 4]); i += 5; break;
                case 18: ctx.clearRect(b[i + 1], b[i + 2], b[i + 3], b[i + 4]); i += 5; break;
                case 19: ctx.fillText(s[b[i + 1]], b[i + 2], b[i + 3]); i += 4; break;
                case 20: ctx.fillStyle = s[b[i + 1]]; i += 2; break;
                case 21: ctx.strokeStyle = s[b[i + 1]]; i += 2; break;
                case 22: if (gradients[b[i + 1]]) ctx.fillStyle = gradients[b[i + 1]]; i += 2; break;
                case 23: if (gradients[b[i + 1]]) ctx.strokeStyle = gradients[b[i + 1]]; i += 2; break;
                case 24: ctx.lineWidth = b[i + 1]; i += 2; break;
                case 25: ctx.font = s[b[i + 1]]; i += 2; break;
                case 26: ctx.textAlign = TEXT_ALIGNS[b[i + 1]]; i += 2; break;
                case 27: ctx.textBaseline = BASELINES[b[i + 1]]; i += 2; break;
                case 28: ctx.globalAlpha = b[i + 1]; i += 2; break;
                case 29: ctx.lineCap = LINE_CAPS[b[i + 1]]; i += 2; break;
                case 30: ctx.lineJoin = LINE_JOINS[b[i + 1]]; i += 2; break;
                case 31: ctx.miterLimit = b[i + 1]; i += 2; break;
                case 32: {
                    var n = b[i + 1];
                    var dash = new Array(n);
                    for (var d = 0; d < n; d++) dash[d] = b[i + 2 + d];
                    ctx.setLineDash(dash);
                    i += 2 + n;
                    break;
                }
                case 33: ctx.translate(b[i + 1], b[i + 2]); i += 3; break;
                case 34: ctx.rotate(b[i + 1]); i += 2; break;
                case 35: ctx.scale(b[i + 1], b[i + 2]); i += 3; break;
                case 36: ctx.setTransform(b[i + 1], b[i + 2], b[i + 3], b[i + 4], b[i + 5], b[i + 6]); i += 7; break;
                case 37: ctx.shadowColor = s[b[i + 1]]; i += 2; break;
                case 38: ctx.shadowBlur = b[i + 1]; i += 2; break;
                case 39: ctx.shadowOffsetX = b[i + 1]; i += 2; break;
                case 40: ctx.shadowOffsetY = b[i + 1]; i += 2; break;
                case 41: gradients[b[i + 1]] = ctx.createLinearGradient(b[i + 2], b[i + 3], b[i + 4], b[i + 5]); i += 6; break;
                case 42: gradients[b[i + 1]] = ctx.createRadialGradient(b[i + 2], b[i + 3], b[i + 4], b[i + 5], b[i + 6], b[i + 7]); i += 8; break;
                case 43:
                    try { gradients[b[i + 1]].addColorStop(b[i + 2], s[b[i + 3]]); } catch (error) { /* invalid colour */ }
                    i += 4;
                    break;
                case 45: {
                    var image = this.obj(b[i + 1]);
                    if (image) {
                        try { ctx.drawImage(image, b[i + 2], b[i + 3], b[i + 4], b[i + 5]); } catch (error) { /* not decodable yet */ }
                    }
                    i += 6;
                    break;
                }
                case 46: {
                    var source = this.obj(b[i + 1]);
                    if (source) {
                        try {
                            ctx.drawImage(source, b[i + 2], b[i + 3], b[i + 4], b[i + 5],
                                b[i + 6], b[i + 7], b[i + 8], b[i + 9]);
                        } catch (error) { /* not decodable yet */ }
                    }
                    i += 10;
                    break;
                }
                case 47: {
                    // fillStyle = createPattern(source, repetition); flags 1
                    // on the next word when no pattern could be made.
                    var patternSource = this.obj(b[i + 1]);
                    var pattern = null;
                    try { pattern = patternSource ? ctx.createPattern(patternSource, REPEATS[b[i + 2]] || 'repeat') : null; }
                    catch (error) { pattern = null; }
                    if (pattern) ctx.fillStyle = pattern;
                    i += 3;
                    break;
                }
                default:
                    throw new Error('qweb: unknown canvas op ' + b[i] + ' at ' + i);
            }
        }
    };

    Host.prototype.measure = function(fontId, text) {
        if (this.measureContext == null) {
            if (typeof OffscreenCanvas !== 'undefined') {
                try { this.measureContext = new OffscreenCanvas(1, 1).getContext('2d'); } catch (error) { /* fall through */ }
            }
            if (this.measureContext == null && !isWorker) {
                this.measureContext = document.createElement('canvas').getContext('2d');
            }
            if (this.measureContext == null) return text.length * 7;
        }
        var ctx = this.measureContext;
        var font = this.strings[fontId];
        if (this.measureFont !== font) {
            ctx.font = font;
            this.measureFont = font;
        }
        return ctx.measureText(text).width;
    };

    /* ------------------------------------------------------------------ */
    /* Presentation (worker frame -> visible canvas)                       */
    /* ------------------------------------------------------------------ */

    function WebGLPresenter(canvas) {
        var options = { alpha: false, antialias: false, depth: false, stencil: false,
            premultipliedAlpha: true, preserveDrawingBuffer: false };
        this.canvas = canvas;
        this.gl = canvas.getContext('webgl2', options);
        this.isWebGL2 = this.gl != null;
        if (this.gl == null) this.gl = canvas.getContext('webgl', options);
        if (this.gl == null) throw new Error('WebGL is unavailable');
        this.name = this.isWebGL2 ? 'webgl2' : 'webgl';
        var gl = this.gl;
        var vs = this.isWebGL2 ?
            '#version 300 es\nin vec2 a;out vec2 uv;void main(){gl_Position=vec4(a,0,1);uv=vec2((a.x+1.0)*.5,(1.0-a.y)*.5);}' :
            'attribute vec2 a;varying vec2 uv;void main(){gl_Position=vec4(a,0,1);uv=vec2((a.x+1.0)*.5,(1.0-a.y)*.5);}';
        var fs = this.isWebGL2 ?
            '#version 300 es\nprecision mediump float;in vec2 uv;uniform sampler2D image;out vec4 color;void main(){color=texture(image,uv);}' :
            'precision mediump float;varying vec2 uv;uniform sampler2D image;void main(){gl_FragColor=texture2D(image,uv);}';
        function compile(type, source) {
            var shader = gl.createShader(type);
            gl.shaderSource(shader, source);
            gl.compileShader(shader);
            if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
            return shader;
        }
        var program = gl.createProgram();
        gl.attachShader(program, compile(gl.VERTEX_SHADER, vs));
        gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fs));
        gl.linkProgram(program);
        if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
        this.program = program;
        this.buffer = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), gl.STATIC_DRAW);
        var position = gl.getAttribLocation(program, 'a');
        gl.enableVertexAttribArray(position);
        gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
        this.texture = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, this.texture);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.useProgram(program);
        gl.uniform1i(gl.getUniformLocation(program, 'image'), 0);
    }

    WebGLPresenter.prototype.present = function(source) {
        var gl = this.gl;
        if (this.canvas.width !== source.width) this.canvas.width = source.width;
        if (this.canvas.height !== source.height) this.canvas.height = source.height;
        gl.viewport(0, 0, this.canvas.width, this.canvas.height);
        gl.clearColor(1, 1, 1, 1);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, this.texture);
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source);
        gl.useProgram(this.program);
        gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
    };

    function Canvas2DPresenter(canvas) {
        this.canvas = canvas;
        this.context = canvas.getContext('2d', { alpha: false, desynchronized: true });
        this.name = 'canvas2d';
    }

    Canvas2DPresenter.prototype.present = function(source) {
        if (this.canvas.width !== source.width) this.canvas.width = source.width;
        if (this.canvas.height !== source.height) this.canvas.height = source.height;
        this.context.setTransform(1, 0, 0, 1, 0, 0);
        this.context.clearRect(0, 0, this.canvas.width, this.canvas.height);
        this.context.drawImage(source, 0, 0);
    };

    /* ------------------------------------------------------------------ */
    /* Imports                                                             */
    /* ------------------------------------------------------------------ */

    Host.prototype.imports = function(memory) {
        var host = this;
        var env = {
            // Web boot probe only. Desktop packaging renames this import and
            // requires the native host's separate, per-build grant adapter.
            bindweb_js_domain_guard: function(ptr, len) { return ptr === 0 && len === 0 ? 1 : 0; },
            // -- numbers, time, strings, measurement ------------------------
            qg_parse_num: function(ptr, len) { return Number(host.decode(ptr, len)); },
            qg_fmt_num: function(x, dst, cap) {
                var bytes = encoder.encode(String(x));
                var n = Math.min(bytes.length, cap);
                new Uint8Array(host.memory.buffer, dst, n).set(bytes.subarray(0, n));
                return n;
            },
            qg_date_now: function() { return Date.now(); },
            qg_perf_now: function() { return typeof performance !== 'undefined' ? performance.now() : Date.now(); },
            qg_intern: function(id, ptr, len) { host.strings[id] = host.decode(ptr, len); },
            qg_measure: function(fontId, ptr, len) { return host.measure(fontId, host.decode(ptr, len)); },
            qg_math1: function(op, x) { return MATH1[op](x); },
            qg_math2: function(op, a, b) { return MATH2[op](a, b); },
            qg_log: function(ptr, len) { console.log('[qgraph]', host.decode(ptr, len)); },
            qg_host_call: function() { return 0; },
            qg_view_metrics: function(dst) {
                var out = new Float64Array(host.memory.buffer, dst, 5);
                for (var i = 0; i < 5; i++) out[i] = 0;
            },
            qg_set_scroll: function() {},

            // -- reply channel -------------------------------------------
            qw_reply_copy: function(dst) {
                if (host.replyBytes && host.replyBytes.length) {
                    new Uint8Array(host.memory.buffer, dst, host.replyBytes.length).set(host.replyBytes);
                }
                host.replyBytes = null;
            },
            qw_result_number: function() { return host.resultNumber || 0; },
            qw_reply_len: function() { return host.replyBytes ? host.replyBytes.length : 0; },

            // -- DOM -----------------------------------------------------
            qw_flush: function(ptr, len) { host.flush(ptr, len); },
            qw_get: function(h, namePtr, nameLen) {
                var target = host.obj(h);
                if (target == null) return 0;
                return host.storeResult(target[host.decode(namePtr, nameLen)]);
            },
            qw_get2: function(h, aPtr, aLen, bPtr, bLen) {
                var target = host.obj(h);
                if (target == null) return 0;
                var inner = target[host.decode(aPtr, aLen)];
                if (inner == null) return inner === null ? 1 : 0;
                return host.storeResult(inner[host.decode(bPtr, bLen)]);
            },
            qw_invoke: function(h, namePtr, nameLen, argsPtr, argsLen, argc) {
                var target = host.obj(h);
                var name = host.decode(namePtr, nameLen);
                if (target == null || typeof target[name] !== 'function') return 0;
                var view = new DataView(host.memory.buffer, argsPtr, argsLen);
                var args = [];
                var p = 0;
                for (var a = 0; a < argc; a++) {
                    var r = host.readValue(view, p);
                    args.push(r[0]);
                    p = r[1];
                }
                var result;
                try { result = target[name].apply(target, args); }
                catch (error) { host.lastError = String(error && error.message || error); return -1; }
                if (result && typeof result.then === 'function' && typeof result.catch === 'function') {
                    result.catch(function() {});
                }
                return host.storeResult(result);
            },
            qw_construct: function(ctorPtr, ctorLen, argsPtr, argsLen, argc) {
                var g = typeof self !== 'undefined' ? self : root;
                var Ctor = g[host.decode(ctorPtr, ctorLen)];
                if (typeof Ctor !== 'function') return 0;
                var view = new DataView(host.memory.buffer, argsPtr, argsLen);
                var args = [];
                var p = 0;
                for (var a = 0; a < argc; a++) {
                    var r = host.readValue(view, p);
                    args.push(r[0]);
                    p = r[1];
                }
                try { return host.handle(new (Function.prototype.bind.apply(Ctor, [null].concat(args)))()); }
                catch (error) { host.lastError = String(error && error.message || error); return 0; }
            },
            qw_rect: function(h, dst) {
                var node = host.obj(h);
                var out = new Float64Array(host.memory.buffer, dst, 6);
                if (!node || typeof node.getBoundingClientRect !== 'function') {
                    for (var i = 0; i < 6; i++) out[i] = 0;
                    return;
                }
                var r = node.getBoundingClientRect();
                out[0] = r.left; out[1] = r.top; out[2] = r.width; out[3] = r.height;
                out[4] = r.right; out[5] = r.bottom;
            },
            qw_query: function(h, selPtr, selLen) {
                var node = host.obj(h);
                if (!node || typeof node.querySelector !== 'function') return 0;
                return host.handle(node.querySelector(host.decode(selPtr, selLen)));
            },
            qw_query_all: function(h, selPtr, selLen, dst, cap) {
                var node = host.obj(h);
                if (!node || typeof node.querySelectorAll !== 'function') return 0;
                var list = node.querySelectorAll(host.decode(selPtr, selLen));
                var out = new Int32Array(host.memory.buffer, dst, cap);
                var n = Math.min(cap, list.length);
                for (var i = 0; i < n; i++) out[i] = host.handle(list[i]);
                return list.length;
            },
            qw_closest: function(h, selPtr, selLen) {
                var node = host.obj(h);
                if (!node || typeof node.closest !== 'function') return 0;
                return host.handle(node.closest(host.decode(selPtr, selLen)));
            },
            qw_matches: function(h, selPtr, selLen) {
                var node = host.obj(h);
                if (!node || typeof node.matches !== 'function') return 0;
                try { return node.matches(host.decode(selPtr, selLen)) ? 1 : 0; } catch (error) { return 0; }
            },
            qw_contains: function(a, b) {
                var outer = host.obj(a);
                var inner = host.obj(b);
                return outer && inner && typeof outer.contains === 'function' && outer.contains(inner) ? 1 : 0;
            },
            qw_same: function(a, b) { return host.obj(a) === host.obj(b) ? 1 : 0; },
            qw_active_element: function() { return isWorker ? 0 : host.handle(document.activeElement); },
            qw_context: function(canvasHandle, kind, alpha, desynchronized) {
                var canvas = host.obj(canvasHandle);
                if (!canvas) return 0;
                var options = { alpha: alpha !== 0 };
                if (desynchronized) options.desynchronized = true;
                return host.handle(canvas.getContext(kind === 1 ? 'bitmaprenderer' : '2d', options));
            },
            qw_replay: function(ctxHandle, ptr, len) { host.replay(host.obj(ctxHandle), ptr, len); },
            qw_put_rgba: function(ctxHandle, ptr, width, height) {
                var ctx = host.obj(ctxHandle);
                if (!ctx) return;
                var bytes = new Uint8ClampedArray(host.memory.buffer, ptr, width * height * 4).slice();
                ctx.putImageData(new ImageData(bytes, width, height), 0, 0);
            },
            qw_node_text: function(h) {
                // innerText with the textContent fallback, as the label editor reads it.
                var node = host.obj(h);
                if (!node) return host.setReply('');
                var raw = node.innerText;
                if (raw == null) raw = node.textContent;
                return host.setReply(raw || '');
            },
            qw_select_contents: function(h) {
                var node = host.obj(h);
                if (!node || isWorker) return;
                var range = document.createRange();
                range.selectNodeContents(node);
                var selection = window.getSelection();
                selection.removeAllRanges();
                selection.addRange(range);
            },
            qw_exec_command: function(cmdPtr, cmdLen, valuePtr, valueLen, hasValue) {
                try {
                    document.execCommand(host.decode(cmdPtr, cmdLen), false,
                        hasValue ? host.decode(valuePtr, valueLen) : null);
                    return 1;
                } catch (error) { return 0; }
            },
            qw_dom_snapshot: function(htmlPtr, htmlLen, mode) {
                // Parses markup with the browser and returns the tree as JSON
                // ({t, a, s, c, h}), so Nim sees exactly what the DOM sees
                // (entities, implied tags, CSSOM-normalised inline styles).
                var text = host.decode(htmlPtr, htmlLen);
                var rootNode;
                if ((mode & 1) !== 0) {
                    var doc = new DOMParser().parseFromString(text, 'image/svg+xml');
                    if (doc.getElementsByTagName('parsererror').length) {
                        return host.setReply(JSON.stringify({ error: doc.getElementsByTagName('parsererror')[0].textContent }));
                    }
                    rootNode = doc.documentElement;
                } else {
                    rootNode = document.createElement('template');
                    rootNode.innerHTML = text;
                    rootNode = rootNode.content;
                }
                return host.setReply(JSON.stringify(snapshot(rootNode, (mode & 2) !== 0, (mode & 1) !== 0)));
            },

            // -- events --------------------------------------------------
            qw_ev_num: function(field) {
                var e = host.currentEvent;
                if (!e) return 0;
                switch (field) {
                    case 0: return e.clientX || 0;
                    case 1: return e.clientY || 0;
                    case 2: return e.button || 0;
                    case 3: return e.buttons || 0;
                    case 4: return (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.metaKey ? 4 : 0) |
                        (e.altKey ? 8 : 0) | (e.pointerType === 'touch' ? 16 : 0);
                    case 5: return e.deltaX || 0;
                    case 6: return e.deltaY || 0;
                    case 7: return e.pointerId == null ? 0 : e.pointerId;
                    case 8: return e.isPrimary === false ? 0 : 1;
                    case 9: return e.detail || 0;
                    case 10: return e.timeStamp || 0;
                    case 11: return e.deltaMode || 0;
                    case 12: return e.data instanceof ArrayBuffer ? e.data.byteLength : -1;
                    default: return 0;
                }
            },
            qw_ev_str: function(field) {
                var e = host.currentEvent;
                if (!e) return host.setReply('');
                switch (field) {
                    case 0: return host.setReply(e.type);
                    case 1: return host.setReply(e.key || '');
                    case 2: return host.setReply(e.code || '');
                    case 3: return host.setReply(e.pointerType || '');
                    case 4: return host.setReply(typeof e.data === 'string' ? e.data : '');
                    case 5: return host.setReply(e.origin || '');
                    default: return host.setReply('');
                }
            },
            qw_ev_handle: function(field) {
                var e = host.currentEvent;
                if (!e) return 0;
                switch (field) {
                    case 0: return host.handle(e.target);
                    case 1: return host.handle(e.currentTarget);
                    case 2: return host.handle(e.relatedTarget);
                    case 3: return host.handle(e.dataTransfer);
                    case 4: return host.handle(e.source);
                    case 5: return host.handle(e);
                    default: return 0;
                }
            },
            qw_ev_prevent: function() { if (host.currentEvent) host.currentEvent.preventDefault(); },
            qw_ev_stop: function() { if (host.currentEvent) host.currentEvent.stopPropagation(); },

            // -- timers --------------------------------------------------
            qw_timeout: function(id, ms) {
                var t = setTimeout(function() {
                    host.timers.delete(id);
                    host.exports.qw_on_timer(id, typeof performance !== 'undefined' ? performance.now() : Date.now());
                }, ms);
                host.timers.set(id, t);
            },
            qw_clear_timeout: function(id) {
                var t = host.timers.get(id);
                if (t != null) clearTimeout(t);
                host.timers.delete(id);
            },
            qw_raf: function(id) {
                var raf = typeof requestAnimationFrame === 'function' ? requestAnimationFrame :
                    function(fn) { return setTimeout(function() { fn(performance.now()); }, 16); };
                var f = raf(function(now) {
                    host.frames.delete(id);
                    host.exports.qw_on_timer(id, now);
                });
                host.frames.set(id, f);
            },
            qw_cancel_raf: function(id) {
                var f = host.frames.get(id);
                if (f != null) {
                    if (typeof cancelAnimationFrame === 'function') cancelAnimationFrame(f);
                    else clearTimeout(f);
                }
                host.frames.delete(id);
            },

            // -- async I/O -------------------------------------------------
            qw_fetch: function(id, urlPtr, urlLen, mode) {
                var url = host.decode(urlPtr, urlLen);
                fetch(url, mode === 2 ? { cache: 'force-cache' } : undefined).then(function(response) {
                    if (!response.ok && response.status !== 0) throw new Error('HTTP ' + response.status);
                    return mode === 3 ? response.blob() : response.arrayBuffer();
                }).then(function(body) {
                    if (mode === 3) host.complete(id, 0, null, host.handle(body));
                    else host.complete(id, 0, new Uint8Array(body), 0);
                }).catch(function(error) {
                    host.complete(id, 1, encoder.encode(String(error && error.message || error)), 0);
                });
            },
            qw_fetch_post: function(id, urlPtr, urlLen, bodyPtr, bodyLen, ctPtr, ctLen) {
                var url = host.decode(urlPtr, urlLen);
                var body = host.decode(bodyPtr, bodyLen);
                var contentType = host.decode(ctPtr, ctLen);
                fetch(url, { method: 'POST', credentials: 'same-origin',
                    headers: { 'Content-Type': contentType }, body: body }).then(function(response) {
                    return response.arrayBuffer().then(function(buf) {
                        return { ok: response.ok, status: response.status, buf: buf };
                    });
                }).then(function(r) {
                    if (!r.ok) throw new Error('HTTP ' + r.status + ': ' + new TextDecoder().decode(r.buf));
                    host.complete(id, 0, new Uint8Array(r.buf), 0);
                }).catch(function(error) {
                    host.complete(id, 1, encoder.encode(String(error && error.message || error)), 0);
                });
            },
            qw_read_blob: function(id, h, mode) {
                var blob = host.obj(h);
                if (!blob) { host.complete(id, 1, encoder.encode('missing file'), 0); return; }
                var reader = new FileReader();
                reader.onload = function() {
                    var result = reader.result;
                    if (result instanceof ArrayBuffer) host.complete(id, 0, new Uint8Array(result), 0);
                    else host.complete(id, 0, encoder.encode(String(result || '')), 0);
                };
                reader.onerror = function() {
                    host.complete(id, 1, encoder.encode(String(reader.error || 'read failed')), 0);
                };
                if (mode === 1) reader.readAsDataURL(blob);
                else if (mode === 2) reader.readAsArrayBuffer(blob);
                else reader.readAsText(blob);
            },
            qw_blob: function(ptr, len, mimePtr, mimeLen) {
                var bytes = new Uint8Array(host.memory.buffer, ptr, len).slice();
                return host.handle(new Blob([bytes], { type: host.decode(mimePtr, mimeLen) }));
            },
            qw_image_bitmap: function(id, h) {
                var source = host.obj(h);
                if (typeof createImageBitmap !== 'function' || !source) {
                    host.complete(id, 1, null, 0);
                    return;
                }
                createImageBitmap(source).then(function(bitmap) {
                    host.complete(id, 0, null, host.handle(bitmap));
                }).catch(function() { host.complete(id, 1, null, 0); });
            },
            qw_canvas_blob: function(id, h, mimePtr, mimeLen) {
                var canvas = host.obj(h);
                if (!canvas) { host.complete(id, 1, null, 0); return; }
                var mime = host.decode(mimePtr, mimeLen);
                var done = function(blob) {
                    if (blob) host.complete(id, 0, null, host.handle(blob));
                    else host.complete(id, 1, null, 0);
                };
                if (typeof canvas.convertToBlob === 'function') canvas.convertToBlob({ type: mime }).then(done, function() { done(null); });
                else canvas.toBlob(done, mime);
            },
            qw_clipboard_write: function(ptr, len) {
                var text = host.decode(ptr, len);
                if (typeof navigator !== 'undefined' && navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(text).catch(function() {});
                }
            },
            qw_prompt: function(msgPtr, msgLen, defPtr, defLen) {
                var value = prompt(host.decode(msgPtr, msgLen), host.decode(defPtr, defLen));
                if (value == null) return -1;
                return host.setReply(value);
            },
            qw_last_error: function() { return host.setReply(host.lastError || ''); },

            // -- presentation ----------------------------------------------
            qw_presenter: function(canvasHandle, kind) {
                var canvas = host.obj(canvasHandle);
                var presenter = null;
                if (kind !== 1) {
                    try { presenter = new WebGLPresenter(canvas); } catch (error) { presenter = null; }
                }
                if (presenter == null) presenter = new Canvas2DPresenter(canvas);
                return host.handle(presenter);
            },
            qw_present: function(presenterHandle, sourceHandle) {
                var presenter = host.obj(presenterHandle);
                var source = host.obj(sourceHandle);
                if (presenter && source) presenter.present(source);
            },

            // -- workers ---------------------------------------------------
            // -- callbacks and the automation surface --------------------
            qw_callback: function(id) {
                // A plain JS function that dispatches to a Nim listener with
                // its first argument as the event (observers, promises).
                return host.handle(function(arg) { host.dispatch(id, arg); });
            },
            qw_expose: function(ptr, len) {
                var name = host.decode(ptr, len);
                if (!isWorker) root[name] = host.apiProxy(name);
            },
            qw_worker_new: function(kind) { return host.spawnWorker(kind); },
            qw_post: function(target, ptr, len, handlesPtr, handleCount) {
                host.post(target, new Uint8Array(host.memory.buffer, ptr, len).slice(),
                    handleCount ? Array.prototype.slice.call(new Int32Array(host.memory.buffer, handlesPtr, handleCount)) : []);
            },
            qw_thread_spawn: function(fn, arg, stack) { return host.spawnThread(fn, arg, stack); },
            qw_thread_id: function() { return host.threadId; },
            qw_is_worker: function() { return isWorker ? 1 : 0; },
            qw_is_shared: function() { return host.shared ? 1 : 0; },
            qw_cores: function() {
                return typeof navigator !== 'undefined' && navigator.hardwareConcurrency ?
                    navigator.hardwareConcurrency : 2;
            }
        };
        if (memory) env.memory = memory;
        return { env: env };
    };

    /* Browser-parsed tree as plain JSON. Text nodes are strings; comments
       are {m}; elements are {t (tagName), l (localName), a (attributes),
       s (non-empty inline style properties), c (children)}. With `markup`
       set, table cells carry innerHTML (h) and tables outerHTML (o). */
    function snapshot(node, markup, svg) {
        var SVG_PROPS = ['fill', 'stroke', 'stroke-width', 'opacity', 'stroke-dasharray',
            'font-family', 'font-size', 'font-weight', 'font-style', 'text-anchor',
            'marker-start', 'marker-end'];
        var STYLE_PROPS = ['backgroundColor', 'color', 'textAlign', 'fontWeight', 'fontFamily',
            'fontSize', 'fontStyle', 'textDecoration', 'textDecorationLine', 'verticalAlign',
            'opacity', 'whiteSpace', 'padding', 'borderColor', 'borderWidth', 'borderStyle',
            'width', 'height'];
        function walk(n) {
            if (n.nodeType === 3) return n.nodeValue;
            if (n.nodeType === 8) return { m: n.nodeValue };
            if (n.nodeType !== 1 && n.nodeType !== 11) return null;
            var out = { c: [] };
            if (n.nodeType === 1) {
                out.t = n.tagName;
                out.l = n.localName;
                out.a = {};
                for (var i = 0; i < n.attributes.length; i++) out.a[n.attributes[i].name] = n.attributes[i].value;
                if (n.style) {
                    var s = {};
                    var any = false;
                    for (var p = 0; p < STYLE_PROPS.length; p++) {
                        var v = n.style[STYLE_PROPS[p]];
                        if (v) { s[STYLE_PROPS[p]] = v; any = true; }
                    }
                    if (any) out.s = s;
                    if (svg) {
                        var props = {};
                        var anyProp = false;
                        for (var q = 0; q < SVG_PROPS.length; q++) {
                            var pv = n.style.getPropertyValue(SVG_PROPS[q]);
                            if (pv) { props[SVG_PROPS[q]] = pv; anyProp = true; }
                        }
                        if (anyProp) out.p = props;
                    }
                }
                if (markup) {
                    if (n.tagName === 'TD' || n.tagName === 'TH') {
                        out.h = n.innerHTML;
                        out.cs = n.colSpan;
                        out.rs = n.rowSpan;
                    }
                    if (n.tagName === 'TABLE') out.o = n.outerHTML;
                }
                // A <template> keeps its children in .content.
                if (n.tagName === 'TEMPLATE' && n.content) n = n.content;
            }
            for (var c = n.firstChild; c; c = c.nextSibling) {
                var child = walk(c);
                if (child !== null) out.c.push(child);
            }
            return out;
        }
        return walk(node);
    }

    /* Hands the result of an async request to the engine. */
    Host.prototype.complete = function(id, failed, bytes, handle) {
        var ptr = 0;
        var len = 0;
        if (bytes && bytes.length) {
            ptr = this.alloc(bytes);
            len = bytes.length;
        }
        this.exports.qw_on_complete(id, failed, ptr, len, handle || 0);
    };

    /* ------------------------------------------------------------------ */
    /* Automation surface                                                  */
    /* ------------------------------------------------------------------ */

    /* window[name] for scripts and tests: every property read or call is
       answered by the application's qw_api export, so objects that live in
       Nim look like ordinary JS objects. Replies are JSON:
       {t:'f'} function, {t:'o'} nested object, {t:'v', v} value,
       {t:'n', h} page object handle, {e} error. */
    Host.prototype.api = function(path, op, args) {
        var text = JSON.stringify(args || [], function(key, value) {
            if (value === undefined && key !== '') return '\u0001undefined';
            return value;
        });
        var pathBytes = encoder.encode(path);
        var argBytes = encoder.encode(text);
        var pp = this.alloc(pathBytes);
        var ap = this.alloc(argBytes);
        var n = this.exports.qw_api(pp, pathBytes.length, op, ap, argBytes.length);
        var reply = JSON.parse(this.decode(this.exports.qw_api_ptr(), n) || '{}');
        if (reply.e) throw new Error(reply.e);
        if (reply.t === 'f') {
            var host = this;
            return function() { return host.api(path, 1, Array.prototype.slice.call(arguments)); };
        }
        if (reply.t === 'o') return this.apiProxy(path);
        if (reply.t === 'n') return this.obj(reply.h);
        return reply.v;
    };

    Host.prototype.apiProxy = function(path) {
        var host = this;
        return new Proxy({}, {
            get: function(target, prop) {
                if (typeof prop !== 'string' || prop === 'then') return undefined;
                return host.api(path + '.' + prop, 0, null);
            },
            set: function(target, prop, value) {
                host.api(path + '.' + String(prop), 2, [value]);
                return true;
            }
        });
    };

    /* ------------------------------------------------------------------ */
    /* Workers and threads                                                 */
    /* ------------------------------------------------------------------ */

    Host.prototype.scriptUrl = function() {
        return this.options.scriptUrl || (Host.base + 'qweb.js' + Host.version);
    };

    Host.prototype.spawnWorker = function(kind) {
        if (typeof Worker === 'undefined') return 0;
        var id = this.handle({});
        var worker;
        try { worker = new Worker(this.scriptUrl()); }
        catch (error) { this.handles.delete(id); return 0; }
        var host = this;
        worker.onmessage = function(event) { host.receive(id, event.data); };
        worker.onerror = function(event) {
            if (event && event.preventDefault) event.preventDefault();
            host.receive(id, { error: String(event && event.message || 'worker failed') });
        };
        this.workers.set(id, worker);
        this.handles.set(id, worker);
        worker.postMessage({
            qweb: 'boot', kind: kind, workerId: id, wasmUrl: this.wasmUrl,
            module: this.module, memory: null, base: Host.base, version: Host.version
        });
        return id;
    };

    Host.prototype.post = function(target, bytes, handles) {
        var transfer = [bytes.buffer];
        var objects = [];
        for (var i = 0; i < handles.length; i++) {
            var value = this.obj(handles[i]);
            objects.push(value);
            if (value && (value instanceof ArrayBuffer ||
                (typeof ImageBitmap !== 'undefined' && value instanceof ImageBitmap) ||
                (typeof OffscreenCanvas !== 'undefined' && value instanceof OffscreenCanvas) ||
                (typeof MessagePort !== 'undefined' && value instanceof MessagePort))) transfer.push(value);
        }
        var message = { qweb: 'msg', bytes: bytes, objects: objects };
        if (target === 0) {
            // To the page from inside a worker.
            self.postMessage(message, transfer);
            return;
        }
        var worker = this.workers.get(target);
        if (worker) worker.postMessage(message, transfer);
    };

    Host.prototype.receive = function(from, data) {
        if (!data) return;
        if (data.error) {
            this.exports.qw_on_worker_error(from);
            return;
        }
        var bytes = data.bytes || new Uint8Array(0);
        var handles = (data.objects || []).map(this.handle, this);
        var ptr = this.alloc(bytes);
        var hptr = 0;
        if (handles.length) {
            hptr = this.exports.qw_alloc(handles.length * 4);
            new Int32Array(this.memory.buffer, hptr, handles.length).set(handles);
        }
        this.exports.qw_on_message(from, ptr, bytes.length, hptr, handles.length);
    };

    /* Threads share the page's memory: each runs the same module in its own
       worker, on its own stack, and calls back into the table entry `fn`. */
    Host.prototype.spawnThread = function(fn, arg, stack) {
        if (!this.shared || typeof Worker === 'undefined') return 0;
        var id = this.handle({});
        var worker;
        try { worker = new Worker(this.scriptUrl()); }
        catch (error) { this.handles.delete(id); return 0; }
        var host = this;
        worker.onmessage = function(event) { host.receive(id, event.data); };
        worker.onerror = function(event) {
            if (event && event.preventDefault) event.preventDefault();
            host.receive(id, { error: String(event && event.message || 'thread failed') });
        };
        this.workers.set(id, worker);
        this.handles.set(id, worker);
        worker.postMessage({
            qweb: 'thread', workerId: id, module: this.module, memory: this.memory,
            fn: fn, arg: arg, stack: stack, base: Host.base, version: Host.version
        });
        return id;
    };

    /* ------------------------------------------------------------------ */
    /* Loading                                                             */
    /* ------------------------------------------------------------------ */

    Host.prototype.instantiate = function(module, memory) {
        var host = this;
        this.module = module;
        return WebAssembly.instantiate(module, this.imports(memory)).then(function(instance) {
            host.instance = instance;
            host.exports = instance.exports;
            host.memory = memory || instance.exports.memory;
            host.shared = typeof SharedArrayBuffer !== 'undefined' &&
                host.memory.buffer instanceof SharedArrayBuffer;
            return host;
        });
    };

    function scriptBase() {
        if (!isWorker && document.currentScript && document.currentScript.src) {
            return document.currentScript.src.replace(/[^/]*$/, '');
        }
        if (typeof location !== 'undefined') return String(location.href).replace(/[^/]*$/, '');
        return '';
    }

    function versionQuery() {
        var src = (!isWorker && document.currentScript && document.currentScript.src) ||
            (typeof location !== 'undefined' ? String(location.href) : '');
        var match = /[?&]v=([A-Za-z0-9._-]+)/.exec(src);
        return match ? '?v=' + match[1] : '';
    }

    Host.base = scriptBase();
    Host.version = versionQuery();

    Host.wasmUrl = function() {
        return Host.base + 'qgraph.wasm' + Host.version;
    };

    function compile(url) {
        return fetch(url).then(function(response) {
            if (!response.ok) throw new Error(url + ': HTTP ' + response.status);
            if (typeof WebAssembly.compileStreaming === 'function') {
                return WebAssembly.compileStreaming(response).catch(function() {
                    return fetch(url).then(function(r) { return r.arrayBuffer(); }).then(WebAssembly.compile);
                });
            }
            return response.arrayBuffer().then(WebAssembly.compile);
        });
    }

    function sharedMemoryFor(module) {
        // The threaded module imports its memory; its limits come from the
        // import descriptor.
        var imports = WebAssembly.Module.imports(module);
        for (var i = 0; i < imports.length; i++) {
            if (imports[i].kind === 'memory') {
                return new WebAssembly.Memory({ initial: 256, maximum: 32768, shared: true });
            }
        }
        return null;
    }

    /* Page entry: load the module and run the application's main. */
    function start() {
        var url = Host.wasmUrl();
        return compile(url).then(function(module) {
            var host = new Host({});
            host.wasmUrl = url;
            var memory = sharedMemoryFor(module);
            return host.instantiate(module, memory);
        }).then(function(host) {
            root.QWeb.host = host;
            if (host.exports.qw_init_memory) host.exports.qw_init_memory();
            host.exports.qw_main();
            return host;
        });
    }

    /* Worker entry: the page sends a boot (fresh instance, own memory) or a
       thread (shared memory, run one function) message. */
    function workerMain() {
        var host = null;
        var queue = [];
        self.onmessage = function(event) {
            var data = event.data || {};
            if (data.qweb === 'boot') {
                Host.base = data.base || Host.base;
                Host.version = data.version || '';
                host = new Host({ workerId: data.workerId });
                var modulePromise = data.module ? Promise.resolve(data.module) : compile(data.wasmUrl);
                modulePromise.then(function(module) {
                    return host.instantiate(module, sharedMemoryFor(module));
                }).then(function() {
                    if (host.exports.qw_init_memory) host.exports.qw_init_memory();
                    host.exports.qw_worker_main(data.kind || 0);
                    var pending = queue;
                    queue = null;
                    pending.forEach(function(message) { host.receive(0, message); });
                }).catch(function(error) {
                    self.postMessage({ error: String(error && error.message || error) });
                });
                return;
            }
            if (data.qweb === 'thread') {
                Host.base = data.base || Host.base;
                Host.version = data.version || '';
                host = new Host({ workerId: data.workerId, threadId: data.workerId });
                host.instantiate(data.module, data.memory).then(function() {
                    host.exports.qw_thread_start(data.stack, data.fn, data.arg);
                }).catch(function(error) {
                    self.postMessage({ error: String(error && error.message || error) });
                });
                queue = null;
                return;
            }
            if (data.qweb === 'msg') {
                if (queue) queue.push(data);
                else if (host) host.receive(0, data);
            }
        };
    }

    root.QWeb = { Host: Host, start: start };

    if (isWorker) workerMain();
    else if (!root.QWEB_MANUAL_START) {
        var boot = function() {
            start().catch(function(error) {
                console.error(error);
                document.body.textContent = 'The application could not be loaded: ' + error.message;
            });
        };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
        else boot();
    }
})(typeof self !== 'undefined' ? self : this);
