/*
 * Loader and host bridge for the QGraph engine (qgraph.wasm).
 *
 * The diagram engine and painter are written in Nim and compiled to a
 * freestanding WebAssembly module. This file provides everything the module
 * imports from the page -- JavaScript math, number formatting, canvas text
 * measurement, a string table, and the host-call channel the Graph facade
 * answers -- and replays the Canvas2D command lists the painter produces.
 *
 * Works on the page and inside the render worker.
 */
(function(root) {
    'use strict';

    var OP = {
        END: 0, SAVE: 1, RESTORE: 2, BEGIN_PATH: 3, MOVE_TO: 4, LINE_TO: 5, QUAD: 6,
        BEZIER: 7, ARC: 8, ELLIPSE: 9, RECT: 10, ROUND_RECT: 11, CLOSE_PATH: 12, FILL: 13,
        STROKE: 14, CLIP: 15, FILL_RECT: 16, STROKE_RECT: 17, CLEAR_RECT: 18, FILL_TEXT: 19,
        FILL_STYLE: 20, STROKE_STYLE: 21, FILL_GRAD: 22, STROKE_GRAD: 23, LINE_WIDTH: 24,
        FONT: 25, TEXT_ALIGN: 26, TEXT_BASELINE: 27, GLOBAL_ALPHA: 28, LINE_CAP: 29,
        LINE_JOIN: 30, MITER_LIMIT: 31, LINE_DASH: 32, TRANSLATE: 33, ROTATE: 34, SCALE: 35,
        SET_TRANSFORM: 36, SHADOW_COLOR: 37, SHADOW_BLUR: 38, SHADOW_OFFSET_X: 39,
        SHADOW_OFFSET_Y: 40, LINEAR_GRAD: 41, RADIAL_GRAD: 42, COLOR_STOP: 43, MEDIA: 44
    };
    var TEXT_ALIGNS = ['start', 'end', 'left', 'right', 'center'];
    var BASELINES = ['top', 'hanging', 'middle', 'alphabetic', 'ideographic', 'bottom'];
    var LINE_CAPS = ['butt', 'round', 'square'];
    var LINE_JOINS = ['round', 'bevel', 'miter'];

    var MATH1 = [Math.sin, Math.cos, Math.tan, Math.atan, Math.asin, Math.acos, Math.exp,
        Math.log, Math.log10, Math.log2, Math.cbrt, Math.sinh, Math.cosh, Math.tanh];
    var MATH2 = [Math.atan2, Math.pow, Math.hypot, function(a, b) { return a % b; }];

    var encoder = new TextEncoder();
    var decoder = new TextDecoder('utf-8');

    function createMeasureContext() {
        if (typeof OffscreenCanvas !== 'undefined') {
            try { return new OffscreenCanvas(1, 1).getContext('2d'); } catch (error) { /* fall through */ }
        }
        if (typeof document !== 'undefined') return document.createElement('canvas').getContext('2d');
        return null;
    }

    function Engine(instance) {
        this.instance = instance;
        this.exports = instance.exports;
        this.memory = instance.exports.memory;
        this.strings = [];
        this.mediaCache = new Map();
        this.measureContext = null;
        this.measureFont = null;
        this.hostHandlers = Object.create(null);
        this.viewMetrics = null;
        this.setScroll = null;
    }

    Engine.prototype.u8 = function() {
        return new Uint8Array(this.memory.buffer);
    };

    Engine.prototype.decode = function(ptr, len) {
        if (!len) return '';
        return decoder.decode(new Uint8Array(this.memory.buffer, ptr, len));
    };

    /* Writes a string argument into the engine's input buffer. */
    Engine.prototype.input = function(text) {
        var bytes = encoder.encode(text == null ? '' : String(text));
        var ptr = this.exports.qg_input(bytes.length);
        if (bytes.length) new Uint8Array(this.memory.buffer, ptr, bytes.length).set(bytes);
        return bytes.length;
    };

    Engine.prototype.output = function() {
        return this.decode(this.exports.qg_output_ptr(), this.exports.qg_output_len());
    };

    /* call('qg_x', [numbers...], stringArg) -> return value of the export. */
    Engine.prototype.call = function(name, numbers, text) {
        var args = numbers ? numbers.slice() : [];
        if (text !== undefined) args.push(this.input(text));
        return this.exports[name].apply(null, args);
    };

    Engine.prototype.callJson = function(name, numbers, value) {
        return this.call(name, numbers, value === undefined ? undefined : JSON.stringify(value));
    };

    Engine.prototype.callOut = function(name, numbers, text) {
        this.call(name, numbers, text);
        return this.output();
    };

    Engine.prototype.callOutJson = function(name, numbers, text) {
        var out = this.callOut(name, numbers, text);
        return out ? JSON.parse(out) : null;
    };

    Engine.prototype.measure = function(fontId, text) {
        if (this.measureContext == null) this.measureContext = createMeasureContext();
        var ctx = this.measureContext;
        if (ctx == null) return text.length * 7;
        var font = this.strings[fontId];
        if (this.measureFont !== font) {
            ctx.font = font;
            this.measureFont = font;
        }
        return ctx.measureText(text).width;
    };

    /* The object passed as a media op's node: its JSON (interned) with the
       interned source ids swapped back for the source strings. */
    Engine.prototype.mediaNode = function(id) {
        var cached = this.mediaCache.get(id);
        if (cached) return cached;
        var node = JSON.parse(this.strings[id]);
        node.src = node.src >= 0 ? this.strings[node.src] : undefined;
        if (Array.isArray(node.mediaLayers)) {
            for (var i = 0; i < node.mediaLayers.length; i++) {
                var layer = node.mediaLayers[i];
                if (layer) layer.src = layer.src >= 0 ? this.strings[layer.src] : undefined;
            }
        }
        if (this.mediaCache.size > 512) this.mediaCache.clear();
        this.mediaCache.set(id, node);
        return node;
    };

    /* Replays the current command buffer onto a 2D context. `media(ctx, node)`
       paints image/video nodes. */
    Engine.prototype.replay = function(ctx, media) {
        var ptr = this.exports.qg_cmd_ptr();
        var len = this.exports.qg_cmd_len();
        if (!len) return;
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
                case 44:
                    if (media) {
                        var node = this.mediaNode(b[i + 1]);
                        media(ctx, node);
                        // The media painter may call back into the engine
                        // (never while replaying today), so refresh the view.
                        b = new Float64Array(this.memory.buffer, ptr, len);
                    }
                    i += 2;
                    break;
                default:
                    throw new Error('QGraph: unknown canvas op ' + b[i] + ' at ' + i);
            }
        }
    };

    function imports(engine) {
        var env = {
            qg_parse_num: function(ptr, len) {
                return Number(engine.decode(ptr, len));
            },
            qg_fmt_num: function(x, dst, cap) {
                var text = String(x);
                var bytes = encoder.encode(text);
                var n = Math.min(bytes.length, cap);
                new Uint8Array(engine.memory.buffer, dst, n).set(bytes.subarray(0, n));
                return n;
            },
            qg_date_now: function() { return Date.now(); },
            qg_perf_now: function() {
                return typeof performance !== 'undefined' ? performance.now() : Date.now();
            },
            qg_intern: function(id, ptr, len) {
                engine.strings[id] = engine.decode(ptr, len);
            },
            qg_measure: function(fontId, ptr, len) {
                return engine.measure(fontId, engine.decode(ptr, len));
            },
            qg_math1: function(op, x) { return MATH1[op](x); },
            qg_math2: function(op, a, b) { return MATH2[op](a, b); },
            qg_host_call: function(op, ptr, len) {
                var handler = engine.hostHandlers[op];
                if (!handler) return 0;
                var reply = handler(engine.decode(ptr, len));
                if (reply == null) return 0;
                var bytes = encoder.encode(String(reply));
                var dst = engine.exports.qg_reply_buffer(bytes.length);
                if (bytes.length) new Uint8Array(engine.memory.buffer, dst, bytes.length).set(bytes);
                return bytes.length;
            },
            qg_view_metrics: function(dst) {
                var m = engine.viewMetrics ? engine.viewMetrics() : [1, 1, 0, 0, 1];
                var out = new Float64Array(engine.memory.buffer, dst, 5);
                for (var i = 0; i < 5; i++) out[i] = m[i];
            },
            qg_set_scroll: function(left, top) {
                if (engine.setScroll) engine.setScroll(left, top);
            },
            qg_log: function(ptr, len) {
                console.log('[qgraph]', engine.decode(ptr, len));
            }
        };
        return { env: env };
    }

    function instantiate(bytesOrResponse) {
        var engine = new Engine({ exports: {} });
        var importObject = imports(engine);
        var promise;
        if (typeof Response !== 'undefined' && bytesOrResponse instanceof Response &&
            typeof WebAssembly.instantiateStreaming === 'function') {
            promise = WebAssembly.instantiateStreaming(bytesOrResponse, importObject)
                .catch(function() {
                    return bytesOrResponse.clone ? bytesOrResponse.arrayBuffer()
                        .then(function(bytes) { return WebAssembly.instantiate(bytes, importObject); }) :
                        Promise.reject(new Error('Could not load qgraph.wasm'));
                });
        } else {
            promise = Promise.resolve(bytesOrResponse).then(function(value) {
                return value instanceof Response ? value.arrayBuffer() : value;
            }).then(function(bytes) { return WebAssembly.instantiate(bytes, importObject); });
        }
        return promise.then(function(result) {
            Engine.call(engine, result.instance);
            engine.exports.qg_init();
            return engine;
        });
    }

    function scriptBase() {
        if (typeof document !== 'undefined' && document.currentScript && document.currentScript.src) {
            return document.currentScript.src.replace(/[^/]*$/, '');
        }
        if (typeof location !== 'undefined') return String(location.href).replace(/[^/]*$/, '');
        return '';
    }

    var base = scriptBase();

    var QGraphWasm = {
        OP: OP,
        Engine: Engine,
        wasmUrl: base + 'qgraph.wasm',
        engine: null,
        /* Loads (once) the shared engine for this realm. */
        load: function(url) {
            if (QGraphWasm.promise) return QGraphWasm.promise;
            var target = url || QGraphWasm.wasmUrl;
            QGraphWasm.promise = fetch(target).then(function(response) {
                if (!response.ok) throw new Error('qgraph.wasm: HTTP ' + response.status);
                return instantiate(response);
            }).then(function(engine) {
                QGraphWasm.engine = engine;
                return engine;
            });
            return QGraphWasm.promise;
        },
        instantiate: instantiate
    };

    root.QGraphWasm = QGraphWasm;
})(typeof self !== 'undefined' ? self : this);
