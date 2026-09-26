// QGraph Luau runtime worker.
//
// Runs Luau programs on the Luau VM from luau-web (Luau compiled to
// WebAssembly), off the page's main thread. The worker is deliberately
// generic: it knows nothing about diagrams. A program reaches the editor only
// through four globals, and the page (the Nim application) answers:
//
//   __log(level, text)        console output, level "print" | "warn" | "info"
//   __host(op, argsJson)      a document operation; yields until the page
//                             replies with a JSON envelope string
//   __sleep(seconds)          yields for a while
//   __now()                   milliseconds since the worker started
//
// Messages are JSON strings in both directions:
//   page -> worker  {t:"run", run, chunks:[{name, source}]}
//                   {t:"reply", id, json}
//   worker -> page  {t:"ready", engine} | {t:"fail", error}
//                   {t:"log", run, level, text}
//                   {t:"req", run, id, op, args}
//                   {t:"done", run, ok, error, chunk}
//
// A worker runs one program. Stopping one terminates the worker; the page
// keeps a fresh worker ready for the next run.

// luau-web picks its JSPI build whenever the browser has JSPI, but in that
// build a Luau error inside pcall escapes to the caller. Hide JSPI while the
// package loads so it takes the Asyncify build, which handles pcall, xpcall
// and errors after a yield correctly.
const jspi = Object.getOwnPropertyDescriptor(WebAssembly, 'Suspending');
if (jspi) delete WebAssembly.Suspending;
const { LuauState } = await import('./luau-web-1.4.0/index.js');
if (jspi) Object.defineProperty(WebAssembly, 'Suspending', jspi);

// The Asyncify build was compiled for pages only and aborts when it detects
// a worker. Detection runs once, while the VM starts, and only looks at
// `window` and `WorkerGlobalScope`; the module embeds its wasm, so nothing
// page-specific is used. Present a page-like global for that moment.
//
// Each worker owns exactly one Luau state and runs one program: luau-web
// mixes up states created after another one was destroyed, so a fresh run
// gets a fresh worker (the page keeps one warm) instead of a fresh state.
const post = (message) => self.postMessage(JSON.stringify(message));
const waiting = new Map();
const started = performance.now();
let nextRequest = 1;
let run = 0;
let state = null;

function text(value) {
    return value === undefined || value === null ? '' : String(value);
}

async function boot() {
    const scope = Object.getOwnPropertyDescriptor(self, 'WorkerGlobalScope');
    if (scope) delete self.WorkerGlobalScope;
    self.window = self;
    try {
        state = await LuauState.createAsync({
            __log: (level, value) => { post({ t: 'log', run, level: text(level), text: text(value) }); },
            __host: (op, args) => new Promise((resolve) => {
                const id = nextRequest++;
                waiting.set(id, resolve);
                post({ t: 'req', run, id, op: text(op), args: text(args) || 'null' });
            }),
            __sleep: (seconds) => new Promise((resolve) => {
                setTimeout(resolve, Math.max(0, Number(seconds) || 0) * 1000);
            }),
            __now: () => performance.now() - started
        });
    } finally {
        delete self.window;
        if (scope) Object.defineProperty(self, 'WorkerGlobalScope', scope);
    }
}

async function execute(message) {
    let chunk = '';
    try {
        if (run !== 0) throw new Error('this Luau worker has already run a program');
        run = message.run;
        for (const part of message.chunks) {
            chunk = part.name;
            const fn = state.loadstring(part.source, part.name, false);
            if (typeof fn === 'string') throw new Error(fn);
            await fn();
        }
        post({ t: 'done', run, ok: true, error: '', chunk: '' });
    } catch (error) {
        post({ t: 'done', run, ok: false, error: text(error && error.message || error), chunk });
    }
}

self.onmessage = (event) => {
    let message;
    try { message = JSON.parse(event.data); } catch (e) { return; }
    if (message.t === 'reply') {
        const resolve = waiting.get(message.id);
        waiting.delete(message.id);
        if (resolve) resolve(text(message.json));
    } else if (message.t === 'run') {
        execute(message);
    }
};

try {
    await boot();
    post({ t: 'ready', engine: 'luau-web 1.4.0 (asyncify)' });
} catch (error) {
    post({ t: 'fail', error: text(error && error.message || error) });
}
