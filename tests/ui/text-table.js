// Multiline editing and table context-menu regression checks.
const assert = require('node:assert/strict');
const {chromium} = require('./pw');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({viewport: {width: 1440, height: 900}});
  const errors = [];
  let dialogs = 0;
  page.on('pageerror', error => errors.push(error.message));
  page.on('dialog', dialog => { dialogs++; dialog.dismiss(); });
  await page.goto(process.env.NEW || 'http://localhost:8123/web/index.html');
  await page.waitForFunction(() => window.graph && window.editorUi);

  const screen = async (x, y) => page.evaluate(([x, y]) => {
    const g = window.graph, r = g.container.getBoundingClientRect();
    return {x: r.left + (x + (g.worldOriginX || 0)) * g.zoom - g.container.scrollLeft,
      y: r.top + (y + (g.worldOriginY || 0)) * g.zoom - g.container.scrollTop};
  }, [x, y]);

  await page.evaluate(() => window.graph.addNode({id: 'multiline-test', x: 360, y: 210,
    width: 260, height: 100, shape: 'rect', text: 'First line\nSecond line',
    richText: {blocks: [
      {type: 'p', indent: 0, runs: [{text: 'First line'}]},
      {type: 'p', indent: 0, runs: [{text: 'Second line'}]}
    ]}}, false));
  const line = await screen(480, 245);
  await page.mouse.dblclick(line.x, line.y);
  await page.locator('.pixel-text-input').waitFor();
  const editable = await page.locator('.pixel-text-input').innerText();
  assert.match(editable, /First line[\s\S]*Second line/,
    'double-clicking an ordinary paragraph opens the whole text object');
  await page.evaluate(() => window.graph.finishTextEdit(true));

  await page.evaluate(() => {
    const g = window.graph;
    g.addTemplate(window.PixelNodeTemplates.table, {x: 100, y: 100}, true);
  });
  const table = await page.evaluate(() => window.graph.getSelection()[0]);
  const cell = await screen(table.x + 10, table.y + table.height - 10);
  const runCellMenu = async label => {
    await page.mouse.click(cell.x, cell.y);
    await page.mouse.click(cell.x, cell.y);
    await page.mouse.click(cell.x, cell.y, {button: 'right'});
    await page.locator('.qg-context .qg-menu-item', {hasText: label}).click();
  };
  const initial = await page.evaluate(() => {
    const t = window.graph.getSelection()[0];
    return {rows: t.rows, columns: t.columns};
  });
  await runCellMenu('Insert Row Above');
  const afterRow = await page.evaluate(() => window.graph.getSelection()[0].rows);
  assert.equal(afterRow, initial.rows + 1, 'the row action inserts a row directly');
  await runCellMenu('Insert Column Left');
  const afterColumn = await page.evaluate(() => window.graph.getSelection()[0].columns);
  assert.equal(afterColumn, initial.columns + 1, 'the column action inserts a column directly');
  assert.equal(dialogs, 0, 'table commands never open the Link URL prompt');
  assert.deepEqual(errors, []);
  console.log('Multiline text and table context actions passed.');
  await browser.close();
})().catch(error => { console.error(error); process.exit(1); });
