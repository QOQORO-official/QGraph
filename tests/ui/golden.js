// Checks the port against document snapshots recorded from the original
// editor. Each scenario in scenarios.js is replayed in headless Chromium and
// the resulting diagram JSON and selection must match tests/ui/golden/.
//
//   node tests/ui/golden.js            check (BASE defaults to the local server)
//   node tests/ui/golden.js --record   re-record from the original (ORIG url)
const { chromium } = require('./pw');
const fs = require('fs');
const path = require('path');
const scenarios = require('./scenarios');

const record = process.argv.includes('--record');
const filter = process.argv.slice(2).find((a) => !a.startsWith('--'));
const url = record ? (process.env.ORIG || 'http://localhost:8124/index.html')
  : (process.env.NEW || 'http://localhost:8123/web/index.html');
const dir = path.join(__dirname, 'golden');

(async () => {
  const browser = await chromium.launch();
  let failures = 0;
  fs.mkdirSync(dir, { recursive: true });
  for (const sc of scenarios) {
    if (filter && !sc.name.includes(filter)) continue;
    const page = await browser.newPage({ viewport: scenarios.viewport });
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    await page.addInitScript(() => { const t = 1700000000000; Date.now = () => t; });
    await page.goto(url);
    await page.waitForFunction(() => window.editorUi && window.graph);
    await page.waitForTimeout(800);
    try { await sc.run(page); } catch (e) { errors.push('scenario threw: ' + e.message); }
    await page.waitForTimeout(400);
    const state = await page.evaluate(() => ({
      document: JSON.parse(window.graph.toJSON()),
      selection: window.graph.getSelection().map((i) => i.id)
    }));
    const text = JSON.stringify(state, null, 1) + '\n';
    const file = path.join(dir, sc.name + '.json');
    if (record) {
      fs.writeFileSync(file, text);
      console.log('recorded ' + sc.name);
    } else if (!fs.existsSync(file)) {
      console.log('SKIP ' + sc.name + ' (no golden)');
    } else {
      const ok = fs.readFileSync(file, 'utf8') === text && errors.length === 0;
      if (!ok) {
        failures++;
        fs.writeFileSync(path.join(dir, sc.name + '.actual.json'), text);
      }
      console.log((ok ? 'PASS ' : 'FAIL ') + sc.name + (errors.length ? '\n  ' + errors.join('\n  ') : ''));
    }
    await page.close();
  }
  await browser.close();
  process.exit(failures ? 1 : 0);
})();
