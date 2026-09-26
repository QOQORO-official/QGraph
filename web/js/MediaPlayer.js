/* Main-thread media playback and worker-backed source preparation.
 *
 * Video frames must ultimately be sampled from an HTMLVideoElement, but
 * embedded files do not need to be base64-decoded on the UI thread. The
 * bridge below asks media-worker.js to encode selected files and to turn
 * embedded video data URIs into Blob objects. Remote MP4/WebM sources stay as
 * URLs so the browser can stream and buffer them normally.
 */
(function(root) {
    'use strict';

    var nextRequestId = 0;

    function youtubeId(src) {
        var value = String(src || '').trim();
        if (!value) return '';
        try {
            var url = new URL(value, typeof location !== 'undefined' ? location.href : undefined);
            var host = url.hostname.replace(/^www\./i, '').toLowerCase();
            var id = '';
            if (host === 'youtu.be') id = url.pathname.split('/').filter(Boolean)[0] || '';
            else if (host === 'youtube.com' || host === 'm.youtube.com' ||
                host === 'music.youtube.com' || host === 'youtube-nocookie.com') {
                if (url.pathname === '/watch') id = url.searchParams.get('v') || '';
                else {
                    var match = /^\/(?:embed|shorts|live)\/([^/?#]+)/i.exec(url.pathname);
                    if (match) id = match[1];
                }
            }
            return /^[A-Za-z0-9_-]{6,15}$/.test(id) ? id : '';
        } catch (error) {
            return '';
        }
    }

    function youtubeStart(src) {
        try {
            var url = new URL(String(src || ''), typeof location !== 'undefined' ? location.href : undefined);
            var value = url.searchParams.get('start') || url.searchParams.get('t') ||
                new URLSearchParams(String(url.hash || '').replace(/^#/, '')).get('t') || '';
            if (/^\d+(?:\.\d+)?$/.test(value)) return Math.max(0, Math.floor(Number(value)));
            var total = 0;
            var match;
            var pattern = /(\d+(?:\.\d+)?)(h|m|s)/ig;
            while ((match = pattern.exec(value))) {
                total += Number(match[1]) * (match[2].toLowerCase() === 'h' ? 3600 :
                    (match[2].toLowerCase() === 'm' ? 60 : 1));
            }
            return Math.max(0, Math.floor(total));
        } catch (error) {
            return 0;
        }
    }

    function mediaTypeFor(src, explicitType) {
        var type = String(explicitType || '').toLowerCase();
        // An explicit image type is conclusive. In particular, never feed a
        // multi-megabyte GIF data URI into URL/YouTube parsing on every paint.
        if (/^image(?:\/|$)/.test(type) || type === 'image') return '';
        if (type === 'video/youtube') return 'video/youtube';
        if (/^video\/(mp4|webm)/.test(type)) return type;
        var value = String(src || '');
        // MIME classification only needs the short data-URI header. Slicing
        // avoids regex engines walking/copying the complete embedded payload.
        var head = value.slice(0, 128);
        var match = /^data:(video\/(?:mp4|webm))/i.exec(head);
        if (match) return match[1].toLowerCase();
        if (/^data:/i.test(head)) return '';
        if (youtubeId(value)) return 'video/youtube';
        if (/\.webm(?:[?#]|$)/i.test(value)) return 'video/webm';
        if (/\.mp4(?:[?#]|$)/i.test(value)) return 'video/mp4';
        return /^video\//.test(type) ? type : '';
    }

    function isVideoSource(src, explicitType) {
        return mediaTypeFor(src, explicitType) !== '';
    }

    function fallbackRead(file) {
        return new Promise(function(resolve, reject) {
            var reader = new FileReader();
            reader.onload = function() { resolve(String(reader.result || '')); };
            reader.onerror = function() { reject(reader.error || new Error('Could not read media file')); };
            reader.readAsDataURL(file);
        });
    }

    function MediaWorkerBridge(workerUrl) {
        this.workerUrl = workerUrl || 'js/media-worker.js';
        this.worker = null;
        this.failed = false;
        this.pending = Object.create(null);
    }

    MediaWorkerBridge.prototype.ensureWorker = function() {
        if (this.worker != null || this.failed || typeof Worker === 'undefined') return this.worker;
        try {
            this.worker = new Worker(this.workerUrl);
            this.worker.onmessage = function(event) {
                var message = event.data || {};
                var pending = this.pending[message.id];
                if (!pending) return;
                delete this.pending[message.id];
                if (message.error) pending.reject(new Error(message.error));
                else pending.resolve(message.value);
            }.bind(this);
            this.worker.onerror = function() { this.failed = true; }.bind(this);
        } catch (error) {
            this.failed = true;
            this.worker = null;
        }
        return this.worker;
    };

    MediaWorkerBridge.prototype.request = function(type, value) {
        var worker = this.ensureWorker();
        if (worker == null) return Promise.reject(new Error('Media worker unavailable'));
        var id = 'media-' + (++nextRequestId);
        return new Promise(function(resolve, reject) {
            this.pending[id] = { resolve: resolve, reject: reject };
            worker.postMessage({ id: id, type: type, value: value });
        }.bind(this));
    };

    MediaWorkerBridge.prototype.encodeFile = function(file) {
        return this.request('encode', file).catch(function() { return fallbackRead(file); });
    };

    MediaWorkerBridge.prototype.bufferSource = function(src) {
        return this.request('buffer', src).catch(function() {
            return fetch(src).then(function(response) { return response.blob(); });
        });
    };

    MediaWorkerBridge.prototype.destroy = function() {
        if (this.worker != null) this.worker.terminate();
        this.worker = null;
        this.pending = Object.create(null);
    };

    var sharedBridge = new MediaWorkerBridge();

    function holder() {
        if (typeof document === 'undefined') return null;
        var element = document.getElementById('pixel-media-holder');
        if (element == null) {
            element = document.createElement('div');
            element.id = 'pixel-media-holder';
            element.setAttribute('aria-hidden', 'true');
            element.style.cssText = 'position:absolute;width:1px;height:1px;overflow:hidden;' +
                'opacity:0;pointer-events:none;left:-9999px;top:0;';
            document.body.appendChild(element);
        }
        return element;
    }

    function MediaPlayback(options) {
        options = options || {};
        this.bridge = options.bridge || sharedBridge;
        this.onFrame = options.onFrame || function() {};
        this.players = new Map();
    }

    MediaPlayback.prototype.add = function(src, explicitType, loop) {
        if (!isVideoSource(src, explicitType) || youtubeId(src) || typeof document === 'undefined') return null;
        var existing = this.players.get(src);
        if (existing) {
            existing.video.loop = loop !== false;
            return existing;
        }

        var self = this;
        var video = document.createElement('video');
        var player = {
            src: src, type: mediaTypeFor(src, explicitType), video: video,
            ready: false, failed: false, objectUrl: null
        };
        this.players.set(src, player);

        video.preload = 'auto';
        video.muted = true;
        video.defaultMuted = true;
        video.loop = loop !== false;
        video.autoplay = true;
        video.playsInline = true;
        video.setAttribute('playsinline', '');
        video.style.cssText = 'position:absolute;width:1px;height:1px;';
        var parking = holder();
        if (parking) parking.appendChild(video);

        function wake() {
            player.ready = video.readyState >= 2 && video.videoWidth > 0;
            if (player.ready) {
                var promise = video.play();
                if (promise && typeof promise.catch === 'function') promise.catch(function() {});
            }
            self.onFrame(src);
        }
        video.addEventListener('loadedmetadata', wake);
        video.addEventListener('loadeddata', wake);
        video.addEventListener('canplay', wake);
        video.addEventListener('seeked', wake);
        video.addEventListener('error', function() {
            player.failed = true;
            self.onFrame(src);
        });

        function assign(source) {
            video.src = source;
            video.load();
        }

        // Embedded videos are converted to a Blob in a worker before the
        // video element sees them. This avoids synchronous base64 decoding on
        // the editor thread and lets the browser buffer the resulting Blob.
        if (/^data:/i.test(src)) {
            this.bridge.bufferSource(src).then(function(blob) {
                if (!self.players.has(src)) return;
                player.objectUrl = URL.createObjectURL(blob);
                assign(player.objectUrl);
            }).catch(function() {
                // A direct data URI remains a safe fallback in older browsers.
                assign(src);
            });
        } else {
            // HTTP(S) sources are deliberately not fetched into memory: the
            // native media pipeline can range-request and stream them.
            if (!/^blob:/i.test(src)) video.crossOrigin = 'anonymous';
            assign(src);
        }
        return player;
    };

    MediaPlayback.prototype.frameFor = function(src, explicitType, loop) {
        var player = this.players.get(src) || this.add(src, explicitType, loop);
        if (!player || !player.ready || player.failed) return null;
        player.video.loop = loop !== false;
        return player.video;
    };

    MediaPlayback.prototype.stateFor = function(src) {
        return this.players.get(src) || null;
    };

    MediaPlayback.prototype.remove = function(src) {
        var player = this.players.get(src);
        if (!player) return;
        this.players.delete(src);
        player.video.pause();
        player.video.removeAttribute('src');
        player.video.load();
        player.video.remove();
        if (player.objectUrl) URL.revokeObjectURL(player.objectUrl);
    };

    MediaPlayback.prototype.retain = function(items) {
        var keep = new Set();
        (items || []).forEach(function(item) {
            if (item && item.src && isVideoSource(item.src, item.mediaType)) keep.add(item.src);
            // Parallax layers can carry their own video sources.
            (item && Array.isArray(item.mediaLayers) ? item.mediaLayers : []).forEach(function(layer) {
                if (layer && layer.src && isVideoSource(layer.src, layer.mediaType)) keep.add(layer.src);
            });
        });
        Array.from(this.players.keys()).forEach(function(src) {
            // Blob preview sources belong to an open dialog and are removed
            // by that dialog, not by scene synchronization.
            if (!keep.has(src) && !/^blob:/i.test(src)) this.remove(src);
        }, this);
    };

    MediaPlayback.prototype.destroy = function() {
        Array.from(this.players.keys()).forEach(this.remove.bind(this));
    };

    function formatTime(seconds) {
        seconds = Math.max(0, Math.floor(Number(seconds) || 0));
        var hours = Math.floor(seconds / 3600);
        var minutes = Math.floor((seconds % 3600) / 60);
        var secs = seconds % 60;
        return (hours ? hours + ':' + String(minutes).padStart(2, '0') : String(minutes)) +
            ':' + String(secs).padStart(2, '0');
    }

    function parseTime(value) {
        var parts = String(value || '').trim().split(':').map(Number);
        if (parts.some(function(part) { return !isFinite(part) || part < 0; })) return null;
        if (parts.length === 1) return parts[0];
        if (parts.length === 2) return parts[0] * 60 + parts[1];
        if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
        return null;
    }

    function MediaOverlayManager(options) {
        options = options || {};
        this.graph = options.graph;
        this.layer = options.layer;
        this.records = new Map();
        this.boundMessage = this.onMessage.bind(this);
        if (typeof window !== 'undefined') window.addEventListener('message', this.boundMessage);
    }

    MediaOverlayManager.prototype.postYouTube = function(record, func, args) {
        if (!record || !record.frame || !record.frame.contentWindow) return;
        record.frame.contentWindow.postMessage(JSON.stringify({
            event: 'command', func: func, args: args || []
        }), '*');
    };

    MediaOverlayManager.prototype.onMessage = function(event) {
        var data = event.data;
        if (typeof data === 'string') {
            try { data = JSON.parse(data); } catch (error) { return; }
        }
        if (!data || (data.event !== 'infoDelivery' && data.event !== 'onStateChange')) return;
        this.records.forEach(function(record) {
            if (!record.youtube || !record.frame || event.source !== record.frame.contentWindow) return;
            var info = data.info || {};
            if (info.duration != null) record.duration = Number(info.duration) || 0;
            if (info.currentTime != null) record.currentTime = Number(info.currentTime) || 0;
            if (info.volume != null) {
                record.volume.value = Math.max(0, Math.min(100, Number(info.volume) || 0));
            }
            if (info.playerState != null) record.playing = Number(info.playerState) === 1;
            if (typeof data.info === 'number') {
                var state = Number(data.info);
                record.playing = state === 1;
                var item = this.graph && this.graph.byId[record.id];
                if (state === 0 && item && item.mediaLoop !== false) {
                    this.postYouTube(record, 'seekTo', [0, true]);
                    this.postYouTube(record, 'playVideo');
                }
            }
            this.updateControls(record);
        }, this);
    };

    MediaOverlayManager.prototype.updateControls = function(record) {
        var duration = Math.max(0, Number(record.duration) || 0);
        var current = Math.max(0, Math.min(duration || Infinity, Number(record.currentTime) || 0));
        var playText = record.playing ? '❚❚' : '▶';
        var playTitle = record.playing ? 'Pause' : 'Play';
        var currentText = formatTime(current);
        var durationText = '/ ' + formatTime(duration);
        if (record.playButton.textContent !== playText) record.playButton.textContent = playText;
        if (record.playButton.title !== playTitle) record.playButton.title = playTitle;
        if (record.seek.max !== String(duration || 0)) record.seek.max = duration || 0;
        if (record.seek.value !== String(current)) record.seek.value = current;
        if (document.activeElement !== record.timeInput && record.timeInput.value !== currentText) {
            record.timeInput.value = currentText;
        }
        if (record.durationLabel.textContent !== durationText) {
            record.durationLabel.textContent = durationText;
        }
    };

    MediaOverlayManager.prototype.createRecord = function(node) {
        var self = this;
        var record = {
            id: node.id, src: node.src, mediaType: mediaTypeFor(node.src, node.mediaType),
            youtube: youtubeId(node.src) !== '', duration: 0, currentTime: 0,
            playing: false, objectUrl: null,
            nodeVolume: Math.max(0, Math.min(1, node.mediaVolume == null ? 1 : node.mediaVolume))
        };
        var wrapper = document.createElement('div');
        wrapper.className = 'pixel-media-overlay';
        wrapper.dataset.nodeId = node.id;
        var visual = document.createElement('div');
        visual.className = 'pixel-media-visual';
        var controls = document.createElement('div');
        controls.className = 'pixel-media-controls';
        wrapper.appendChild(visual);
        wrapper.appendChild(controls);
        this.layer.appendChild(wrapper);
        record.wrapper = wrapper;
        record.visual = visual;
        record.controls = controls;

        function control(tag, className, title) {
            var element = document.createElement(tag);
            element.className = className;
            if (title) element.title = title;
            controls.appendChild(element);
            return element;
        }
        record.playButton = control('button', 'pixel-media-button pixel-media-play', 'Play');
        record.stopButton = control('button', 'pixel-media-button', 'Stop and return to 00:00');
        record.stopButton.textContent = '■';
        record.seek = control('input', 'pixel-media-seek', 'Playback position');
        record.seek.type = 'range'; record.seek.min = 0; record.seek.max = 0; record.seek.step = .1;
        record.timeInput = control('input', 'pixel-media-time', 'Jump to time, for example 02:12');
        record.timeInput.type = 'text'; record.timeInput.value = '0:00';
        record.durationLabel = control('span', 'pixel-media-duration');
        record.durationLabel.textContent = '/ 0:00';
        record.volumeIcon = control('span', 'pixel-media-volume-icon');
        record.volumeIcon.textContent = '🔊';
        record.volume = control('input', 'pixel-media-volume', 'Volume');
        record.volume.type = 'range'; record.volume.min = 0; record.volume.max = 100; record.volume.step = 1;
        record.volume.value = Math.round((node.mediaVolume == null ? 1 : node.mediaVolume) * 100);
        record.fullscreenButton = control('button', 'pixel-media-button', 'Fullscreen');
        record.fullscreenButton.textContent = '⛶';

        controls.addEventListener('pointerdown', function(event) {
            event.stopPropagation();
            if (self.graph && self.graph.setSelection) self.graph.setSelection([record.id]);
        });
        controls.addEventListener('dblclick', function(event) { event.stopPropagation(); });

        record.playButton.addEventListener('click', function(event) {
            event.stopPropagation();
            if (record.youtube) {
                self.postYouTube(record, record.playing ? 'pauseVideo' : 'playVideo');
                record.playing = !record.playing;
            } else if (record.video) {
                if (record.video.paused) {
                    var promise = record.video.play();
                    if (promise && promise.catch) promise.catch(function() {});
                } else record.video.pause();
            }
            self.updateControls(record);
        });
        record.stopButton.addEventListener('click', function(event) {
            event.stopPropagation();
            if (record.youtube) {
                self.postYouTube(record, 'stopVideo');
                self.postYouTube(record, 'seekTo', [0, true]);
                record.currentTime = 0; record.playing = false;
            } else if (record.video) {
                record.video.pause();
                try { record.video.currentTime = 0; } catch (error) {}
            }
            self.updateControls(record);
        });
        function seekTo(seconds) {
            seconds = Math.max(0, Math.min(record.duration || Infinity, Number(seconds) || 0));
            if (record.youtube) self.postYouTube(record, 'seekTo', [seconds, true]);
            else if (record.video) {
                try { record.video.currentTime = seconds; } catch (error) {}
            }
            record.currentTime = seconds;
            self.updateControls(record);
        }
        record.seek.addEventListener('input', function() { seekTo(record.seek.value); });
        record.timeInput.addEventListener('change', function() {
            var seconds = parseTime(record.timeInput.value);
            if (seconds != null) seekTo(seconds);
            else self.updateControls(record);
        });
        record.timeInput.addEventListener('keydown', function(event) {
            if (event.key === 'Enter') { record.timeInput.blur(); event.stopPropagation(); }
        });
        record.volume.addEventListener('input', function() {
            var value = Math.max(0, Math.min(100, Number(record.volume.value) || 0));
            if (record.youtube) {
                self.postYouTube(record, 'setVolume', [value]);
                self.postYouTube(record, value === 0 ? 'mute' : 'unMute');
            } else if (record.video) {
                record.video.muted = value === 0;
                record.video.volume = value / 100;
            }
            record.volumeIcon.textContent = value === 0 ? '🔇' : (value < 50 ? '🔉' : '🔊');
            var item = self.graph && self.graph.byId[record.id];
            if (item) item.mediaVolume = value / 100;
            record.nodeVolume = value / 100;
        });
        record.volume.addEventListener('pointerdown', function() {
            record.volumeBefore = self.graph && self.graph.snapshot ? self.graph.snapshot() : null;
        });
        record.volume.addEventListener('change', function() {
            if (self.graph && self.graph.commit) {
                self.graph.commit(record.volumeBefore, 'Media Volume');
                record.volumeBefore = null;
            }
        });
        record.fullscreenButton.addEventListener('click', function(event) {
            event.stopPropagation();
            // A canvas-composited (native) video has a transparent wrapper, so
            // fullscreen the parked video element itself; YouTube keeps the
            // wrapper (its iframe fills it).
            var target = record.canvasComposited && record.video ? record.video : wrapper;
            var request = target.requestFullscreen || target.webkitRequestFullscreen;
            if (request) request.call(target);
        });

        if (record.youtube) this.createYouTube(record, node);
        else this.createNative(record, node);
        this.updateControls(record);
        this.records.set(node.id, record);
        return record;
    };

    MediaOverlayManager.prototype.createYouTube = function(record, node) {
        var self = this;
        var frame = document.createElement('iframe');
        var id = youtubeId(node.src);
        var start = youtubeStart(node.src);
        record.currentTime = start;
        var origin = typeof location !== 'undefined' && /^https?:/.test(location.origin) ?
            '&origin=' + encodeURIComponent(location.origin) : '';
        frame.className = 'pixel-media-frame';
        frame.allow = 'autoplay; encrypted-media; picture-in-picture; fullscreen';
        frame.setAttribute('allowfullscreen', '');
        frame.referrerPolicy = 'strict-origin-when-cross-origin';
        frame.src = 'https://www.youtube-nocookie.com/embed/' + encodeURIComponent(id) +
            '?enablejsapi=1&controls=0&playsinline=1&rel=0&modestbranding=1' +
            (start ? '&start=' + start : '') + origin;
        frame.addEventListener('load', function() {
            frame.contentWindow.postMessage(JSON.stringify({ event: 'listening', id: record.id }), '*');
            self.postYouTube(record, 'setVolume', [Number(record.volume.value) || 100]);
            self.postYouTube(record, 'addEventListener', ['onStateChange']);
        });
        record.frame = frame;
        record.visual.appendChild(frame);
    };

    MediaOverlayManager.prototype.createNative = function(record, node) {
        var self = this;
        var player = this.graph && this.graph.mediaPlayback ?
            this.graph.mediaPlayback.add(node.src, node.mediaType, node.mediaLoop) : null;
        var video = player ? player.video : document.createElement('video');
        record.video = video;
        // The scene painter samples this video's frames straight into the
        // canvas in the node's z-order, so other objects can be arranged in
        // front of it. The element therefore stays parked in the hidden
        // holder and this overlay only floats the transparent control bar
        // over the node. (YouTube keeps a full iframe overlay — a
        // cross-origin frame can never be canvas-composited.)
        record.canvasComposited = true;
        record.wrapper.classList.add('pixel-media-canvas');
        video.controls = false;
        video.loop = node.mediaLoop !== false;
        video.playsInline = true;
        video.volume = Math.max(0, Math.min(1, node.mediaVolume == null ? 1 : node.mediaVolume));
        video.muted = video.volume === 0;

        if (!player) {
            // No shared playback pipeline: park a private decoder so the
            // painter can still sample its frames.
            record.ownsVideo = true;
            video.style.cssText = 'position:absolute;width:1px;height:1px;';
            var parking = holder();
            if (parking) parking.appendChild(video);
            video.preload = 'auto';
            video.autoplay = true;
            if (/^data:/i.test(node.src)) {
                sharedBridge.bufferSource(node.src).then(function(blob) {
                    if (!self.records.has(record.id) && !record.wrapper.isConnected) return;
                    record.objectUrl = URL.createObjectURL(blob);
                    video.src = record.objectUrl; video.load();
                });
            } else {
                video.src = node.src; video.load();
            }
        }
        function update() {
            record.duration = isFinite(video.duration) ? video.duration : 0;
            record.currentTime = video.currentTime || 0;
            record.playing = !video.paused && !video.ended;
            self.updateControls(record);
        }
        ['loadedmetadata', 'durationchange', 'timeupdate', 'play', 'pause', 'ended', 'seeked']
            .forEach(function(name) { video.addEventListener(name, update); });
    };

    MediaOverlayManager.prototype.destroyRecord = function(record) {
        if (!record) return;
        if (record.objectUrl) URL.revokeObjectURL(record.objectUrl);
        if (record.youtube && record.frame) record.frame.src = 'about:blank';
        // Shared players are reclaimed by MediaPlayback.retain; only a
        // privately parked decoder is removed here.
        if (record.ownsVideo && record.video) {
            record.video.pause();
            record.video.removeAttribute('src');
            record.video.load();
            record.video.remove();
        }
        record.wrapper.remove();
        this.records.delete(record.id);
    };

    MediaOverlayManager.prototype.sync = function(items, view) {
        if (!this.layer) return;
        var graph = this.graph;
        var keep = new Set();
        var hidden = new Set((view && view.hiddenLayers) || []);
        (items || []).forEach(function(node, index) {
            // Parallax-layered nodes composite their whole stack on the canvas;
            // a DOM overlay would hide every layer beneath the base video.
            if (!node || node.type === 'edge' || !node.src ||
                (Array.isArray(node.mediaLayers) && node.mediaLayers.length > 0) ||
                !isVideoSource(node.src, node.mediaType)) return;
            keep.add(node.id);
            var record = this.records.get(node.id);
            var type = mediaTypeFor(node.src, node.mediaType);
            if (!record || record.src !== node.src || record.mediaType !== type) {
                if (record) this.destroyRecord(record);
                record = this.createRecord(node);
            }
            var visible = node.visible !== false && !node.foldedAway && !hidden.has(node.layer);
            if (record.wrapper.hidden === visible) record.wrapper.hidden = !visible;
            if (!visible) return;
            var zoom = graph.zoom || 1;
            var selected = graph.selection && graph.selection.indexOf(node.id) >= 0;
            var left = (node.x + (graph.worldOriginX || 0)) * zoom;
            var top = (node.y + (graph.worldOriginY || 0)) * zoom;
            var width = Math.max(24, node.width * zoom);
            var height = Math.max(24, node.height * zoom);
            var rotation = Number(node.rotation) || 0;
            var zIndex = Math.max(0, Number(node.z) || index);
            var layoutKey = [left, top, width, height, rotation, zIndex,
                selected ? 1 : 0, width < 360 ? 1 : 0, width < 245 ? 1 : 0].join('|');
            if (record.layoutKey !== layoutKey) {
                record.layoutKey = layoutKey;
                record.wrapper.style.left = left + 'px';
                record.wrapper.style.top = top + 'px';
                record.wrapper.style.width = width + 'px';
                record.wrapper.style.height = height + 'px';
                record.wrapper.style.transform = 'rotate(' + rotation + 'deg)';
                record.wrapper.style.zIndex = String(zIndex);
                record.wrapper.classList.toggle('pixel-media-selected', selected);
                record.wrapper.classList.toggle('pixel-media-compact', width < 360);
                record.wrapper.classList.toggle('pixel-media-tiny', width < 245);
            }
            var nodeVolume = Math.max(0, Math.min(1,
                node.mediaVolume == null ? 1 : Number(node.mediaVolume)));
            if (Math.abs(nodeVolume - record.nodeVolume) > .001) {
                record.nodeVolume = nodeVolume;
                record.volume.value = Math.round(nodeVolume * 100);
                record.volumeIcon.textContent = nodeVolume === 0 ? '🔇' :
                    (nodeVolume < .5 ? '🔉' : '🔊');
                if (record.youtube) {
                    this.postYouTube(record, 'setVolume', [Math.round(nodeVolume * 100)]);
                    this.postYouTube(record, nodeVolume === 0 ? 'mute' : 'unMute');
                } else if (record.video) {
                    record.video.volume = nodeVolume;
                    record.video.muted = nodeVolume === 0;
                }
            }
            if (record.video) {
                record.video.loop = node.mediaLoop !== false;
                // Fit/align/opacity are applied by the scene painter when it
                // samples the video into the canvas, so no element styles are
                // needed here.
            }
        }, this);
        Array.from(this.records.values()).forEach(function(record) {
            if (!keep.has(record.id)) this.destroyRecord(record);
        }, this);
    };

    MediaOverlayManager.prototype.destroy = function() {
        Array.from(this.records.values()).forEach(this.destroyRecord.bind(this));
        if (typeof window !== 'undefined') window.removeEventListener('message', this.boundMessage);
        if (this.layer) this.layer.remove();
    };

    root.PixelMedia = {
        typeFor: mediaTypeFor,
        isVideo: isVideoSource,
        isYouTube: function(src) { return youtubeId(src) !== ''; },
        youtubeId: youtubeId,
        encodeFile: function(file) { return sharedBridge.encodeFile(file); },
        bufferSource: function(src) { return sharedBridge.bufferSource(src); }
    };
    root.MediaPlayback = MediaPlayback;
    root.MediaOverlayManager = MediaOverlayManager;
})(typeof self !== 'undefined' ? self : this);
