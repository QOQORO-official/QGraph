/*
 * Scene painter facade for the QGraph engine.
 *
 * Scene culling, shape geometry, connectors, labels, tables and stencils are
 * painted by the Nim engine (qgraph.wasm), which produces a Canvas2D command
 * list for each frame. This file keeps the parts that need browser media
 * APIs -- decoding pictures, sniffing animated GIF/APNG/WebP sources, sampling
 * video frames and the cursor-parallax stacks -- and plays those into the
 * frame where the engine asks for them (the media op).
 *
 * Used on the page (realtime/fallback painters, outline, previews, export)
 * and inside the render worker.
 */
(function(root) {
    'use strict';

    function engine() {
        var loaded = root.QGraphWasm && root.QGraphWasm.engine;
        if (!loaded) throw new Error('QGraph engine is not loaded yet');
        return loaded;
    }
    function clamp(value, min, max) {
        return Math.max(min, Math.min(max, value));
    }

    /* Video-source check that also works inside the render worker, where
       PixelMedia (DOM video plumbing) is not loaded. Kept in sync with the
       native MP4/WebM cases of PixelMedia.isVideo; YouTube is only recognised
       on the main thread, which is fine because a YouTube iframe can never be
       canvas-composited anyway. */
    function isVideoSource(src, mediaType) {
        if (root.PixelMedia != null) return root.PixelMedia.isVideo(src, mediaType);
        var type = String(mediaType || '').toLowerCase();
        if (/^video\//.test(type)) return true;
        var head = String(src || '').slice(0, 128);
        return /^data:video\//i.test(head) || /\.(?:mp4|webm)(?:[?#]|$)/i.test(head);
    }

    function isYouTubeSource(src) {
        return root.PixelMedia != null && root.PixelMedia.isYouTube(src);
    }


    /* `handle` attaches to an existing engine painter (the editor's own
       realtime painter lives inside the engine and shares its scene). */
    function ScenePainter(handle) {
        this.engine = engine();
        this.owned = handle == null;
        this.handle = handle == null ? this.engine.exports.qg_painter_new() : handle;
        this.images = new Map();
        /* Pointer-driven parallax for layered media nodes. parallaxTarget is
           set by the host on pointermove (-1..1 over the canvas); parallax
           eases toward it on every layered draw, like the Persona wallpaper's
           800 ms OutQuart mouse behaviour. The worker painter never receives a
           target, so worker frames simply render layers at rest. */
        this.parallax = { x: 0, y: 0 };
        this.parallaxTarget = { x: 0, y: 0 };
        this.parallaxLastTime = 0;
        this.parallaxFrameTime = 0;
        this.hasLayeredItems = false;
        this.drawMedia = this.drawImageNode.bind(this);
    }


    ScenePainter.prototype.setParallaxTarget = function(x, y) {
        this.parallaxTarget.x = clamp(Number(x) || 0, -1, 1);
        this.parallaxTarget.y = clamp(Number(y) || 0, -1, 1);
    };

    /* Advances cursor parallax once per painted frame, rather than once per
       layered node. The old per-node update made the smoothing speed depend on
       how many parallax blocks happened to be visible. The time-based easing
       below keeps the feel stable at 60/120/144 Hz and after dropped frames. */
    ScenePainter.prototype.advanceParallax = function(now) {
        var dx = this.parallaxTarget.x - this.parallax.x;
        var dy = this.parallaxTarget.y - this.parallax.y;
        if (Math.abs(dx) <= 0.0005 && Math.abs(dy) <= 0.0005) {
            this.parallax.x = this.parallaxTarget.x;
            this.parallax.y = this.parallaxTarget.y;
            this.parallaxLastTime = 0;
            return false;
        }

        now = Number(now) || (typeof performance !== 'undefined' ? performance.now() : Date.now());
        var dt = this.parallaxLastTime > 0 ? now - this.parallaxLastTime : (1000 / 60);
        // Do not let a background-tab or off-screen pause turn into one huge
        // jump when painting resumes.
        dt = clamp(dt, 4, 34);
        this.parallaxLastTime = now;

        // Equivalent to roughly 12% easing per 60 Hz frame, but frame-rate
        // independent. 130 ms is the matching exponential time constant.
        var amount = 1 - Math.exp(-dt / 130);
        this.parallax.x += dx * amount;
        this.parallax.y += dy * amount;
        return true;
    };

    /* Decodes an image once and caches it. Returns null while it is loading,
       false if it failed. Works both on the window (Image) and inside the
       render worker (fetch + createImageBitmap), so image nodes paint in
       either mode; onImageLoad lets the host repaint when a decode lands. */
    /* Multi-frame detection.
     *
     * An <img> holding an animated GIF advances by itself, so drawing it
     * repeatedly animates. A worker ImageBitmap is a single frozen frame. The
     * scene therefore has to know which sources move, so the host can keep
     * repainting them on the main thread. */
    function bytesAreAnimated(bytes) {
        if (bytes == null || bytes.length < 16) return false;

        // GIF: more than one Graphic Control Extension means more than a frame.
        if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
            var frames = 0;
            for (var i = 0; i < bytes.length - 3; i++) {
                if (bytes[i] === 0x21 && bytes[i + 1] === 0xF9 && bytes[i + 2] === 0x04) {
                    frames++;
                    if (frames > 1) return true;
                }
            }
            return false;
        }

        var head = '';
        var limit = Math.min(bytes.length, 4096);
        for (var c = 0; c < limit; c++) head += String.fromCharCode(bytes[c]);

        // APNG announces itself with an acTL chunk before the first IDAT.
        if (bytes[0] === 0x89 && bytes[1] === 0x50) {
            var actl = head.indexOf('acTL');
            var idat = head.indexOf('IDAT');
            return actl >= 0 && (idat < 0 || actl < idat);
        }

        // Animated WebP carries an ANIM chunk.
        if (head.indexOf('RIFF') === 0 && head.indexOf('WEBP') === 8) {
            return head.indexOf('ANIM') > 0;
        }

        return false;
    }

    /* Above this many base64 characters, decode incrementally instead. */
    var CHUNK_THRESHOLD = 512 * 1024;

    function decodeDataUri(src) {
        var comma = src.indexOf(',');
        if (comma < 0) return null;
        var meta = src.substring(0, comma);
        var body = src.substring(comma + 1);

        try {
            if (/;base64/i.test(meta)) {
                var binary = atob(body);
                var bytes = new Uint8Array(binary.length);
                for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                return bytes;
            }
            return new TextEncoder().encode(decodeURIComponent(body));
        } catch (error) {
            return null;
        }
    }

    /* Browsers only guarantee that an <img> keeps advancing its frames while
       it is in the document, and a detached one can be throttled or frozen.
       Animated sources therefore get parked in a hidden, zero-size holder so
       drawImage always samples a moving picture. */
    function parkForAnimation(image, src, painter) {
        if (typeof document === 'undefined' || !painter.isAnimated(src)) return;
        if (image.parentNode != null) return;

        var holder = document.getElementById('pixel-animation-holder');

        if (holder == null) {
            holder = document.createElement('div');
            holder.id = 'pixel-animation-holder';
            holder.setAttribute('aria-hidden', 'true');
            holder.style.cssText = 'position:absolute;width:0;height:0;overflow:hidden;' +
                'opacity:0;pointer-events:none;left:-9999px;top:0;';
            document.body.appendChild(holder);
        }

        image.style.cssText = 'position:absolute;width:1px;height:1px;';
        holder.appendChild(image);
    }

    ScenePainter.prototype.markAnimated = function(src) {
        if (this.animated == null) this.animated = new Set();
        if (this.animated.has(src)) return;
        this.animated.add(src);

        // Hand it to the decoder so frames come from us rather than from the
        // browser's own image animation, which does not run for a picture that
        // is never rendered as an element.
        if (this.playback != null) this.playback.add(src);
        else {
            // No decoder available (worker blocked): fall back to the element,
            // parked in the document so the browser at least tries to play it.
            var element = this.ensureElement(src);
            if (element != null) parkForAnimation(element, src, this);
        }

        // Wakes the host so it can start the playback loop.
        if (typeof this.onImageLoad === 'function') this.onImageLoad(src);
    };

    ScenePainter.prototype.isAnimated = function(src) {
        return this.animated != null && this.animated.has(src);
    };

    ScenePainter.prototype.markVideo = function(src, mediaType, loop) {
        if (!src) return;
        if (this.videoSources == null) this.videoSources = new Set();
        var first = !this.videoSources.has(src);
        this.videoSources.add(src);
        if (this.animated == null) this.animated = new Set();
        this.animated.add(src);
        if (this.mediaPlayback != null) this.mediaPlayback.add(src, mediaType, loop);
        if (first && typeof this.onImageLoad === 'function') this.onImageLoad(src);
    };

    /* Scans a base64 GIF payload for a second frame without ever decoding the
     * whole thing at once. Diagrams embed multi-megabyte GIFs as data URIs, and
     * decoding one in a single pass blocks the UI for seconds. This walks it in
     * slices, yielding between them, and stops at the second frame marker --
     * which for a real animation is usually inside the first slice or two. */
    function scanBase64Gif(body, onResult) {
        var CHUNK = 64 * 1024;          // base64 chars per slice (48 KB decoded)
        var CAP = 24 * 1024 * 1024;     // give up rather than grind forever
        var offset = 0;
        var frames = 0;
        var carry = [];

        function step() {
            var slice = body.substr(offset, CHUNK);

            if (slice === '' || offset > CAP) {
                onResult(false);
                return;
            }

            offset += slice.length;
            var bytes;

            try {
                var binary = atob(slice);
                bytes = new Uint8Array(binary.length);
                for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            } catch (error) {
                onResult(false);
                return;
            }

            // Carry the last two bytes so a marker split across slices counts.
            var window = carry.concat(Array.prototype.slice.call(bytes, 0, 2));
            for (var w = 0; w + 2 < window.length; w++) {
                if (window[w] === 0x21 && window[w + 1] === 0xF9 && window[w + 2] === 0x04) frames++;
            }
            for (var b = 0; b + 2 < bytes.length; b++) {
                if (bytes[b] === 0x21 && bytes[b + 1] === 0xF9 && bytes[b + 2] === 0x04) {
                    frames++;
                    if (frames > 1) { onResult(true); return; }
                }
            }

            carry = Array.prototype.slice.call(bytes, Math.max(0, bytes.length - 2));
            if (frames > 1) { onResult(true); return; }
            setTimeout(step, 0);
        }

        step();
    }

    ScenePainter.prototype.detectAnimation = function(src) {
        var self = this;
        if (!src) return;

        // Sniffing is one-shot per source: this is also called from sync and
        // upsert, which run far more often than a draw.
        if (this.checkedAnimation == null) this.checkedAnimation = new Set();
        if (this.checkedAnimation.has(src)) return;
        this.checkedAnimation.add(src);

        if (isVideoSource(src)) {
            // Every native video is canvas-composited in z-order now (the DOM
            // overlay only carries its controls), so it always needs decoding.
            // YouTube stays an iframe overlay and is never sampled.
            if (!isYouTubeSource(src)) {
                this.markVideo(src, root.PixelMedia != null ? root.PixelMedia.typeFor(src) : '', true);
            }
            return;
        }

        if (/^data:/i.test(src)) {
            var comma = src.indexOf(',');
            var meta = comma < 0 ? '' : src.substring(0, comma);
            var body = comma < 0 ? '' : src.substring(comma + 1);

            // Big base64 GIFs get the incremental scan; everything else is
            // small enough to look at in one go.
            if (/;base64/i.test(meta) && /gif/i.test(meta) && body.length > CHUNK_THRESHOLD) {
                scanBase64Gif(body, function(animated) {
                    if (animated) self.markAnimated(src);
                });
                return;
            }

            if (bytesAreAnimated(decodeDataUri(src))) this.markAnimated(src);
            return;
        }

        if (typeof fetch !== 'function') {
            if (/\.gif(\?|#|$)/i.test(src)) this.markAnimated(src);
            return;
        }

        fetch(src, { cache: 'force-cache' })
            .then(function(response) { return response.arrayBuffer(); })
            .then(function(buffer) {
                if (bytesAreAnimated(new Uint8Array(buffer))) self.markAnimated(src);
            })
            .catch(function() {
                // A cross-origin fetch can fail where <img> succeeds; fall back
                // to the file extension so obvious GIFs still animate.
                if (/\.gif(\?|#|$)/i.test(src)) self.markAnimated(src);
            });
    };

    /* Creates (once) the <img> that backs a source. Kept separate from
       resolveImage so an animated picture can start playing as soon as it is
       recognised, without waiting for the first frame that draws it. */
    ScenePainter.prototype.ensureElement = function(src) {
        if (typeof Image === 'undefined' || !src) return null;
        if (this.elements == null) this.elements = new Map();
        if (this.elements.has(src)) return this.elements.get(src);

        var self = this;
        var image = new Image();
        this.elements.set(src, image);

        image.onload = function() {
            self.images.set(src, image);
            if (typeof self.onImageLoad === 'function') self.onImageLoad(src);
        };
        image.onerror = function() { self.images.set(src, false); };
        if (!/^data:/.test(src)) image.crossOrigin = 'anonymous';
        image.src = src;
        parkForAnimation(image, src, this);
        return image;
    };

    ScenePainter.prototype.resolveImage = function(src) {
        if (!src) return false;
        if (this.images.has(src)) return this.images.get(src);
        this.images.set(src, null);

        var self = this;
        function done(bitmap) {
            self.images.set(src, bitmap);
            if (typeof self.onImageLoad === 'function') self.onImageLoad(src);
        }
        function failed() { self.images.set(src, false); }

        this.detectAnimation(src);

        if (typeof Image !== 'undefined') {
            // The element keeps animating on its own; each draw samples it.
            this.ensureElement(src);
        } else if (typeof fetch === 'function' && typeof createImageBitmap === 'function') {
            fetch(src).then(function(response) { return response.blob(); })
                .then(createImageBitmap).then(done).catch(failed);
        } else {
            failed();
        }

        return null;
    };

    /* Sniffs every image in a set of items without waiting for a draw.
     *
     * In worker mode the worker's painter does the drawing, so the main-thread
     * painter would otherwise never resolve an image and never learn that it
     * animates -- and since only the main thread can play an animation, the
     * playback loop would never start. Scanning on sync/upsert breaks that
     * circle. */
    ScenePainter.prototype.scanForAnimation = function(items) {
        for (var i = 0; i < (items || []).length; i++) {
            var item = items[i];
            if (!item) continue;
            var layered = Array.isArray(item.mediaLayers) && item.mediaLayers.length > 0;
            if (layered) this.hasLayeredItems = true;
            if (item.src) {
                if (isVideoSource(item.src, item.mediaType)) {
                    // Native video is always canvas-composited in z-order (the
                    // DOM overlay only carries controls), so it always needs
                    // decoding. YouTube stays an iframe overlay.
                    if (!isYouTubeSource(item.src)) {
                        this.markVideo(item.src, item.mediaType, item.mediaLoop);
                    }
                } else {
                    this.detectAnimation(item.src);
                }
            }
            if (layered) {
                for (var j = 0; j < item.mediaLayers.length; j++) {
                    var layer = item.mediaLayers[j];
                    if (!layer || !layer.src) continue;
                    if (isVideoSource(layer.src, layer.mediaType)) {
                        this.markVideo(layer.src, layer.mediaType, true);
                    } else {
                        this.detectAnimation(layer.src);
                    }
                }
            }
        }
    };

    /* True while a parallax-layered node still has reason to repaint: a
       scrolling layer never settles, and easing runs until parallax catches
       its target. */
    ScenePainter.prototype.parallaxLoopNeeded = function(item) {
        var layers = item && item.mediaLayers;
        if (!Array.isArray(layers) || layers.length === 0) return false;
        for (var i = 0; i < layers.length; i++) {
            if (layers[i] && (Number(layers[i].scrollX) || Number(layers[i].scrollY))) return true;
        }
        return Math.abs(this.parallaxTarget.x - this.parallax.x) > 0.001 ||
            Math.abs(this.parallaxTarget.y - this.parallax.y) > 0.001;
    };

    /* Reports moving content in one visibility pass. Parallax is kept
       separate because it needs display-synchronised frames; GIF decoders can
       keep their own source timing. Layer sources are checked too (the older
       test only looked at the base media source). */
    ScenePainter.prototype.visibleAnimationState = function(view) {
        var state = { any: false, parallax: false, media: false };
        if ((this.animated == null || this.animated.size === 0) && !this.hasLayeredItems) return state;
        var visible = this.getVisibleItems(view);

        for (var i = 0; i < visible.length; i++) {
            var item = visible[i];
            if (item.src && this.animated != null && this.animated.has(item.src)) {
                state.media = true;
            }

            // A canvas-composited native video keeps the main-thread painter in
            // charge while visible (via the animated set above) and needs
            // display-rate frames while it is actually playing.
            if (item.src && this.mediaPlayback != null &&
                isVideoSource(item.src, item.mediaType)) {
                var mediaState = this.mediaPlayback.stateFor(item.src);
                if (mediaState != null && mediaState.ready && !mediaState.failed &&
                    !mediaState.video.paused && !mediaState.video.ended) {
                    state.parallax = true;
                }
            }

            if (Array.isArray(item.mediaLayers) && item.mediaLayers.length > 0) {
                if (this.parallaxLoopNeeded(item)) state.parallax = true;
                // Layered video is sampled directly into the canvas (there is
                // intentionally no DOM media overlay for parallax stacks), so
                // it also needs display-rate painting even after the cursor
                // itself has settled.
                if (item.src && isVideoSource(item.src, item.mediaType)) {
                    state.parallax = true;
                }
                if (this.animated != null) {
                    for (var j = 0; j < item.mediaLayers.length; j++) {
                        var layer = item.mediaLayers[j];
                        if (layer && layer.src && this.animated.has(layer.src)) {
                            state.media = true;
                            if (isVideoSource(layer.src, layer.mediaType)) {
                                state.parallax = true;
                            }
                        }
                    }
                }
            }

            if (state.parallax && state.media) break;
        }

        state.any = state.parallax || state.media;
        return state;
    };

    ScenePainter.prototype.hasVisibleAnimation = function(view) {
        return this.visibleAnimationState(view).any;
    };

    root.PixelImageAnimation = { bytesAreAnimated: bytesAreAnimated, decodeDataUri: decodeDataUri };

    /* Contain-fit inside the node box, as the classic image shape does. */
    ScenePainter.prototype.drawImageNode = function(ctx, node) {
        var layers = Array.isArray(node.mediaLayers) && node.mediaLayers.length > 0 ?
            node.mediaLayers : null;
        var videoSource = isVideoSource(node.src, node.mediaType);
        // Native video (MP4/WebM) is sampled straight into the canvas so the
        // node honours the scene z-order — objects arranged in front of it
        // must really paint in front. The synchronized DOM overlay only adds
        // the control bar on top; it no longer carries the picture.
        // Exception: a YouTube iframe can never be canvas-composited
        // (cross-origin), so it keeps its full DOM overlay. Paint only the
        // dark backing plate here; the overlay supplies the moving frame.
        if (videoSource && layers == null && isYouTubeSource(node.src)) {
            ctx.save();
            ctx.fillStyle = '#111111';
            ctx.fillRect(node.x, node.y, node.width, node.height);
            ctx.restore();
            return;
        }
        var bitmap = (videoSource && this.mediaPlayback != null) ?
            this.mediaPlayback.frameFor(node.src, node.mediaType, node.mediaLoop) : null;
        // An animated source is played from decoded frames; the <img> would be
        // frozen because the browser never renders it as an element.
        if (bitmap == null && !videoSource && this.playback != null) bitmap = this.playback.frameFor(node.src);
        if (bitmap == null && !videoSource) bitmap = this.resolveImage(node.src);

        if (!bitmap) {
            ctx.save();
            ctx.fillStyle = '#eef1f5';
            ctx.fillRect(node.x, node.y, node.width, node.height);
            ctx.strokeStyle = '#b6bec9';
            ctx.lineWidth = 1;
            ctx.setLineDash([4, 3]);
            ctx.strokeRect(node.x + .5, node.y + .5, node.width - 1, node.height - 1);
            ctx.setLineDash([]);
            ctx.fillStyle = '#8a94a2';
            ctx.font = '11px Arial, sans-serif';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            var unavailable = videoSource && this.mediaPlayback != null &&
                this.mediaPlayback.stateFor(node.src) && this.mediaPlayback.stateFor(node.src).failed;
            ctx.fillText(bitmap === false || unavailable ? 'Media unavailable' : 'Loading media…',
                node.x + node.width / 2, node.y + node.height / 2);
            ctx.restore();
            return;
        }

        this.drawFittedBitmap(ctx, bitmap, node, node.imageFit, node.imageOpacity, 0, 0);
        if (layers != null) this.drawMediaLayers(ctx, node, layers);
    };

    /* Fit/align/opacity draw shared by the base image and parallax layers. */
    ScenePainter.prototype.drawFittedBitmap = function(ctx, bitmap, node, fit, opacity, offsetX, offsetY) {
        var naturalWidth = bitmap.videoWidth || bitmap.naturalWidth || bitmap.width || node.width;
        var naturalHeight = bitmap.videoHeight || bitmap.naturalHeight || bitmap.height || node.height;
        fit = fit || 'contain';

        ctx.save();
        if (opacity != null) ctx.globalAlpha *= clamp(opacity, 0, 1);

        // 'tile' repeats at natural size; the others scale a single copy.
        // If the context cannot build a pattern, fall through to a scaled
        // draw rather than leaving the shape blank.
        if (fit === 'tile') {
            var pattern = null;
            try { pattern = ctx.createPattern(bitmap, 'repeat'); } catch (error) { pattern = null; }

            if (pattern != null) {
                ctx.fillStyle = pattern;
                ctx.translate(node.x, node.y);
                ctx.fillRect(0, 0, node.width, node.height);
                ctx.restore();
                return;
            }

            fit = 'contain';
        }

        var scale;
        if (fit === 'stretch') scale = null;
        else if (fit === 'cover') scale = Math.max(node.width / naturalWidth, node.height / naturalHeight);
        else if (fit === 'none') scale = 1;
        else scale = Math.min(node.width / naturalWidth, node.height / naturalHeight);

        var width = scale == null ? node.width : naturalWidth * scale;
        var height = scale == null ? node.height : naturalHeight * scale;
        var alignX = node.imageAlign === 'left' ? 0 :
            node.imageAlign === 'right' ? node.width - width : (node.width - width) / 2;
        var alignY = node.imageVerticalAlign === 'top' ? 0 :
            node.imageVerticalAlign === 'bottom' ? node.height - height : (node.height - height) / 2;

        // cover and none can overflow the node, so clip to its box.
        if (width > node.width || height > node.height) {
            ctx.beginPath();
            ctx.rect(node.x, node.y, node.width, node.height);
            ctx.clip();
        }

        ctx.drawImage(bitmap, node.x + alignX + (offsetX || 0), node.y + alignY + (offsetY || 0),
            width, height);
        ctx.restore();
    };

    /* Bitmap for one parallax layer, resolved through the same decoders as
       the base image: video frames, decoded GIF frames, then plain images. */
    ScenePainter.prototype.layerBitmap = function(layer) {
        var videoSource = isVideoSource(layer.src, layer.mediaType);
        if (videoSource) {
            return this.mediaPlayback != null ?
                this.mediaPlayback.frameFor(layer.src, layer.mediaType, true) : null;
        }
        if (this.playback != null) {
            var frame = this.playback.frameFor(layer.src);
            if (frame != null) return frame;
        }
        return this.resolveImage(layer.src);
    };

    /* Paints the parallax stack back to front, clipped to the node box. Each
       layer cover-fits with a small depth-scaled margin so pointer shifts
       never expose an edge; scrolling layers tile with a modulo offset so the
       drift loops seamlessly, like the train-window bars in the Persona
       reference wallpaper. */
    ScenePainter.prototype.drawMediaLayers = function(ctx, node, layers) {
        // Parallax itself advances once in render(), so every layered node sees
        // exactly the same cursor position and scrolling timestamp this frame.
        var now = this.parallaxFrameTime ||
            (typeof performance !== 'undefined' ? performance.now() : Date.now());

        ctx.save();
        ctx.beginPath();
        ctx.rect(node.x, node.y, node.width, node.height);
        ctx.clip();

        for (var i = 0; i < layers.length; i++) {
            var layer = layers[i];
            if (!layer || !layer.src) continue;
            var bitmap = this.layerBitmap(layer);
            if (!bitmap) continue;

            var depth = clamp(Number(layer.depth) || 0, 0, 1);
            var marginX = depth * node.width * 0.06;
            var marginY = depth * node.height * 0.06;
            var naturalWidth = bitmap.videoWidth || bitmap.naturalWidth || bitmap.width || node.width;
            var naturalHeight = bitmap.videoHeight || bitmap.naturalHeight || bitmap.height || node.height;
            var scale = Math.max((node.width + 2 * marginX) / naturalWidth,
                (node.height + 2 * marginY) / naturalHeight);
            var width = naturalWidth * scale;
            var height = naturalHeight * scale;
            var centerX = node.x + (node.width - width) / 2 - this.parallax.x * marginX;
            var centerY = node.y + (node.height - height) / 2 - this.parallax.y * marginY;

            ctx.save();
            ctx.globalAlpha *= clamp(layer.opacity == null ? 1 : Number(layer.opacity) || 0, 0, 1);

            var scrollX = Number(layer.scrollX) || 0;
            var scrollY = Number(layer.scrollY) || 0;
            if (scrollX || scrollY) {
                var shiftX = scrollX ? (now / 1000 * scrollX) % width : 0;
                var shiftY = scrollY ? (now / 1000 * scrollY) % height : 0;
                for (var tx = -1; tx <= 1; tx++) {
                    for (var ty = -1; ty <= 1; ty++) {
                        var dx = centerX - shiftX + tx * width;
                        var dy = centerY - shiftY + ty * height;
                        if (dx + width <= node.x || dx >= node.x + node.width ||
                            dy + height <= node.y || dy >= node.y + node.height) continue;
                        ctx.drawImage(bitmap, dx, dy, width, height);
                    }
                }
            } else {
                ctx.drawImage(bitmap, centerX, centerY, width, height);
            }
            ctx.restore();
        }

        ctx.restore();
    };

    /* ------------------------------------------------------------------ */
    /* Scene: kept inside the engine                                       */
    /* ------------------------------------------------------------------ */

    ScenePainter.prototype.refreshLayered = function() {
        this.hasLayeredItems = this.engine.exports.qg_painter_has_layered(this.handle) === 1;
    };

    ScenePainter.prototype.sync = function(items) {
        this.engine.callJson('qg_painter_sync', [this.handle], items || []);
        this.refreshLayered();
    };

    ScenePainter.prototype.upsert = function(items) {
        this.engine.callJson('qg_painter_upsert', [this.handle], items || []);
        this.refreshLayered();
    };

    ScenePainter.prototype.remove = function(ids) {
        this.engine.callJson('qg_painter_remove', [this.handle], ids || []);
        this.refreshLayered();
    };

    /* Visible objects that carry media ({id, src, mediaType, mediaLoop,
       mediaLayers}); ordinary shapes are not reported. */
    ScenePainter.prototype.getVisibleItems = function(view) {
        return this.engine.callOutJson('qg_painter_visible_media', [this.handle],
            JSON.stringify(view)) || [];
    };

    ScenePainter.prototype.render = function(canvas, view) {
        this.parallaxFrameTime = typeof performance !== 'undefined' ? performance.now() : Date.now();
        this.refreshLayered();
        if (this.hasLayeredItems) this.advanceParallax(this.parallaxFrameTime);

        var engine = this.engine;
        engine.call('qg_painter_render', [this.handle], JSON.stringify(view));
        var stats = new Float64Array(engine.memory.buffer, engine.exports.qg_stats_ptr(), 4);
        var result = {
            visible: stats[0], total: stats[1],
            pixelWidth: stats[2], pixelHeight: stats[3]
        };

        if (canvas.width !== result.pixelWidth) canvas.width = result.pixelWidth;
        if (canvas.height !== result.pixelHeight) canvas.height = result.pixelHeight;
        var ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
        engine.replay(ctx, this.drawMedia);
        return result;
    };

    ScenePainter.prototype.destroy = function() {
        if (this.owned) this.engine.exports.qg_painter_free(this.handle);
    };

    /* The subset of PixelGeometry the editor chrome uses. */
    root.PixelGeometry = {
        itemBounds: function(item, scene) {
            var items = [];
            if (scene) {
                if (typeof scene.forEach === 'function' && !Array.isArray(scene)) {
                    scene.forEach(function(value) { items.push(value); });
                } else {
                    Object.keys(scene).forEach(function(key) { items.push(scene[key]); });
                }
            }
            return engine().callOutJson('qg_item_bounds', [],
                JSON.stringify({ item: item, items: items }));
        }
    };

    root.PixelScenePainter = ScenePainter;
})(typeof self !== 'undefined' ? self : window);
