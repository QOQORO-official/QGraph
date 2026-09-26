/*
 * Main-thread side of GIF playback.
 *
 * Holds one player per animated source. Each player keeps the current frame on
 * a small canvas that the scene painter draws instead of the <img>, and asks
 * the decode worker for the next frame when the current frame's delay is up.
 *
 * Everything is driven by our own clock rather than the browser's image
 * animation, which is unreliable for pictures that are never rendered as
 * elements — the diagram only ever samples them through drawImage.
 */
(function(root) {
    'use strict';

    var nextId = 0;

    function GifPlayback(options) {
        options = options || {};
        this.workerUrl = options.workerUrl || 'js/gif-worker.js';
        this.onFrame = options.onFrame || function() {};
        this.players = new Map();
        this.byId = Object.create(null);
        this.worker = null;
        this.failed = false;
    }

    GifPlayback.prototype.ensureWorker = function() {
        if (this.worker != null || this.failed) return this.worker;

        try {
            this.worker = new Worker(this.workerUrl);
            this.worker.onmessage = this.onMessage.bind(this);
            this.worker.onerror = function() { this.failed = true; }.bind(this);
        } catch (error) {
            this.failed = true;
            this.worker = null;
        }

        return this.worker;
    };

    /* Starts decoding a source. The worker fetches or decodes it itself, so a
       multi-megabyte data URI never touches the main thread. */
    GifPlayback.prototype.add = function(src) {
        if (this.players.has(src)) return this.players.get(src);
        var worker = this.ensureWorker();
        if (worker == null) return null;

        var id = 'gif-' + (++nextId);
        var player = {
            id: id, src: src, canvas: null, context: null,
            ready: false, waiting: true, dueAt: 0, delay: 100, frames: 0
        };

        this.players.set(src, player);
        this.byId[id] = player;
        worker.postMessage({ type: 'load', id: id, src: src });
        return player;
    };

    GifPlayback.prototype.get = function(src) {
        return this.players.get(src) || null;
    };

    /* The canvas holding the current frame, or null until the first arrives. */
    GifPlayback.prototype.frameFor = function(src) {
        var player = this.players.get(src);
        return (player != null && player.ready) ? player.canvas : null;
    };

    GifPlayback.prototype.onMessage = function(event) {
        var message = event.data || {};
        var player = this.byId[message.id];
        if (player == null) return;

        if (message.type === 'failed') {
            this.players.delete(player.src);
            delete this.byId[message.id];
            return;
        }

        if (message.type === 'loaded') {
            player.frames = message.frames;
            player.canvas = document.createElement('canvas');
            player.canvas.width = message.width;
            player.canvas.height = message.height;
            player.context = player.canvas.getContext('2d');
            player.waiting = true;
            this.worker.postMessage({ type: 'next', id: player.id });
            return;
        }

        if (message.type === 'frame') {
            var pixels = new Uint8ClampedArray(message.rgba);

            if (player.context != null) {
                player.context.putImageData(
                    new ImageData(pixels, message.width, message.height), 0, 0);
            }

            player.delay = message.delay;
            player.dueAt = (root.performance ? performance.now() : Date.now()) + message.delay;
            player.ready = true;
            player.waiting = false;
            this.onFrame(player.src);
        }
    };

    /* Requests the next frame for any player whose delay has elapsed.
       Returns true when at least one player is running. */
    GifPlayback.prototype.tick = function(now) {
        if (this.players.size === 0) return false;
        now = now || (root.performance ? performance.now() : Date.now());
        var worker = this.worker;
        var running = false;

        this.players.forEach(function(player) {
            running = true;
            if (player.waiting || worker == null) return;
            if (player.frames <= 1) return;
            if (now < player.dueAt) return;
            player.waiting = true;
            worker.postMessage({ type: 'next', id: player.id });
        });

        return running;
    };

    GifPlayback.prototype.remove = function(src) {
        var player = this.players.get(src);
        if (player == null) return;
        this.players.delete(src);
        delete this.byId[player.id];
        if (this.worker != null) this.worker.postMessage({ type: 'release', id: player.id });
    };

    GifPlayback.prototype.destroy = function() {
        if (this.worker != null) this.worker.terminate();
        this.worker = null;
        this.players.clear();
        this.byId = Object.create(null);
    };

    root.GifPlayback = GifPlayback;
})(typeof self !== 'undefined' ? self : this);
