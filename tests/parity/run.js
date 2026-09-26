// Renders the parity scene with the original JS painter and the Nim painter
// and reports per-view pixel differences. Usage: node tests/parity/run.js [outdir]
const { chromium } = require('../ui/pw');
const fs = require('fs');
const path = require('path');
(async () => {
  const base = process.env.BASE || 'http://localhost:8123';
  const out = process.argv[2];
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.goto(base + '/tests/parity/orig.html');
  const orig = await page.evaluate(() => window.render());
  await page.goto(base + '/tests/parity/new.html');
  const next = await page.evaluate(() => window.render());
  let failed = false;
  for (let i = 0; i < orig.length; i++) {
    const r = await page.evaluate(([a, b]) => window.compare(a, b), [orig[i], next[i]]);
    console.log('view ' + i + ': ' + JSON.stringify({ diffPixels: r.diffPixels, maxDelta: r.maxDelta, box: r.box, sizeMismatch: r.sizeMismatch }));
    if (r.diffPixels) failed = true;
    if (out) {
      fs.mkdirSync(out, { recursive: true });
      const save = (name, url) => fs.writeFileSync(path.join(out, name), Buffer.from(url.split(',')[1], 'base64'));
      save('orig-' + i + '.png', orig[i]);
      save('new-' + i + '.png', next[i]);
      if (r.diffImage) save('diff-' + i + '.png', r.diffImage);
    }
  }
  if (errors.length) console.log('errors:\n' + errors.join('\n'));
  await browser.close();
  process.exit(failed || errors.length ? 1 : 0);
})();
