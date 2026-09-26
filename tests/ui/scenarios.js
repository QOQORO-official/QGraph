// Scripted interactions for golden.js. Diagram coordinates go through
// toScreen(); the viewport below gives the desktop layout the same 936x803
// canvas the goldens were recorded with.
const fs = require('fs');
const path = require('path');

const sceneSource = fs.readFileSync(path.join(__dirname, '..', 'parity', 'scene.js'), 'utf8');

async function demo(page) {
  await page.evaluate(() => window.editorUi.editor.loadDemo());
  await page.waitForTimeout(200);
}

async function scene(page) {
  await page.addScriptTag({ content: sceneSource });
  await page.evaluate(() => window.graph.loadItems(window.makeScene(), true));
  await page.waitForTimeout(300);
}

// Screen position of a world point.
async function toScreen(page, x, y) {
  return page.evaluate(([x, y]) => {
    const g = window.graph;
    const r = g.container.getBoundingClientRect();
    const zoom = g.zoom;
    return {
      x: r.left + (x + (g.worldOriginX || 0)) * zoom - g.container.scrollLeft,
      y: r.top + (y + (g.worldOriginY || 0)) * zoom - g.container.scrollTop
    };
  }, [x, y]);
}

async function drag(page, from, to, steps = 8, opts = {}) {
  await page.mouse.move(from.x, from.y);
  if (opts.modifier) await page.keyboard.down(opts.modifier);
  await page.mouse.down();
  for (let i = 1; i <= steps; i++) {
    await page.mouse.move(from.x + (to.x - from.x) * i / steps, from.y + (to.y - from.y) * i / steps);
    await page.waitForTimeout(16);
  }
  await page.mouse.up();
  if (opts.modifier) await page.keyboard.up(opts.modifier);
  await page.waitForTimeout(100);
}

async function click(page, p, opts) {
  await page.mouse.click(p.x, p.y, opts);
  await page.waitForTimeout(80);
}

module.exports = [
  { name: 'empty', run: async () => {} },
  { name: 'demo', run: demo },
  { name: 'scene', run: scene },
  { name: 'scene-zoomed-out', run: async (page) => {
    await scene(page);
    await page.evaluate(() => window.graph.setZoom(0.5));
  } },
  { name: 'scene-select-all', run: async (page) => {
    await scene(page);
    await click(page, await toScreen(page, 60, 60));
    await page.keyboard.press('Control+a');
  } },
  { name: 'sidebar-click-insert', run: async (page) => {
    const items = page.locator('.qg-panel-library .qg-shape');
    for (const i of [0, 4, 7, 11]) {
      await items.nth(i).click();
      await page.waitForTimeout(80);
    }
  } },
  { name: 'select-node', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
  } },
  { name: 'move-node', run: async (page) => {
    await demo(page);
    const p = await toScreen(page, 437, 150);
    await drag(page, p, { x: p.x + 63, y: p.y + 47 });
  } },
  { name: 'resize-node', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
    const corner = await toScreen(page, 365 + 145, 120 + 66);
    await drag(page, corner, { x: corner.x + 51, y: corner.y + 33 });
  } },
  { name: 'rubberband', run: async (page) => {
    await demo(page);
    const a = await toScreen(page, 560, 60);
    const b = await toScreen(page, 900, 200);
    await drag(page, a, b);
  } },
  { name: 'hover-arrows', run: async (page) => {
    await demo(page);
    const p = await toScreen(page, 437, 150);
    await page.mouse.move(p.x, p.y);
    await page.waitForTimeout(600);
  } },
  { name: 'connect-nodes', run: async (page) => {
    await page.evaluate(() => {
      const g = window.graph;
      const before = g.snapshot();
      g.addNode({ id: 'a', x: 100, y: 100, width: 120, height: 60, text: 'A', shape: 'rect' }, false);
      g.addNode({ id: 'b', x: 420, y: 260, width: 120, height: 60, text: 'B', shape: 'ellipse' }, false);
      g.commit(before, 'Add');
    });
    await page.waitForTimeout(100);
    const a = await toScreen(page, 160, 130);
    await page.mouse.move(a.x, a.y);
    await page.waitForTimeout(600);
    // Drag the right-hand connection arrow of A onto B.
    const arrow = await toScreen(page, 220 + 18, 130);
    const b = await toScreen(page, 480, 290);
    await drag(page, arrow, b, 12);
  } },
  { name: 'text-edit', run: async (page) => {
    await demo(page);
    await page.mouse.dblclick(...Object.values(await toScreen(page, 437, 150)));
    await page.waitForTimeout(200);
    await page.keyboard.press('Control+a');
    await page.keyboard.type('Hello world');
    await click(page, await toScreen(page, 300, 600));
  } },
  { name: 'text-edit-open', run: async (page) => {
    await demo(page);
    await page.mouse.dblclick(...Object.values(await toScreen(page, 437, 150)));
    await page.waitForTimeout(200);
    await page.keyboard.type('X');
  } },
  { name: 'undo-redo', run: async (page) => {
    await demo(page);
    const p = await toScreen(page, 437, 150);
    await drag(page, p, { x: p.x + 80, y: p.y + 20 });
    const q = await toScreen(page, 620, 150);
    await drag(page, q, { x: q.x, y: q.y + 200 });
    await page.keyboard.press('Control+z');
    await page.keyboard.press('Control+z');
    await page.keyboard.press('Control+y');
  } },
  { name: 'copy-paste', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
    await page.keyboard.press('Control+c');
    await page.keyboard.press('Control+v');
    await page.keyboard.press('Control+v');
  } },
  { name: 'duplicate-delete', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
    await page.keyboard.press('Control+d');
    await click(page, await toScreen(page, 790, 150));
    await page.keyboard.press('Delete');
  } },
  { name: 'group', run: async (page) => {
    await demo(page);
    const a = await toScreen(page, 560, 60);
    const b = await toScreen(page, 900, 200);
    await drag(page, a, b);
    await page.keyboard.press('Control+g');
  } },
  { name: 'arrow-keys', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
    for (let i = 0; i < 3; i++) await page.keyboard.press('ArrowRight');
    await page.keyboard.press('Shift+ArrowDown');
  } },
  { name: 'context-menu', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150), { button: 'right' });
  } },
  { name: 'menu-edit', run: async (page) => {
    await demo(page);
    await page.locator('.qg-menubtn').filter({ hasText: /^Edit$/ }).first().click();
    await page.waitForTimeout(200);
  } },
  { name: 'toolbar-zoom-in', run: async (page) => {
    await demo(page);
    await page.evaluate(() => window.editorUi.actions.run('zoomIn'));
    await page.evaluate(() => window.editorUi.actions.run('zoomIn'));
  } },
  { name: 'wheel-scroll', run: async (page) => {
    await scene(page);
    const p = await toScreen(page, 300, 300);
    await page.mouse.move(p.x, p.y);
    await page.mouse.wheel(0, 240);
    await page.waitForTimeout(300);
  } },
  { name: 'ctrl-wheel-zoom', run: async (page) => {
    await scene(page);
    const p = await toScreen(page, 300, 300);
    await page.mouse.move(p.x, p.y);
    await page.keyboard.down('Control');
    await page.mouse.wheel(0, -200);
    await page.keyboard.up('Control');
    await page.waitForTimeout(300);
  } },
  { name: 'align-left', run: async (page) => {
    await demo(page);
    const a = await toScreen(page, 560, 60);
    const b = await toScreen(page, 900, 200);
    await drag(page, a, b);
    await page.evaluate(() => window.editorUi.actions.run('alignLeft'));
  } },
  { name: 'format-fill', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
    await page.evaluate(() => window.graph.applyStyle({ fill: '#1ba1e2' }, 'Fill'));
  } },
  { name: 'page-view', run: async (page) => {
    await demo(page);
    await page.evaluate(() => window.editorUi.actions.run('pageView'));
  } },
  { name: 'table-insert', run: async (page) => {
    await page.fill('.qg-panel-library .qg-search-input', 'table');
    await page.keyboard.press('Enter');
    await page.waitForTimeout(300);
    // The original's '.geItem' matched the menubar's File entry first, so the
    // recorded golden is a search followed by opening the File menu.
    await page.locator('.qg-menubtn:visible').first().click();
  } },
  { name: 'layers-dialog', run: async (page) => {
    await demo(page);
    await page.evaluate(() => window.editorUi.actions.run('layers'));
  } },
  { name: 'outline', run: async (page) => {
    await scene(page);
    await page.evaluate(() => window.editorUi.actions.run('outline'));
  } },
  { name: 'rotate-flip', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
    await page.evaluate(() => { window.editorUi.actions.run('rotate90'); window.editorUi.actions.run('flipHorizontal'); });
  } },
  { name: 'edge-waypoint', run: async (page) => {
    await page.evaluate(() => {
      const g = window.graph;
      const before = g.snapshot();
      g.addNode({ id: 'a', x: 100, y: 100, width: 120, height: 60, text: 'A', shape: 'rect' }, false);
      g.addNode({ id: 'b', x: 420, y: 300, width: 120, height: 60, text: 'B', shape: 'rect' }, false);
      g.addEdge({ id: 'e', sourceId: 'a', targetId: 'b', text: 'label' }, false);
      g.commit(before, 'Add');
    });
    await page.waitForTimeout(100);
    const mid = await page.evaluate(() => {
      const e = window.graph.getItem('e');
      return e;
    });
    const s = await toScreen(page, 220, 130);
    const t = await toScreen(page, 420, 330);
    await click(page, { x: (s.x + t.x) / 2, y: (s.y + t.y) / 2 });
  } }
];

const MX_SAMPLE = `<mxGraphModel dx="1000" dy="600" grid="1" gridSize="10"><root>
<mxCell id="0"/><mxCell id="1" parent="0"/>
<mxCell id="lane" value="Pool" style="swimlane;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;" vertex="1" parent="1"><mxGeometry x="40" y="40" width="360" height="220" as="geometry"/></mxCell>
<mxCell id="s1" value="Start" style="ellipse;whiteSpace=wrap;html=1;fillColor=#d5e8d4;strokeColor=#82b366;" vertex="1" parent="lane"><mxGeometry x="20" y="60" width="80" height="50" as="geometry"/></mxCell>
<mxCell id="s2" value="Check &lt;b&gt;bold&lt;/b&gt;" style="rhombus;whiteSpace=wrap;html=1;fillColor=#fff2cc;strokeColor=#d6b656;" vertex="1" parent="lane"><mxGeometry x="160" y="50" width="100" height="80" as="geometry"/></mxCell>
<mxCell id="e1" value="go" style="edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;" edge="1" parent="lane" source="s1" target="s2"><mxGeometry relative="1" as="geometry"/></mxCell>
<mxCell id="t1" value="Some free text with wrapping enabled across lines" style="text;html=1;whiteSpace=wrap;align=left;verticalAlign=top;" vertex="1" parent="1"><mxGeometry x="460" y="40" width="160" height="60" as="geometry"/></mxCell>
<mxCell id="c1" value="Cloud" style="ellipse;shape=cloud;whiteSpace=wrap;html=1;" vertex="1" parent="1"><mxGeometry x="460" y="140" width="120" height="80" as="geometry"/></mxCell>
<mxCell id="d1" value="Doc" style="shape=document;whiteSpace=wrap;html=1;boundedLbl=1;dashed=1;" vertex="1" parent="1"><mxGeometry x="660" y="140" width="100" height="70" as="geometry"/></mxCell>
<mxCell id="e2" value="" style="edgeStyle=none;html=1;endArrow=open;startArrow=oval;curved=1;" edge="1" parent="1" source="c1" target="d1"><mxGeometry relative="1" as="geometry"><Array as="points"><mxPoint x="620" y="260"/></Array></mxGeometry></mxCell>
<mxCell id="e3" value="to pool" style="edgeStyle=elbowEdgeStyle;html=1;dashed=1;strokeColor=#b85450;" edge="1" parent="1" source="d1" target="lane"><mxGeometry relative="1" as="geometry"/></mxCell>
<mxCell id="tb" value="&lt;table border=&quot;1&quot;&gt;&lt;tr&gt;&lt;th&gt;A&lt;/th&gt;&lt;th&gt;B&lt;/th&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;1&lt;/td&gt;&lt;td&gt;2&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;" style="text;html=1;whiteSpace=wrap;overflow=fill;" vertex="1" parent="1"><mxGeometry x="60" y="320" width="200" height="80" as="geometry"/></mxCell>
<mxCell id="cy" value="DB" style="shape=cylinder3;whiteSpace=wrap;html=1;size=15;shadow=1;" vertex="1" parent="1"><mxGeometry x="320" y="320" width="70" height="90" as="geometry"/></mxCell>
<mxCell id="hx" value="Hex" style="shape=hexagon;perimeter=hexagonPerimeter2;whiteSpace=wrap;html=1;rotation=15;gradientColor=#7ea6e0;fillColor=#dae8fc;" vertex="1" parent="1"><mxGeometry x="460" y="320" width="110" height="70" as="geometry"/></mxCell>
</root></mxGraphModel>`;

async function loadMx(page) {
  await page.evaluate((xml) => {
    const doc = window.PixelMxGraphFormat.parse(xml);
    window.graph.fromJSON(doc);
  }, MX_SAMPLE);
  await page.waitForTimeout(300);
}

async function twoNodesAndEdge(page) {
  await page.evaluate(() => {
    const g = window.graph;
    const before = g.snapshot();
    g.addNode({ id: 'a', x: 100, y: 100, width: 120, height: 60, text: 'A', shape: 'rect' }, false);
    g.addNode({ id: 'b', x: 420, y: 300, width: 120, height: 60, text: 'B', shape: 'rect' }, false);
    g.addEdge({ id: 'e', sourceId: 'a', targetId: 'b', text: 'label' }, false);
    g.commit(before, 'Add');
  });
  await page.waitForTimeout(100);
}

async function addTable(page) {
  await page.evaluate(() => {
    const g = window.graph;
    const before = g.snapshot();
    g.addTemplate(window.PixelNodeTemplates.table, { x: 100, y: 100 }, true);
    g.commit(before, 'Table');
  });
  await page.waitForTimeout(100);
}

module.exports.push(
  { name: 'mx-load', run: loadMx },
  { name: 'mx-select-lane', run: async (page) => {
    await loadMx(page);
    await click(page, await toScreen(page, 100, 50));
  } },
  { name: 'mx-move-child', run: async (page) => {
    await loadMx(page);
    const p = await toScreen(page, 100, 125);
    await drag(page, p, { x: p.x + 40, y: p.y + 60 });
  } },
  { name: 'mx-move-lane', run: async (page) => {
    await loadMx(page);
    const p = await toScreen(page, 220, 52);
    await drag(page, p, { x: p.x + 150, y: p.y + 200 });
  } },
  { name: 'mx-fold-lane', run: async (page) => {
    await loadMx(page);
    await click(page, await toScreen(page, 220, 52));
    await page.evaluate(() => window.editorUi.actions.run('collapseExpand'));
  } },
  { name: 'mx-select-all-group', run: async (page) => {
    await loadMx(page);
    await click(page, await toScreen(page, 900, 500));
    await page.keyboard.press('Control+a');
    await page.keyboard.press('Control+g');
    await click(page, await toScreen(page, 520, 180));
  } },
  { name: 'mx-fit', run: async (page) => {
    await loadMx(page);
    await page.evaluate(() => window.editorUi.actions.run('fit'));
  } },
  { name: 'edge-select', run: async (page) => {
    await twoNodesAndEdge(page);
    const s = await toScreen(page, 280, 130);
    await click(page, s);
    const edge = await page.evaluate(() => window.graph.getSelection().map((i) => i.id));
    if (!edge.length) {
      const t = await toScreen(page, 350, 230);
      await click(page, t);
    }
  } },
  { name: 'edge-drag-target', run: async (page) => {
    await twoNodesAndEdge(page);
    await page.evaluate(() => window.graph.setSelection(['e']));
    await page.waitForTimeout(100);
    const ends = await page.evaluate(() => {
      const e = window.graph.getItem('e');
      return { t: e.targetPoint, route: e.route };
    });
    const pts = ends.route && ends.route.length ? ends.route : null;
    const end = pts ? pts[pts.length - 1] : (ends.t || { x: 480, y: 300 });
    const p = await toScreen(page, end.x, end.y);
    await drag(page, p, { x: p.x + 150, y: p.y + 120 }, 10);
  } },
  { name: 'edge-add-waypoint', run: async (page) => {
    await twoNodesAndEdge(page);
    await page.evaluate(() => { window.graph.setSelection(['e']); window.editorUi.actions.run('addWaypoint'); });
  } },
  { name: 'edge-reverse-style', run: async (page) => {
    await twoNodesAndEdge(page);
    await page.evaluate(() => {
      window.graph.setSelection(['e']);
      window.editorUi.actions.run('reverseConnector');
      window.editorUi.actions.run('dashed');
    });
  } },
  { name: 'table-add', run: addTable },
  { name: 'table-cell-click', run: async (page) => {
    await addTable(page);
    const b = await page.evaluate(() => window.graph.getSelection()[0]);
    await click(page, await toScreen(page, b.x + 10, b.y + b.height - 10));
    await click(page, await toScreen(page, b.x + 10, b.y + b.height - 10));
  } },
  { name: 'table-insert-row', run: async (page) => {
    await addTable(page);
    const b = await page.evaluate(() => window.graph.getSelection()[0]);
    await click(page, await toScreen(page, b.x + 10, b.y + b.height - 10));
    await click(page, await toScreen(page, b.x + 10, b.y + b.height - 10));
    await page.evaluate(() => window.editorUi.actions.run('tableInsertRowBelow'));
  } },
  { name: 'table-cell-edit', run: async (page) => {
    await addTable(page);
    const b = await page.evaluate(() => window.graph.getSelection()[0]);
    const p = await toScreen(page, b.x + 10, b.y + b.height - 10);
    await click(page, p);
    await page.mouse.dblclick(p.x, p.y);
    await page.waitForTimeout(200);
    await page.keyboard.type('Cell!');
    await page.keyboard.press('Tab');
    await page.keyboard.type('Next');
    await click(page, await toScreen(page, 700, 600));
  } },
  { name: 'table-context-menu', run: async (page) => {
    await addTable(page);
    const b = await page.evaluate(() => window.graph.getSelection()[0]);
    const p = await toScreen(page, b.x + 10, b.y + b.height - 10);
    await click(page, p);
    await click(page, p);
    await click(page, p, { button: 'right' });
  } },
  { name: 'rotate-handle', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
    const r = await page.evaluate(() => {
      const el = document.querySelector('canvas');
      return null;
    });
    const p = await toScreen(page, 437.5, 120 - 54);
    await page.mouse.move(p.x, p.y);
    await page.waitForTimeout(100);
    const q = await toScreen(page, 437.5 + 80, 120 - 20);
    await drag(page, p, q, 10);
  } },
  { name: 'sidebar-drag-drop', run: async (page) => {
    const src = page.locator('.qg-panel-library .qg-shape').nth(4);
    const target = await toScreen(page, 500, 400);
    await src.dragTo(page.locator('body'), { targetPosition: target });
    await page.waitForTimeout(300);
  } },
  { name: 'shift-click-replace', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
    await page.keyboard.down('Shift');
    await page.locator('.qg-panel-library .qg-shape').nth(4).click();
    await page.keyboard.up('Shift');
  } },
  { name: 'layers-add-move', run: async (page) => {
    await demo(page);
    await page.evaluate(() => {
      const g = window.graph;
      const layer = g.addLayer('Second');
      g.setSelection(['test']);
      g.moveSelectionToLayer(layer.id || layer);
      g.updateLayer(g.layers[0].id, { visible: false });
    });
    await page.evaluate(() => window.editorUi.actions.run('layers'));
  } },
  { name: 'lock-and-drag', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
    await page.keyboard.press('Control+l');
    const p = await toScreen(page, 437, 150);
    await drag(page, p, { x: p.x + 60, y: p.y + 60 });
  } },
  { name: 'copy-paste-style', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
    await page.keyboard.press('Control+Shift+c');
    await click(page, await toScreen(page, 120, 138));
    await page.keyboard.press('Control+Shift+v');
  } },
  { name: 'bold-toolbar', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 120, 80));
    await page.evaluate(() => window.editorUi.actions.run('bold'));
  } },
  { name: 'format-tabs', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
    await page.locator('.qg-inspector-tabs [data-tab=arrange]').click();
    await page.waitForTimeout(200);
  } },
  { name: 'text-tab', run: async (page) => {
    await demo(page);
    await click(page, await toScreen(page, 437, 150));
    await page.locator('.qg-inspector-tabs [data-tab=text]').click().catch(() => {});
    await page.waitForTimeout(200);
  } },
  { name: 'new-shape-typing', run: async (page) => {
    await click(page, await toScreen(page, 300, 300));
    await page.evaluate(() => window.editorUi.editor.addAtCenter('process'));
    await page.keyboard.type('typed');
    await page.keyboard.press('Escape');
  } },
  { name: 'distribute', run: async (page) => {
    await demo(page);
    await page.evaluate(() => {
      window.graph.setSelection(['test', 'docs', 'admission', 'add']);
      window.editorUi.actions.run('distributeHorizontal');
    });
  } },
  { name: 'save-load-local', run: async (page) => {
    await demo(page);
    await page.evaluate(() => {
      window.graph.saveLocal();
      window.editorUi.editor.newDocument();
      window.graph.loadLocal();
    });
  } },
  { name: 'export-png-size', run: async (page) => {
    await loadMx(page);
    await page.evaluate(() => {
      const c = window.graph.renderToCanvas(1, 20);
      window.__exportSize = c.width + 'x' + c.height;
      const g = window.graph;
      const before = g.snapshot();
      g.addNode({ id: 'sz', x: 700, y: 400, width: 160, height: 40, text: window.__exportSize }, false);
      g.commit(before, 'size');
    });
  } },
  { name: 'export-png-pixels', run: async (page) => {
    await loadMx(page);
    await page.evaluate(() => {
      const c = window.graph.renderToCanvas(1, 20);
      const img = document.createElement('img');
      img.src = c.toDataURL('image/png');
      img.style.cssText = 'position:fixed;left:0;top:0;z-index:100000;background:#fff';
      document.body.appendChild(img);
    });
    await page.waitForTimeout(300);
  } }
);

module.exports.viewport = { width: 1588, height: 859 };
