// Runs the same scripted interactions against the original editor and the
// Nim/WASM port and compares the resulting document JSON and screenshots.
// Usage: node tests/ui/compare.js [scenario-name-filter] [outdir]
//   ORIG=http://localhost:8124/index.html NEW=http://localhost:8123/web/index.html
const { chromium } = require('./pw');
const fs = require('fs');
const path = require('path');
const scenarios = require('./scenarios');

const ORIG = process.env.ORIG || 'http://localhost:8124/index.html';
const NEW = process.env.NEW || 'http://localhost:8123/web/index.html';
// Regions that legitimately differ: the sidebar tab strip (no Visual Script
// tab) and the frame-time readout in the status bar.
const TOLERANCE = Number(process.env.TOLERANCE || 40);
const MASKS = [{ x: 0, y: 68, width: 213, height: 38 }, { x: 900, y: 872, width: 500, height: 28 }];

async function open(browser, url) {
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message + '\n' + (e.stack || '').split('\n').slice(1, 4).join('\n')));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.addInitScript(() => {
    let t = 1700000000000;
    Date.now = () => t;
    window.__tick = (ms) => { t += ms; };
  });
  await page.goto(url);
  await page.waitForFunction(() => window.editorUi && window.graph);
  if (url === ORIG) {
    // Apply the port's intended removals (CScript, PowerPoint paste) to the
    // original so only unintended differences are reported.
    await page.evaluate(() => {
      const ui = window.editorUi;
      const drop = ['editCScript', 'runCScript', 'cscriptRunMode', 'pasteOfficeShapes'];
      ui.contextMenuBaseEntries = ui.contextMenuBaseEntries.filter((n) => drop.indexOf(n) < 0);
      const labels = ['Edit CScript', 'Run CScript', 'CScript Run Mode', 'Paste from PowerPoint'];
      (ui.menuPopups || []).forEach((popup) => {
        Array.from(popup.children).forEach((el) => {
          if (labels.some((l) => el.textContent.startsWith(l))) el.remove();
        });
        Array.from(popup.children).forEach((el) => {
          const prev = el.previousElementSibling;
          if (prev && el.tagName === 'HR' && prev.tagName === 'HR') el.remove();
        });
      });
      document.querySelectorAll('button').forEach((b) => { if (b.textContent === 'Edit CScript…') b.remove(); });
    });
  }
  await page.waitForTimeout(800);
  return { page, errors };
}

async function snapshot(page) {
  await page.waitForTimeout(400);
  const json = await page.evaluate(() => {
    const doc = JSON.parse(window.graph.toJSON());
    return JSON.stringify(doc, null, 1);
  });
  const selection = await page.evaluate(() => window.graph.getSelection().map((i) => i.id));
  const png = await page.screenshot({ mask: [] });
  return { json, selection, png };
}

async function diffImages(page, a, b) {
  return page.evaluate(async ([a, b, masks]) => {
    const load = (b64) => new Promise((res) => { const i = new Image(); i.onload = () => res(i); i.src = 'data:image/png;base64,' + b64; });
    const [ia, ib] = await Promise.all([load(a), load(b)]);
    const w = ia.width, h = ia.height;
    const ca = document.createElement('canvas'); ca.width = w; ca.height = h;
    const xa = ca.getContext('2d'); xa.drawImage(ia, 0, 0);
    const cb = document.createElement('canvas'); cb.width = w; cb.height = h;
    const xb = cb.getContext('2d'); xb.drawImage(ib, 0, 0);
    const da = xa.getImageData(0, 0, w, h).data, db = xb.getImageData(0, 0, w, h).data;
    const out = xa.createImageData(w, h);
    let n = 0, box = null;
    const masked = (x, y) => masks.some((m) => x >= m.x && x < m.x + m.width && y >= m.y && y < m.y + m.height);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      const d = Math.abs(da[i] - db[i]) + Math.abs(da[i + 1] - db[i + 1]) + Math.abs(da[i + 2] - db[i + 2]);
      out.data[i + 3] = 255;
      if (d > 0 && !masked(x, y)) {
        n++; out.data[i] = 255;
        if (!box) box = { x0: x, y0: y, x1: x, y1: y };
        else { box.x0 = Math.min(box.x0, x); box.y0 = Math.min(box.y0, y); box.x1 = Math.max(box.x1, x); box.y1 = Math.max(box.y1, y); }
      } else { out.data[i] = out.data[i + 1] = out.data[i + 2] = (da[i] + da[i + 1] + da[i + 2]) / 12 + 180; }
    }
    xa.putImageData(out, 0, 0);
    return { n, box, image: n ? ca.toDataURL('image/png').split(',')[1] : null };
  }, [a.toString('base64'), b.toString('base64'), MASKS]);
}

(async () => {
  const filter = process.argv[2] && process.argv[2] !== 'all' ? process.argv[2] : null;
  const outDir = process.argv[3];
  const browser = await chromium.launch();
  let failures = 0;
  for (const sc of scenarios) {
    if (filter && !sc.name.includes(filter)) continue;
    const results = [];
    for (const url of [ORIG, NEW]) {
      const { page, errors } = await open(browser, url);
      try { await sc.run(page); } catch (e) { errors.push('scenario threw: ' + e.message); }
      const snap = await snapshot(page);
      results.push({ page, errors, snap });
    }
    const [o, n] = results;
    const jsonSame = o.snap.json === n.snap.json;
    const selSame = JSON.stringify(o.snap.selection) === JSON.stringify(n.snap.selection);
    const d = await diffImages(n.page, o.snap.png, n.snap.png);
    // A few dozen pixels of form-control antialiasing differ from run to run
    // in the original as well; anything larger is a real difference.
    const ok = jsonSame && selSame && d.n <= TOLERANCE && n.errors.length === 0;
    if (!ok) failures++;
    console.log((ok ? 'PASS ' : 'FAIL ') + sc.name + '  json:' + (jsonSame ? 'same' : 'DIFF') +
      ' sel:' + (selSame ? 'same' : 'DIFF') + ' px:' + d.n + (d.box ? ' ' + JSON.stringify(d.box) : ''));
    if (o.errors.length) console.log('  original errors: ' + o.errors.join(' | ').slice(0, 400));
    if (n.errors.length) console.log('  port errors:\n    ' + n.errors.join('\n    ').slice(0, 2000));
    if (outDir && !ok) {
      fs.mkdirSync(outDir, { recursive: true });
      fs.writeFileSync(path.join(outDir, sc.name + '-orig.png'), o.snap.png);
      fs.writeFileSync(path.join(outDir, sc.name + '-new.png'), n.snap.png);
      if (d.image) fs.writeFileSync(path.join(outDir, sc.name + '-diff.png'), Buffer.from(d.image, 'base64'));
      fs.writeFileSync(path.join(outDir, sc.name + '-orig.json'), o.snap.json);
      fs.writeFileSync(path.join(outDir, sc.name + '-new.json'), n.snap.json);
      if (!selSame) console.log('  selection orig=' + JSON.stringify(o.snap.selection) + ' new=' + JSON.stringify(n.snap.selection));
    }
    await o.page.close();
    await n.page.close();
  }
  await browser.close();
  process.exit(failures ? 1 : 0);
})();
