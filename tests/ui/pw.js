// Resolves Playwright from the project, $PLAYWRIGHT or the global install.
module.exports = (() => {
  const candidates = [process.env.PLAYWRIGHT, 'playwright', '/opt/node22/lib/node_modules/playwright'];
  for (const c of candidates) {
    if (!c) continue;
    try { return require(c); } catch (e) { /* try the next one */ }
  }
  throw new Error('Playwright not found; run `npm install` first');
})();
