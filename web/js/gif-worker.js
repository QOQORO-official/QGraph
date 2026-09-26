/*
 * GIF decode worker.
 *
 * Keeps the LZW decoding and frame compositing off the main thread: a large
 * animated GIF would otherwise stall the editor every frame. One sequence is
 * held per source id; the main thread asks for the next frame when the current
 * one's delay has elapsed, so only one frame of work is ever in flight and the
 * decoded bytes never accumulate.
 */
importScripts('GifDecoder.js');

var sequences = Object.create(null);

function loadBytes(src) {
    if (typeof src !== 'string') return Promise.reject(new Error('missing source'));

    if (/^data:/i.test(src)) {
        var comma = src.indexOf(',');
        if (comma < 0) return Promise.reject(new Error('malformed data uri'));
        var meta = src.substring(0, comma);
        var body = src.substring(comma + 1);

        if (!/;base64/i.test(meta)) {
            return Promise.resolve(new TextEncoder().encode(decodeURIComponent(body)));
        }

        // Decode in slices so a huge payload does not build one giant string.
        var binary = atob(body);
        var bytes = new Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return Promise.resolve(bytes);
    }

    return fetch(src, { credentials: 'same-origin' })
        .then(function(response) {
            if (!response.ok) throw new Error('HTTP ' + response.status);
            return response.arrayBuffer();
        })
        .then(function(buffer) { return new Uint8Array(buffer); });
}

self.onmessage = function(event) {
    var message = event.data || {};

    if (message.type === 'load') {
        // The worker resolves the source itself so a multi-megabyte data URI
        // is never base64-decoded on the main thread.
        loadBytes(message.src).then(function(bytes) {
            var sequence = new PixelGifDecoder.GifSequence(bytes);

            if (!sequence.valid()) {
                self.postMessage({ type: 'failed', id: message.id, error: 'not an animated gif' });
                return;
            }

            sequences[message.id] = sequence;
            self.postMessage({
                type: 'loaded', id: message.id,
                width: sequence.info.width,
                height: sequence.info.height,
                frames: sequence.frameCount()
            });
        }).catch(function(error) {
            self.postMessage({ type: 'failed', id: message.id, error: String(error && error.message) });
        });
        return;
    }

    if (message.type === 'next') {
        var target = sequences[message.id];
        if (target == null) return;

        try {
            var frame = target.next();
            if (frame == null) return;

            // Transfer the pixels rather than copying them across.
            self.postMessage({
                type: 'frame', id: message.id, index: frame.index,
                delay: frame.delay, width: frame.width, height: frame.height,
                rgba: frame.rgba.buffer
            }, [frame.rgba.buffer]);
        } catch (error) {
            self.postMessage({ type: 'failed', id: message.id, error: String(error && error.message) });
        }
        return;
    }

    if (message.type === 'release') {
        delete sequences[message.id];
    }
};
