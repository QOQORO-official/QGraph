// Evaluates the original palette/template definitions and writes them as
// JSON for the Nim build (src/app/data/*.json).
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const dir = path.join(__dirname, '..', process.argv[2] || 'ref/js');
const out = path.join(__dirname, '..', 'src', 'app', 'data');
const ctx = { console };
ctx.window = ctx; ctx.self = ctx;
vm.createContext(ctx);
for (const f of ['ClassicPalette.js', 'Editor.js']) {
  vm.runInContext(fs.readFileSync(path.join(dir, f), 'utf8'), ctx, { filename: f });
}
fs.writeFileSync(path.join(out, 'palette.json'), JSON.stringify(ctx.PixelClassicPalette));
fs.writeFileSync(path.join(out, 'templates.json'), JSON.stringify(ctx.PixelNodeTemplates));
fs.writeFileSync(path.join(out, 'visualscript.json'), JSON.stringify(ctx.PixelVisualScriptDefinitions));
console.log('wrote', Object.keys(ctx.PixelClassicPalette).join(','), Object.keys(ctx.PixelNodeTemplates).length);
