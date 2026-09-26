// Regression checks for selected-label formatting and visual block saving.
const assert = require('node:assert/strict');
const {chromium} = require('./pw');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({viewport: {width: 1440, height: 900}});
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(process.env.NEW || 'http://localhost:8123/web/index.html');
  await page.waitForFunction(() => window.graph && window.editorUi);

  await page.evaluate(() => {
    window.graph.addNode({id: 'range-test', x: 365, y: 120, width: 240, height: 70,
      text: 'Alpha Beta Gamma', shape: 'rect', textColor: '#172033'}, false);
  });
  const point = await page.evaluate(() => {
    const g = window.graph, r = g.container.getBoundingClientRect();
    return {x: r.left + (485 + (g.worldOriginX || 0)) * g.zoom - g.container.scrollLeft,
      y: r.top + (155 + (g.worldOriginY || 0)) * g.zoom - g.container.scrollTop};
  });
  await page.mouse.dblclick(point.x, point.y);
  await page.locator('.pixel-text-input').waitFor();
  await page.evaluate(() => {
    const field = document.querySelector('.pixel-text-input');
    const walker = document.createTreeWalker(field, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode()) && !node.textContent.includes('Beta')) {}
    if (!node) throw Error('Beta text node is missing');
    const start = node.textContent.indexOf('Beta'), range = document.createRange();
    range.setStart(node, start); range.setEnd(node, start + 4);
    const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
    field.dispatchEvent(new MouseEvent('mouseup', {bubbles: true}));
  });
  await page.locator('.qg-inspector-tabs [data-tab=text]').click();
  await page.locator('.qg-panel-inspector [data-page=text] input[type=color]').fill('#e5484d');
  await page.locator('.qg-panel-inspector [data-page=text] button[title=Bold]').click();
  assert.equal(await page.locator('.pixel-text-input').count(), 1, 'label stays open while formatting');
  const editorHtml = await page.locator('.pixel-text-input').evaluate(field => field.innerHTML);
  console.log('Selected-label editor HTML:', editorHtml);
  await page.evaluate(() => window.graph.finishTextEdit(true));
  const node = await page.evaluate(() => JSON.parse(window.graph.toJSON()).items.find(item => item.id === 'range-test'));
  if (!node.richText) console.log('Saved label without rich text:', JSON.stringify(node));
  assert.equal(node.textColor, '#172033', 'base color stays unchanged');
  const runs = node.richText.blocks.flatMap(block => block.runs);
  assert.equal(runs.map(run => run.text).join(''), 'Alpha Beta Gamma');
  assert.equal(runs.filter(run => run.text.includes('Beta')).every(run => run.color === '#e5484d' && run.bold), true);
  assert.equal(runs.filter(run => run.text.includes('Alpha') || run.text.includes('Gamma')).every(run => !run.bold && run.color !== '#e5484d'), true);

  await page.evaluate(() => {
    window.graph.addNode({id: 'block-test', kind: 'visualScript', vsType: 'set',
      x: 690, y: 120, width: 210, height: 76, shape: 'rect', text: 'Set variable',
      visualScript: {vsType: 'set', name: 'count', value: '0'}, editable: false}, false);
    window.graph.setSelection(['block-test']);
  });
  await page.locator('.qg-inspector-tabs [data-tab=block]').click();
  await page.locator('.qg-panel-inspector [data-field=__title]').fill('Saved title');
  await page.locator('.qg-panel-inspector [data-field=value]').fill('42');
  await page.locator('.qg-panel-inspector [data-page=block] button', {hasText: 'Save'}).click();
  const block = await page.evaluate(() => JSON.parse(window.graph.toJSON()).items.find(item => item.id === 'block-test'));
  assert.equal(block.text, 'Saved title');
  assert.equal(block.visualScript.value, '42');
  assert.deepEqual(errors, []);
  console.log('Inspector selected-text formatting and visual block Save passed.');
  await browser.close();
})().catch(error => {console.error(error); process.exit(1)});
