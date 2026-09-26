/* Worker used by Edit Media and video playback. It keeps large base64/file
 * conversion away from form controls and the main editor event loop. */
'use strict';

self.onmessage = function(event) {
    var message = event.data || {};

    try {
        if (message.type === 'encode') {
            var reader = new FileReaderSync();
            self.postMessage({ id: message.id, value: reader.readAsDataURL(message.value) });
            return;
        }

        if (message.type === 'buffer') {
            fetch(message.value).then(function(response) {
                if (!response.ok && response.status !== 0) throw new Error('Media source returned ' + response.status);
                return response.blob();
            }).then(function(blob) {
                self.postMessage({ id: message.id, value: blob });
            }).catch(function(error) {
                self.postMessage({ id: message.id, error: error.message || String(error) });
            });
            return;
        }

        self.postMessage({ id: message.id, error: 'Unknown media worker request' });
    } catch (error) {
        self.postMessage({ id: message.id, error: error.message || String(error) });
    }
};
