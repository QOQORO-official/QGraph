// Ctrl-drag selects overlapping objects additively, including from a node.
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
    const g = window.graph;
    for (const [id, x, y] of [['first', 300, 260], ['second', 520, 260], ['kept', 800, 300]]) {
      g.addNode({id, x, y, width: 80, height: 60, shape: 'rect', text: id}, false);
    }
    g.setSelection(['kept']);
  });
  const screen = async (x, y) => page.evaluate(([x, y]) => {
    const g = window.graph, r = g.container.getBoundingClientRect();
    return {x: r.left + (x + (g.worldOriginX || 0)) * g.zoom - g.container.scrollLeft,
      y: r.top + (y + (g.worldOriginY || 0)) * g.zoom - g.container.scrollTop};
  }, [x, y]);
  const start = await screen(340, 290), end = await screen(570, 320);
  await page.mouse.move(start.x, start.y);
  await page.keyboard.down('Control');
  await page.mouse.down();
  await page.mouse.move(end.x, end.y, {steps: 8});
  await page.mouse.up();
  await page.keyboard.up('Control');
  const state = await page.evaluate(() => ({
    ids: window.graph.getSelection().map(item => item.id).sort(),
    positions: JSON.parse(window.graph.toJSON()).items.filter(item =>
      ['first', 'second', 'kept'].includes(item.id)).map(item => [item.id, item.x, item.y])
  }));
  assert.deepEqual(state.ids, ['first', 'kept', 'second']);
  assert.deepEqual(state.positions, [['first', 300, 260], ['second', 520, 260], ['kept', 800, 300]],
    'Ctrl-drag selects instead of moving its starting node');

  const second = await screen(560, 290);
  await page.keyboard.down('Control');
  await page.mouse.click(second.x, second.y);
  await page.keyboard.up('Control');
  assert.deepEqual(await page.evaluate(() => window.graph.getSelection().map(item => item.id).sort()),
    ['first', 'kept'], 'Ctrl-click toggles one item without dragging');

  await page.mouse.click(start.x, start.y, {button: 'right'});
  await page.locator('.qg-context').waitFor({state: 'visible'});
  const beforeDismiss = await page.evaluate(() => ({
    x: window.graph.container.scrollLeft, y: window.graph.container.scrollTop,
    selection: window.graph.getSelection().map(item => item.id).sort()
  }));
  const empty = await screen(710, 460);
  await page.mouse.click(empty.x, empty.y);
  assert.equal(await page.locator('.qg-context').isVisible(), false);
  const afterDismiss = await page.evaluate(() => ({
    x: window.graph.container.scrollLeft, y: window.graph.container.scrollTop,
    selection: window.graph.getSelection().map(item => item.id).sort()
  }));
  assert.deepEqual(afterDismiss, beforeDismiss,
    'dismissing the context menu does not pan or change canvas selection');
  // Selection must not resize the scroll surface, even momentarily.
  await page.evaluate(() => {
    window.selectionSpacerChanges = 0;
    window.selectionObserver = new MutationObserver(records => {
      window.selectionSpacerChanges += records.length;
    });
    window.selectionObserver.observe(document.querySelector('.pixel-world-spacer'),
      {attributes: true, attributeFilter: ['style']});
  });
  for (let i = 0; i < 3; i++) {
    await page.mouse.click(start.x, start.y);
    assert.deepEqual(await page.evaluate(() => window.graph.getSelection().map(item => item.id)), ['first']);
    await page.mouse.click(empty.x, empty.y);
    assert.equal(await page.evaluate(() => window.graph.getSelection().length), 0);
  }
  const stable = await page.evaluate(() => {
    window.selectionObserver.disconnect();
    return {changes: window.selectionSpacerChanges, x: window.graph.container.scrollLeft,
      y: window.graph.container.scrollTop};
  });
  assert.equal(stable.changes, 0, 'selecting and deselecting never resizes the canvas surface');
  assert.equal(stable.x, beforeDismiss.x);
  assert.equal(stable.y, beforeDismiss.y);
  assert.deepEqual(errors, []);
  console.log('Ctrl-drag selection and stable context-menu dismissal passed.');
  await browser.close();
})().catch(error => { console.error(error); process.exit(1); });
