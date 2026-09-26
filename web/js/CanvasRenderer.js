/*
 * ImageBitmap presentation layer for the pixel-native graph engine.
 * Rasterization happens in renderer-worker.js; this file presents frames with
 * WebGPU, WebGL2/WebGL, or Canvas2D without adding per-object DOM nodes.
 */
(function(root) {
    'use strict';

    function requestedBackend() {
        var match = /(?:\?|&)renderer=([^&]+)/i.exec(location.search);
        var value = match ? decodeURIComponent(match[1]).toLowerCase() : 'auto';
        return /^(auto|webgpu|webgl|canvas2d)$/.test(value) ? value : 'auto';
    }

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

    Canvas2DPresenter.prototype.destroy = function() {};

    function WebGLPresenter(canvas) {
        this.canvas = canvas;
        this.gl = canvas.getContext('webgl2', {
            alpha: false,
            antialias: false,
            depth: false,
            stencil: false,
            premultipliedAlpha: true,
            preserveDrawingBuffer: false
        });
        this.isWebGL2 = this.gl != null;

        if (this.gl == null) {
            this.gl = canvas.getContext('webgl', {
                alpha: false,
                antialias: false,
                depth: false,
                stencil: false,
                premultipliedAlpha: true,
                preserveDrawingBuffer: false
            });
        }

        if (this.gl == null) throw new Error('WebGL is unavailable');
        this.name = this.isWebGL2 ? 'webgl2' : 'webgl';
        this.initialize();
    }

    WebGLPresenter.prototype.compile = function(type, source) {
        var gl = this.gl;
        var shader = gl.createShader(type);
        gl.shaderSource(shader, source);
        gl.compileShader(shader);

        if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
            var error = gl.getShaderInfoLog(shader);
            gl.deleteShader(shader);
            throw new Error(error || 'WebGL shader compilation failed');
        }
        return shader;
    };

    WebGLPresenter.prototype.initialize = function() {
        var gl = this.gl;
        var vertexSource = this.isWebGL2 ?
            '#version 300 es\nin vec2 a;out vec2 uv;void main(){gl_Position=vec4(a,0,1);uv=vec2((a.x+1.0)*.5,(1.0-a.y)*.5);}' :
            'attribute vec2 a;varying vec2 uv;void main(){gl_Position=vec4(a,0,1);uv=vec2((a.x+1.0)*.5,(1.0-a.y)*.5);}';
        var fragmentSource = this.isWebGL2 ?
            '#version 300 es\nprecision mediump float;in vec2 uv;uniform sampler2D image;out vec4 color;void main(){color=texture(image,uv);}' :
            'precision mediump float;varying vec2 uv;uniform sampler2D image;void main(){gl_FragColor=texture2D(image,uv);}';
        var vertex = this.compile(gl.VERTEX_SHADER, vertexSource);
        var fragment = this.compile(gl.FRAGMENT_SHADER, fragmentSource);
        var program = gl.createProgram();
        gl.attachShader(program, vertex);
        gl.attachShader(program, fragment);
        gl.linkProgram(program);
        gl.deleteShader(vertex);
        gl.deleteShader(fragment);

        if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
            throw new Error(gl.getProgramInfoLog(program) || 'WebGL link failed');
        }

        this.program = program;
        this.buffer = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
            -1, -1, 1, -1, -1, 1,
            -1, 1, 1, -1, 1, 1
        ]), gl.STATIC_DRAW);
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
    };

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

    WebGLPresenter.prototype.destroy = function() {
        if (this.texture) this.gl.deleteTexture(this.texture);
        if (this.buffer) this.gl.deleteBuffer(this.buffer);
        if (this.program) this.gl.deleteProgram(this.program);
    };

    function WebGPUPresenter(canvas, device, format) {
        this.canvas = canvas;
        this.device = device;
        this.format = format;
        this.context = canvas.getContext('webgpu');
        if (this.context == null) throw new Error('WebGPU canvas context is unavailable');
        this.name = 'webgpu';
        this.initialize();
    }

    WebGPUPresenter.prototype.initialize = function() {
        var shader = this.device.createShaderModule({ code: [
            'struct O{@builtin(position) p:vec4f,@location(0) uv:vec2f};',
            '@vertex fn vs(@builtin(vertex_index)i:u32)->O{',
            'var p=array<vec2f,6>(vec2f(-1,-1),vec2f(1,-1),vec2f(-1,1),vec2f(-1,1),vec2f(1,-1),vec2f(1,1));',
            'var u=array<vec2f,6>(vec2f(0,1),vec2f(1,1),vec2f(0,0),vec2f(0,0),vec2f(1,1),vec2f(1,0));',
            'var o:O;o.p=vec4f(p[i],0,1);o.uv=u[i];return o;}',
            '@group(0) @binding(0)var s:sampler;',
            '@group(0) @binding(1)var t:texture_2d<f32>;',
            '@fragment fn fs(o:O)->@location(0) vec4f{return textureSample(t,s,o.uv);}'
        ].join('\n') });
        this.pipeline = this.device.createRenderPipeline({
            layout: 'auto',
            vertex: { module: shader, entryPoint: 'vs' },
            fragment: { module: shader, entryPoint: 'fs', targets: [{ format: this.format }] },
            primitive: { topology: 'triangle-list' }
        });
        this.sampler = this.device.createSampler({ minFilter: 'linear', magFilter: 'linear' });
    };

    WebGPUPresenter.prototype.resize = function(width, height) {
        if (this.canvas.width !== width) this.canvas.width = width;
        if (this.canvas.height !== height) this.canvas.height = height;
        this.context.configure({
            device: this.device,
            format: this.format,
            alphaMode: 'opaque'
        });
        if (this.texture) this.texture.destroy();
        this.texture = this.device.createTexture({
            size: [width, height, 1],
            format: 'rgba8unorm',
            usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST
        });
        this.bindGroup = this.device.createBindGroup({
            layout: this.pipeline.getBindGroupLayout(0),
            entries: [
                { binding: 0, resource: this.sampler },
                { binding: 1, resource: this.texture.createView() }
            ]
        });
    };

    WebGPUPresenter.prototype.present = function(source) {
        if (this.canvas.width !== source.width || this.canvas.height !== source.height || !this.texture) {
            this.resize(source.width, source.height);
        }
        this.device.queue.copyExternalImageToTexture(
            { source: source }, { texture: this.texture }, [source.width, source.height]);
        var encoder = this.device.createCommandEncoder();
        var pass = encoder.beginRenderPass({ colorAttachments: [{
            view: this.context.getCurrentTexture().createView(),
            clearValue: { r: 1, g: 1, b: 1, a: 1 },
            loadOp: 'clear', storeOp: 'store'
        }] });
        pass.setPipeline(this.pipeline);
        pass.setBindGroup(0, this.bindGroup);
        pass.draw(6);
        pass.end();
        this.device.queue.submit([encoder.finish()]);
    };

    WebGPUPresenter.prototype.destroy = function() {
        if (this.texture) this.texture.destroy();
        this.context.unconfigure();
    };

    function createPresenter(canvas) {
        var requested = requestedBackend();

        if (requested === 'canvas2d') return Promise.resolve(new Canvas2DPresenter(canvas));

        // WebGPU can be exposed by Chromium even when the underlying Dawn/GPU
        // presentation path is unusable (notably on some Windows VPS hosts).
        // Prefer the mature WebGL path in auto mode; WebGPU remains available
        // as an explicit opt-in with ?renderer=webgpu.
        if (requested !== 'webgpu') {
            try {
                return Promise.resolve(new WebGLPresenter(canvas));
            } catch (error) {
                return Promise.resolve(new Canvas2DPresenter(canvas));
            }
        }

        var gpuPromise = navigator.gpu != null ? Promise.race([
            navigator.gpu.requestAdapter(),
            new Promise(function(resolve) { setTimeout(function() { resolve(null); }, 1500); })
        ]) : Promise.resolve(null);

        return gpuPromise.then(function(adapter) {
            if (adapter == null) throw new Error('WebGPU adapter unavailable');
            return adapter.requestDevice();
        }).then(function(device) {
            return new WebGPUPresenter(canvas, device, navigator.gpu.getPreferredCanvasFormat());
        }).catch(function() {
            try {
                return new WebGLPresenter(canvas);
            } catch (error) {
                return new Canvas2DPresenter(canvas);
            }
        });
    }

    function CanvasRenderer(canvas, options) {
        options = options || {};
        this.canvas = canvas;
        this.onStats = options.onStats || function() {};
        this.presenter = null;
        this.frameId = 0;
        this.inFlight = false;
        this.queued = false;
        this.latestView = null;
        this.ready = false;
        this.destroyed = false;
        this.workerMode = false;
        this.fallbackPainter = null;
        this.fallbackCanvas = null;
        this.realtimePainter = new PixelScenePainter();
        this.realtimeCanvas = document.createElement('canvas');
        this.realtimeActive = false;
        this.realtimeFrame = null;
        this.interactiveDpr = 1.25;
        this.pendingWorkerUpserts = new Map();
        this.parallaxTarget = { x: 0, y: 0 };
        this.parallaxAnimating = false;
        this.presenterPromise = createPresenter(canvas).then(function(presenter) {
            this.presenter = presenter;
            return presenter;
        }.bind(this));

        if (typeof Worker !== 'undefined' && typeof OffscreenCanvas !== 'undefined') {
            try {
                this.worker = new Worker(options.workerUrl || 'js/renderer-worker.js');
                this.workerMode = true;
                this.worker.onmessage = this.onWorkerMessage.bind(this);
                this.worker.onerror = this.useFallback.bind(this);
                this.worker.postMessage({ type: 'init' });
            } catch (error) {
                this.useFallback(error);
            }
        } else {
            this.useFallback();
        }
    }

    CanvasRenderer.prototype.useFallback = function() {
        if (this.worker) this.worker.terminate();
        this.worker = null;
        this.workerMode = false;
        this.ready = true;
        this.fallbackPainter = this.fallbackPainter || new PixelScenePainter();
        this.fallbackCanvas = this.fallbackCanvas || document.createElement('canvas');
        if (typeof this.fallbackPainter.setParallaxTarget === 'function') {
            this.fallbackPainter.setParallaxTarget(this.parallaxTarget.x, this.parallaxTarget.y);
            this.fallbackPainter.parallax.x = this.parallaxTarget.x;
            this.fallbackPainter.parallax.y = this.parallaxTarget.y;
        }
        if (this.latestItems) this.fallbackPainter.sync(this.latestItems);
        if (this.latestView) this.requestFrame(this.latestView);
    };

    CanvasRenderer.prototype.onWorkerMessage = function(event) {
        var message = event.data || {};
        if (message.type === 'ready') {
            this.ready = true;
            if (this.pendingStencils) {
                this.worker.postMessage({ type: 'stencils', shapes: this.pendingStencils });
            }
            if (this.latestItems) this.worker.postMessage({ type: 'sync', items: this.latestItems });
            this.worker.postMessage({ type: 'parallax', x: this.parallaxTarget.x, y: this.parallaxTarget.y });
            if (this.latestView) this.requestFrame(this.latestView);
            return;
        }

        // The worker finished decoding an image, so the last frame is stale.
        if (message.type === 'invalidate') {
            if (this.latestView && !this.realtimeActive) this.requestFrame(this.latestView);
            return;
        }

        if (message.type === 'frame') {
            this.inFlight = false;
            var bitmap = message.bitmap;

            // A worker frame can be one or more pointer events behind. While a
            // gesture is active, the local rAF painter owns presentation. If a
            // newer worker view is queued, skip this stale bitmap entirely.
            if (this.realtimeActive || this.queued) {
                if (bitmap && bitmap.close) bitmap.close();

                if (!this.realtimeActive && this.queued && this.latestView) {
                    this.queued = false;
                    this.sendFrame();
                } else if (this.realtimeActive) {
                    this.queued = false;
                }
                return;
            }

            this.presenterPromise.then(function(presenter) {
                if (!this.destroyed) presenter.present(bitmap);
                if (bitmap && bitmap.close) bitmap.close();
                message.stats.backend = presenter.name;
                message.stats.worker = true;
                this.onStats(message.stats);
                if (this.queued && this.latestView) {
                    this.queued = false;
                    this.sendFrame();
                }
            }.bind(this));
        }
    };

    /* Ships parsed stencil programs to the worker so it can draw them too. */
    CanvasRenderer.prototype.sendStencils = function(shapes) {
        this.pendingStencils = shapes;
        if (this.workerMode && this.ready) {
            this.worker.postMessage({ type: 'stencils', shapes: shapes });
        }
    };

    CanvasRenderer.prototype.setParallaxTarget = function(x, y) {
        x = Math.max(-1, Math.min(1, Number(x) || 0));
        y = Math.max(-1, Math.min(1, Number(y) || 0));
        this.parallaxTarget.x = x;
        this.parallaxTarget.y = y;

        if (this.realtimePainter && typeof this.realtimePainter.setParallaxTarget === 'function') {
            this.realtimePainter.setParallaxTarget(x, y);
        }
        // Fallback/worker renderers are only used after the smoothed realtime
        // motion has settled, so keep them at the exact target. That avoids a
        // one-frame snap back to the unshifted layer stack.
        if (this.fallbackPainter && typeof this.fallbackPainter.setParallaxTarget === 'function') {
            this.fallbackPainter.setParallaxTarget(x, y);
            this.fallbackPainter.parallax.x = x;
            this.fallbackPainter.parallax.y = y;
        }
        if (this.workerMode && this.ready && this.worker) {
            this.worker.postMessage({ type: 'parallax', x: x, y: y });
        }
    };

    CanvasRenderer.prototype.sync = function(items) {
        this.latestItems = items;
        this.pendingWorkerUpserts.clear();
        this.realtimePainter.sync(items);
        if (this.realtimePainter.mediaPlayback &&
            typeof this.realtimePainter.mediaPlayback.retain === 'function') {
            this.realtimePainter.mediaPlayback.retain(items);
        }
        // Learn which sources animate without waiting for a main-thread draw;
        // in worker mode that draw may never come.
        this.realtimePainter.scanForAnimation(items);
        if (this.workerMode) {
            if (this.ready) this.worker.postMessage({ type: 'sync', items: items });
        } else if (this.fallbackPainter) {
            this.fallbackPainter.sync(items);
        }
    };

    CanvasRenderer.prototype.upsert = function(items, deferWorker) {
        if (this.latestItems != null) {
            for (var i = 0; i < items.length; i++) {
                var found = false;
                for (var j = 0; j < this.latestItems.length; j++) {
                    if (this.latestItems[j].id === items[i].id) {
                        this.latestItems[j] = items[i];
                        found = true;
                        break;
                    }
                }
                if (!found) this.latestItems.push(items[i]);
            }
        }

        this.realtimePainter.upsert(items);
        this.realtimePainter.scanForAnimation(items);

        if (this.workerMode) {
            if (deferWorker === true || this.realtimeActive) {
                for (var k = 0; k < items.length; k++) {
                    this.pendingWorkerUpserts.set(items[k].id, items[k]);
                }
            } else if (this.ready) {
                this.worker.postMessage({ type: 'upsert', items: items });
            }
        } else if (this.fallbackPainter) {
            this.fallbackPainter.upsert(items);
        }
    };

    CanvasRenderer.prototype.remove = function(ids) {
        if (this.latestItems != null) {
            var removed = new Set(ids);
            this.latestItems = this.latestItems.filter(function(item) { return !removed.has(item.id); });
        }

        this.realtimePainter.remove(ids);
        if (this.realtimePainter.mediaPlayback &&
            typeof this.realtimePainter.mediaPlayback.retain === 'function') {
            this.realtimePainter.mediaPlayback.retain(this.latestItems || []);
        }
        for (var p = 0; p < ids.length; p++) this.pendingWorkerUpserts.delete(ids[p]);

        if (this.workerMode) {
            if (this.ready) this.worker.postMessage({ type: 'remove', ids: ids });
        } else if (this.fallbackPainter) {
            this.fallbackPainter.remove(ids);
        }
    };

    CanvasRenderer.prototype.requestFrame = function(view, realtime) {
        this.latestView = view;
        if (!this.ready || this.destroyed) return;

        if (realtime === true) {
            this.realtimeActive = true;
            this.requestRealtimeFrame();
            return;
        }

        this.realtimeActive = false;
        if (this.realtimeFrame != null) {
            cancelAnimationFrame(this.realtimeFrame);
            this.realtimeFrame = null;
        }

        if (this.workerMode) {
            this.flushWorkerUpserts();
            if (this.inFlight) this.queued = true;
            else this.sendFrame();
        } else {
            if (this.fallbackFrame) cancelAnimationFrame(this.fallbackFrame);
            this.fallbackFrame = requestAnimationFrame(function() {
                this.fallbackFrame = null;
                var started = performance.now();
                var stats = this.fallbackPainter.render(this.fallbackCanvas, this.latestView);
                this.presenterPromise.then(function(presenter) {
                    presenter.present(this.fallbackCanvas);
                    stats.backend = presenter.name;
                    stats.worker = false;
                    stats.renderMs = Math.round((performance.now() - started) * 100) / 100;
                    this.onStats(stats);
                }.bind(this));
            }.bind(this));
        }
    };

    CanvasRenderer.prototype.flushWorkerUpserts = function() {
        if (!this.workerMode || !this.ready || this.pendingWorkerUpserts.size === 0) return;
        var items = Array.from(this.pendingWorkerUpserts.values());
        this.pendingWorkerUpserts.clear();
        this.worker.postMessage({ type: 'upsert', items: items });
    };

    CanvasRenderer.prototype.requestRealtimeFrame = function() {
        if (this.realtimeFrame != null || !this.latestView) return;

        this.realtimeFrame = requestAnimationFrame(function() {
            this.realtimeFrame = null;
            if (!this.realtimeActive || this.destroyed) return;
            var started = performance.now();
            var realtimeView = Object.assign({}, this.latestView, {
                // A slightly lower transient resolution keeps high-DPI pointer
                // interaction inside the frame budget. The worker replaces it
                // with a full-DPI frame after ordinary gestures settle.
                // GIF/APNG playback can keep full resolution because its
                // cadence is source-limited. Pointer/scroll parallax can run at
                // display rate, so let the adaptive transient DPR protect the
                // frame budget instead of forcing a 2x full-scene repaint.
                dpr: this.animating && !this.parallaxAnimating ? (this.latestView.dpr || 1) :
                    Math.min(this.interactiveDpr, this.latestView.dpr || 1),
                overscan: 20
            });
            var stats = this.realtimePainter.render(this.realtimeCanvas, realtimeView);
            var paintMs = performance.now() - started;
            if (paintMs > 14) this.interactiveDpr = Math.max(.75, this.interactiveDpr - .15);
            else if (paintMs < 7) this.interactiveDpr = Math.min(1.25, this.interactiveDpr + .05);

            this.presenterPromise.then(function(presenter) {
                if (!this.realtimeActive || this.destroyed) return;
                presenter.present(this.realtimeCanvas);
                stats.backend = presenter.name;
                stats.worker = false;
                stats.realtime = true;
                stats.interactiveDpr = realtimeView.dpr;
                stats.renderMs = Math.round((performance.now() - started) * 100) / 100;
                this.onStats(stats);
            }.bind(this));
        }.bind(this));
    };

    CanvasRenderer.prototype.sendFrame = function() {
        if (!this.worker || !this.latestView) return;
        this.inFlight = true;
        this.worker.postMessage({
            type: 'render',
            frameId: ++this.frameId,
            view: this.latestView
        });
    };

    CanvasRenderer.prototype.destroy = function() {
        this.destroyed = true;
        if (this.worker) this.worker.terminate();
        if (this.fallbackFrame) cancelAnimationFrame(this.fallbackFrame);
        if (this.realtimeFrame) cancelAnimationFrame(this.realtimeFrame);
        this.presenterPromise.then(function(presenter) { presenter.destroy(); });
    };

    root.CanvasRenderer = CanvasRenderer;
})(window);
