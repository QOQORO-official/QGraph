// Loads the editor page, reports page errors and saves a screenshot.
// Usage: node tests/ui/smoke.js <url> <out.png>
const { chromium } = require('./pw');
(async () => {
  const [url, out] = process.argv.slice(2);
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message + '\n' + (e.stack || '').split('\n').slice(0, 4).join('\n')));
  page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') errors.push(m.type() + ': ' + m.text()); });
  page.on('requestfailed', (r) => errors.push('requestfailed: ' + r.url()));
  await page.goto(url);
  await page.waitForTimeout(2500);
  await page.screenshot({ path: out });
  console.log(errors.join('\n') || 'no errors');
  await browser.close();
})();
