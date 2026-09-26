/* OffscreenCanvas render worker: its own instance of the QGraph engine,
   used in painter-only mode with a copy of the scene. */
(function() {
    var v = /[?&]v=([A-Za-z0-9._-]+)/.exec(location.search);
    var q = v ? '?v=' + v[1] : '';
    importScripts('QGraphWasm.js' + q, 'RichText.js' + q, 'Stencils.js' + q, 'CanvasPaint.js' + q);
})();

var painter = null;
var canvas = null;
var lastView = null;
var queued = [];

function handle(message) {
    if (message.type === 'sync') {
        painter.syncJson(message.json || '[]');
    } else if (message.type === 'upsert') {
        painter.upsertJson(message.json || '[]');
    } else if (message.type === 'remove') {
        painter.remove(message.ids || []);
    } else if (message.type === 'parallax') {
        painter.setParallaxTarget(message.x, message.y);
        // Worker frames are the settled/full-resolution state. Realtime easing
        // happens on the main thread while the pointer is moving.
        painter.parallax.x = painter.parallaxTarget.x;
        painter.parallax.y = painter.parallaxTarget.y;
    } else if (message.type === 'stencils') {
        // Stencil XML is parsed on the main thread; the worker only receives
        // the resulting draw programs.
        PixelStencils.register(message.shapes || []);
    } else if (message.type === 'render') {
        if (canvas == null) canvas = new OffscreenCanvas(1, 1);
        lastView = message.view;
        var started = performance.now();
        var stats = painter.render(canvas, lastView);
        var bitmap = canvas.transferToImageBitmap();
        stats.renderMs = Math.round((performance.now() - started) * 100) / 100;
        self.postMessage({
            type: 'frame',
            frameId: message.frameId,
            bitmap: bitmap,
            stats: stats
        }, [bitmap]);
    }
}

self.onmessage = function(event) {
    var message = event.data || {};

    if (message.type === 'init') {
        QGraphWasm.load(message.wasmUrl).then(function() {
            painter = new PixelScenePainter();
            // An image decodes after the frame that requested it; ask for a redraw.
            painter.onImageLoad = function() {
                self.postMessage({ type: 'invalidate' });
            };
            canvas = new OffscreenCanvas(1, 1);
            var pending = queued;
            queued = [];
            pending.forEach(handle);
            self.postMessage({ type: 'ready' });
        }).catch(function(error) {
            self.postMessage({ type: 'failed', message: String(error && error.message || error) });
        });
        return;
    }

    if (painter == null) {
        queued.push(message);
        return;
    }
    handle(message);
};
