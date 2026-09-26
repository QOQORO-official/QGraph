/*
 * GIF87a/89a decoder for the canvas engine.
 *
 * Relying on an <img> to animate itself does not work here: browsers throttle
 * or freeze animation for images that are not actually being rendered, and the
 * diagram never renders the element — it only samples it with drawImage. So the
 * frames are decoded explicitly and advanced on our own clock.
 *
 * The parse pass is deliberately cheap: it records where each frame's LZW data
 * lives rather than decoding it. Frames are then decoded one at a time, on
 * demand, so a 12 MB GIF costs one frame of work at a time instead of hundreds
 * of megabytes of decoded RGBA held at once.
 */
(function(root) {
    'use strict';

    var DISPOSAL_BACKGROUND = 2;
    var DISPOSAL_PREVIOUS = 3;

    function readSubBlockRanges(bytes, offset) {
        var ranges = [];

        while (offset < bytes.length) {
            var size = bytes[offset];
            offset++;
            if (size === 0) break;
            ranges.push([offset, offset + size]);
            offset += size;
        }

        return { ranges: ranges, end: offset };
    }

    function readPalette(bytes, offset, count) {
        var palette = new Uint8Array(count * 3);
        for (var i = 0; i < count * 3; i++) palette[i] = bytes[offset + i];
        return palette;
    }

    /* Walks the file structure without decompressing anything. */
    function parse(bytes) {
        if (bytes == null || bytes.length < 13) return null;
        if (!(bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46)) return null;

        var width = bytes[6] | (bytes[7] << 8);
        var height = bytes[8] | (bytes[9] << 8);
        var flags = bytes[10];
        var backgroundIndex = bytes[11];
        var offset = 13;
        var globalPalette = null;

        if (flags & 0x80) {
            var globalSize = 1 << ((flags & 0x07) + 1);
            globalPalette = readPalette(bytes, offset, globalSize);
            offset += globalSize * 3;
        }

        var frames = [];
        var loopCount = 0;
        var pending = { delay: 100, disposal: 0, transparent: -1 };

        while (offset < bytes.length) {
            var block = bytes[offset];

            if (block === 0x3B) break;                       // trailer

            if (block === 0x21) {                            // extension
                var label = bytes[offset + 1];
                offset += 2;

                if (label === 0xF9) {                        // graphic control
                    var size = bytes[offset];
                    var packed = bytes[offset + 1];
                    var delay = (bytes[offset + 2] | (bytes[offset + 3] << 8)) * 10;
                    pending = {
                        disposal: (packed >> 2) & 0x07,
                        transparent: (packed & 0x01) ? bytes[offset + 4] : -1,
                        // Browsers clamp absurdly fast GIFs the same way.
                        delay: delay < 20 ? 100 : delay
                    };
                    offset += size + 1;
                    offset = readSubBlockRanges(bytes, offset).end;
                } else {
                    if (label === 0xFF) {
                        var appBlockSize = bytes[offset];
                        var appName = '';
                        for (var a = 1; a <= 11 && a <= appBlockSize; a++) {
                            appName += String.fromCharCode(bytes[offset + a]);
                        }
                        var appData = readSubBlockRanges(bytes, offset + appBlockSize + 1);
                        if (appName.indexOf('NETSCAPE') === 0 && appData.ranges.length > 0) {
                            var start = appData.ranges[0][0];
                            loopCount = bytes[start + 1] | (bytes[start + 2] << 8);
                        }
                        offset = appData.end;
                    } else {
                        offset = readSubBlockRanges(bytes, offset).end;
                    }
                }
                continue;
            }

            if (block === 0x2C) {                            // image descriptor
                var frame = {
                    x: bytes[offset + 1] | (bytes[offset + 2] << 8),
                    y: bytes[offset + 3] | (bytes[offset + 4] << 8),
                    width: bytes[offset + 5] | (bytes[offset + 6] << 8),
                    height: bytes[offset + 7] | (bytes[offset + 8] << 8),
                    delay: pending.delay,
                    disposal: pending.disposal,
                    transparent: pending.transparent,
                    palette: globalPalette,
                    interlaced: false
                };

                var localFlags = bytes[offset + 9];
                frame.interlaced = (localFlags & 0x40) !== 0;
                offset += 10;

                if (localFlags & 0x80) {
                    var localSize = 1 << ((localFlags & 0x07) + 1);
                    frame.palette = readPalette(bytes, offset, localSize);
                    offset += localSize * 3;
                }

                frame.minCodeSize = bytes[offset];
                offset++;
                var data = readSubBlockRanges(bytes, offset);
                frame.ranges = data.ranges;
                offset = data.end;

                frames.push(frame);
                pending = { delay: 100, disposal: 0, transparent: -1 };
                continue;
            }

            offset++;                                        // skip junk
        }

        if (frames.length === 0) return null;

        return {
            width: width, height: height, frames: frames,
            loopCount: loopCount, backgroundIndex: backgroundIndex,
            globalPalette: globalPalette
        };
    }

    /* GIF variable-width LZW. */
    function decodeIndices(bytes, frame) {
        var length = 0;
        var r;
        for (r = 0; r < frame.ranges.length; r++) length += frame.ranges[r][1] - frame.ranges[r][0];

        var data = new Uint8Array(length);
        var cursor = 0;
        for (r = 0; r < frame.ranges.length; r++) {
            data.set(bytes.subarray(frame.ranges[r][0], frame.ranges[r][1]), cursor);
            cursor += frame.ranges[r][1] - frame.ranges[r][0];
        }

        var pixelCount = frame.width * frame.height;
        var output = new Uint8Array(pixelCount);
        var minCodeSize = frame.minCodeSize;
        var clearCode = 1 << minCodeSize;
        var endCode = clearCode + 1;
        var codeSize = minCodeSize + 1;
        var nextCode = endCode + 1;

        var maxEntries = 4096;
        var prefix = new Int32Array(maxEntries);
        var suffix = new Uint8Array(maxEntries);
        var pixelStack = new Uint8Array(maxEntries + 1);
        var i;
        for (i = 0; i < clearCode; i++) { prefix[i] = -1; suffix[i] = i; }

        var bitBuffer = 0;
        var bitCount = 0;
        var position = 0;
        var out = 0;
        var previous = -1;
        var top = 0;

        while (out < pixelCount) {
            if (bitCount < codeSize) {
                if (position >= data.length) break;
                bitBuffer |= data[position] << bitCount;
                bitCount += 8;
                position++;
                continue;
            }

            var code = bitBuffer & ((1 << codeSize) - 1);
            bitBuffer >>= codeSize;
            bitCount -= codeSize;

            if (code === clearCode) {
                codeSize = minCodeSize + 1;
                nextCode = endCode + 1;
                previous = -1;
                continue;
            }
            if (code === endCode) break;

            var current = code;
            if (code >= nextCode) {
                if (previous < 0) break;
                pixelStack[top++] = suffix[previous];
                current = previous;
            }

            while (current >= clearCode) {
                pixelStack[top++] = suffix[current];
                current = prefix[current];
                if (current < 0 || top > maxEntries) { current = 0; break; }
            }
            pixelStack[top++] = suffix[current] || 0;

            while (top > 0 && out < pixelCount) output[out++] = pixelStack[--top];

            if (previous >= 0 && nextCode < maxEntries) {
                prefix[nextCode] = previous;
                suffix[nextCode] = suffix[current] || 0;
                nextCode++;
                if ((nextCode & (nextCode - 1)) === 0 && nextCode < maxEntries) codeSize++;
            }

            previous = code;
        }

        return output;
    }

    var INTERLACE_STEPS = [[0, 8], [4, 8], [2, 4], [1, 2]];

    /* Writes one frame's pixels into a full-canvas RGBA buffer. */
    function composite(rgba, canvasWidth, frame, indices) {
        var palette = frame.palette;
        if (palette == null) return;

        var rows = [];
        var y;

        if (frame.interlaced) {
            for (var p = 0; p < INTERLACE_STEPS.length; p++) {
                for (y = INTERLACE_STEPS[p][0]; y < frame.height; y += INTERLACE_STEPS[p][1]) rows.push(y);
            }
        } else {
            for (y = 0; y < frame.height; y++) rows.push(y);
        }

        for (var r = 0; r < rows.length; r++) {
            var sourceRow = r;
            var targetRow = rows[r];

            for (var x = 0; x < frame.width; x++) {
                var index = indices[sourceRow * frame.width + x];
                if (index === frame.transparent) continue;

                var target = ((frame.y + targetRow) * canvasWidth + (frame.x + x)) * 4;
                if (target < 0 || target + 3 >= rgba.length) continue;

                rgba[target] = palette[index * 3];
                rgba[target + 1] = palette[index * 3 + 1];
                rgba[target + 2] = palette[index * 3 + 2];
                rgba[target + 3] = 255;
            }
        }
    }

    function clearRect(rgba, canvasWidth, frame) {
        for (var y = 0; y < frame.height; y++) {
            for (var x = 0; x < frame.width; x++) {
                var target = ((frame.y + y) * canvasWidth + (frame.x + x)) * 4;
                if (target < 0 || target + 3 >= rgba.length) continue;
                rgba[target] = 0;
                rgba[target + 1] = 0;
                rgba[target + 2] = 0;
                rgba[target + 3] = 0;
            }
        }
    }

    /* Sequential player: holds the composited canvas and steps through frames,
       honouring the disposal method between them. */
    function GifSequence(bytes) {
        this.bytes = bytes;
        this.info = parse(bytes);
        this.index = -1;

        if (this.info != null) {
            this.rgba = new Uint8ClampedArray(this.info.width * this.info.height * 4);
            this.previous = null;
        }
    }

    GifSequence.prototype.valid = function() {
        return this.info != null && this.info.frames.length > 0;
    };

    GifSequence.prototype.frameCount = function() {
        return this.valid() ? this.info.frames.length : 0;
    };

    /* Advances to the next frame and returns its RGBA buffer plus delay. */
    GifSequence.prototype.next = function() {
        if (!this.valid()) return null;

        var count = this.info.frames.length;
        var nextIndex = (this.index + 1) % count;
        var frame = this.info.frames[nextIndex];

        // Looping restarts from a clean canvas.
        if (nextIndex === 0) this.rgba.fill(0);

        if (frame.disposal === DISPOSAL_PREVIOUS) this.previous = this.rgba.slice(0);
        composite(this.rgba, this.info.width, frame, decodeIndices(this.bytes, frame));

        var result = {
            index: nextIndex,
            delay: frame.delay,
            width: this.info.width,
            height: this.info.height,
            rgba: this.rgba.slice(0)
        };

        // Apply the disposal for the frame we just showed, ready for the next.
        if (frame.disposal === DISPOSAL_BACKGROUND) clearRect(this.rgba, this.info.width, frame);
        else if (frame.disposal === DISPOSAL_PREVIOUS && this.previous != null) this.rgba.set(this.previous);

        this.index = nextIndex;
        return result;
    };

    root.PixelGifDecoder = {
        parse: parse,
        decodeIndices: decodeIndices,
        GifSequence: GifSequence
    };
})(typeof self !== 'undefined' ? self : this);
