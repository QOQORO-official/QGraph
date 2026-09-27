// Drag across QGraph table cells, including Ctrl-drag from a table.
const assert = require('node:assert/strict');
const {chromium} = require('./pw');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({viewport: {width: 1440, height: 900}});
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(process.env.NEW || 'http://localhost:8123/web/index.html');
  await page.waitForFunction(() => window.graph && window.editorUi);
  await page.evaluate(() => window.graph.addNode({id: 'range-table', shape: 'table',
    kind: 'table', x: 300, y: 220, width: 300, height: 150, rows: 3, columns: 3,
    cells: {'0,0': {text: 'A'}, '2,2': {text: 'I'}}}, false));
  const screen = async (x, y) => page.evaluate(([x, y]) => {
    const g = window.graph, r = g.container.getBoundingClientRect();
    return {x: r.left + (x + (g.worldOriginX || 0)) * g.zoom - g.container.scrollLeft,
      y: r.top + (y + (g.worldOriginY || 0)) * g.zoom - g.container.scrollTop};
  }, [x, y]);
  const drag = async (from, to, ctrl) => {
    const a = await screen(...from), b = await screen(...to);
    await page.mouse.move(a.x, a.y);
    if (ctrl) await page.keyboard.down('Control');
    await page.mouse.down();
    await page.mouse.move(b.x, b.y, {steps: 10});
    await page.mouse.up();
    if (ctrl) await page.keyboard.up('Control');
  };
  const selected = () => page.evaluate(() => window.graph.getSelectedTableCell());

  await drag([330, 245], [550, 340], true);
  let range = await selected();
  assert.deepEqual([range.startRow, range.startColumn, range.endRow, range.endColumn],
    [0, 0, 2, 2], 'Ctrl-drag expands one table-cell range instead of selecting the table object');
  assert.deepEqual(await page.evaluate(() => window.graph.getSelection().map(item => item.id)),
    ['range-table']);

  await drag([330, 245], [450, 290], false);
  range = await selected();
  assert.deepEqual([range.startRow, range.startColumn, range.endRow, range.endColumn],
    [0, 0, 1, 1], 'ordinary drag extends the active table cell selection too');
  assert.deepEqual(errors, []);
  console.log('Table cell-range dragging passed.');
  await browser.close();
})().catch(error => { console.error(error); process.exit(1); });
