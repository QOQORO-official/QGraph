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
  const colorHtml = await page.locator('.pixel-text-input').evaluate(field => field.innerHTML);
  const selectionBeforeBold = await page.evaluate(() => getSelection().toString());
  await page.locator('.qg-panel-inspector [data-page=text] button[title=Bold]').click();
  assert.equal(await page.locator('.pixel-text-input').count(), 1, 'label stays open while formatting');
  const boldHtml = await page.locator('.pixel-text-input').evaluate(field => field.innerHTML);
  await page.evaluate(() => window.graph.finishTextEdit(true));
  const node = await page.evaluate(() => JSON.parse(window.graph.toJSON()).items.find(item => item.id === 'range-test'));
  assert.ok(node.richText, `selected formatting survived: color ${colorHtml}, selection ${selectionBeforeBold}, bold ${boldHtml}`);
  assert.equal(node.textColor, '#172033', 'base color stays unchanged');
  const runs = node.richText.blocks.flatMap(block => block.runs);
  assert.equal(runs.map(run => run.text).join(''), 'Alpha Beta Gamma');
  const isAccent = color => ['#e5484d', 'rgb(229,72,77)'].includes((color || '').toLowerCase().replace(/\s/g, ''));
  const selectedRuns = runs.filter(run => run.text.includes('Beta'));
  assert.equal(selectedRuns.length > 0 && selectedRuns.every(run => isAccent(run.color) && run.bold), true);
  assert.equal(runs.filter(run => run.text.includes('Alpha') || run.text.includes('Gamma')).every(run => !run.bold && !isAccent(run.color)), true);

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

  await page.evaluate(() => {
    window.graph.addNode({id: 'socket-source', x: 365, y: 350, width: 190, height: 100,
      shape: 'rect', text: 'Source', portsEnabled: true, outputPorts: 'value:float'}, false);
    window.graph.addNode({id: 'socket-target', x: 670, y: 350, width: 190, height: 100,
      shape: 'rect', text: 'Target', portsEnabled: true, inputPorts: 'value:float'}, false);
    window.graph.setSelection(['socket-source']);
  });
  await page.locator('.qg-inspector-tabs [data-tab=style]').click();
  const socketsCard = page.locator('.qg-panel-inspector [data-page=style] .qg-card',
    {hasText: 'Variable sockets'});
  const socketsToggle = socketsCard.locator('input[type=checkbox]');
  assert.equal(await socketsToggle.isChecked(), true);
  await socketsToggle.uncheck();
  assert.equal(await page.evaluate(() => JSON.parse(window.graph.toJSON()).items.find(item =>
    item.id === 'socket-source').portsEnabled), false, 'socket visibility changes only on this node');
  await socketsToggle.check();
  const ports = await page.evaluate(() => {
    const g = window.graph, r = g.container.getBoundingClientRect();
    const xy = (x, y) => ({x: r.left + (x + (g.worldOriginX || 0)) * g.zoom - g.container.scrollLeft,
      y: r.top + (y + (g.worldOriginY || 0)) * g.zoom - g.container.scrollTop});
    return {from: xy(555, 400), to: xy(670, 400)};
  });
  await page.mouse.move(ports.from.x, ports.from.y);
  await page.mouse.down();
  await page.mouse.move(ports.to.x, ports.to.y, {steps: 8});
  await page.mouse.up();
  const edge = await page.evaluate(() => JSON.parse(window.graph.toJSON()).items.find(item =>
    item.type === 'edge' && item.sourceId === 'socket-source' && item.targetId === 'socket-target'));
  assert.equal(edge?.sourceAnchor?.portName, 'value', 'drag began at the named output socket');
  assert.equal(edge?.targetAnchor?.portName, 'value', 'drag ended at the named input socket');

  await page.locator('[title="Lock canvas for panning"]').click();
  assert.equal(await page.evaluate(() => window.graph.getSelection().length), 0);
  const sourceCenter = await page.evaluate(() => {
    const g = window.graph, r = g.container.getBoundingClientRect();
    return {x: r.left + (460 + (g.worldOriginX || 0)) * g.zoom - g.container.scrollLeft,
      y: r.top + (400 + (g.worldOriginY || 0)) * g.zoom - g.container.scrollTop};
  });
  await page.mouse.click(sourceCenter.x, sourceCenter.y);
  assert.equal(await page.evaluate(() => window.graph.getSelection().length), 0, 'canvas lock prevents selection');
  await page.setViewportSize({width: 820, height: 700});
  await page.waitForTimeout(200);
  assert.equal(await page.locator('.qg-topbar-start [title="Menu"]').isVisible(), true,
    'compact desktop and tablet widths keep the full menu accessible');
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true);
  await page.setViewportSize({width: 320, height: 640});
  await page.waitForTimeout(200);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true,
    'phone layout fits its viewport');
  assert.equal(await page.locator('[title="Unlock canvas interactions"]').isVisible(), true);
  await page.locator('[title="Unlock canvas interactions"]').click();
  await page.evaluate(() => window.graph.setSelection(['socket-source']));
  assert.equal(await page.locator('.qg-selpill').isVisible(), true);
  assert.equal(await page.locator('.qg-selpill').evaluate(pill =>
    pill.scrollWidth > pill.clientWidth && pill.getBoundingClientRect().right <= innerWidth), true,
    'the crowded mobile selection toolbar scrolls within the screen');
  assert.deepEqual(errors, []);
  console.log('Inspector text, block Save, variable sockets, canvas lock, and phone layout passed.');
  await browser.close();
})().catch(error => {console.error(error); process.exit(1)});
