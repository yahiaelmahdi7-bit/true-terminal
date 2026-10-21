// Dev only: screenshots of every phone screen (light + dark, 390x844 @2x) against scripts/remote-mock.py.
// Run: node scripts/remote-shots.mjs   (needs Playwright: set PW_PATH to a node_modules/playwright dir if it isn't resolvable)
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PW_PATH || 'playwright');
const out = path.join(root, '.out/run26');
mkdirSync(out, { recursive: true });
const PORT = 8899, wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function withMock(state, fn) {
  const p = spawn('python3', [path.join(root, 'scripts/remote-mock.py')], { env: { ...process.env, MOCK_STATE: state, MOCK_PORT: String(PORT) }, stdio: 'ignore' });
  try {
    for (let i = 0; i < 50; i++) { try { await fetch(`http://127.0.0.1:${PORT}/manifest.webmanifest`); break; } catch { await wait(100); } }
    await fn();
  } finally { p.kill('SIGKILL'); await wait(200); }
}

const browser = await chromium.launch();
try {
  for (const scheme of ['light', 'dark']) {
    const page = async (paired) => {
      const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, colorScheme: scheme, hasTouch: true, isMobile: true });
      const pg = await ctx.newPage();
      if (paired) await pg.addInitScript(() => localStorage.setItem('true.token', 'mock-token'));
      await pg.goto(`http://127.0.0.1:${PORT}/`);
      return pg;
    };
    const shot = (pg, name) => pg.screenshot({ path: path.join(out, `${name}-${scheme}.png`) });

    await withMock('pairing', async () => {
      const pg = await page(false);
      await pg.waitForSelector('#pair:not([hidden])');
      await pg.tap('#cells'); await pg.keyboard.type('428');
      await shot(pg, 'pairing');
    });
    await withMock('normal', async () => {
      let pg = await page(true);
      await pg.waitForSelector('#tabs .row'); await shot(pg, 'hub-normal');
      await pg.evaluate(() => window.scrollTo(0, 120)); await wait(300); await shot(pg, 'hub-scrolled');
      await pg.evaluate(() => window.scrollTo(0, 0));
      await pg.tap('#fab'); await pg.waitForSelector('#cmdText');
      await pg.fill('#cmdText', 'fix the login test'); await pg.tap('#cmdRoute'); await pg.waitForSelector('.rc'); await wait(600);
      await shot(pg, 'composer');
      await pg.tap('.rc'); await wait(700); await shot(pg, 'slot-picker');
      await pg.close();
      pg = await page(true); await pg.waitForSelector('#tabs .row');
      await pg.tap('#tabs .row >> nth=3'); await pg.waitForSelector('#sheetBody pre'); await wait(600); await shot(pg, 'builder-sheet');
      await pg.close();
      pg = await page(true); await pg.waitForSelector('#tabs .row');
      await pg.tap('[data-tab=shots]'); await pg.waitForSelector('#grid img[src]'); await wait(400); await shot(pg, 'shots');
      await pg.tap('#grid button >> nth=1'); await pg.waitForSelector('#viewer:not([hidden])'); await wait(400); await shot(pg, 'shot-viewer');
      await pg.tap('#vClose');
      await pg.tap('[data-tab=send]'); await pg.waitForSelector('#inbox .item'); await wait(400); await shot(pg, 'send');
      await pg.close();
    });
    await withMock('empty', async () => {
      const pg = await page(true); await pg.waitForSelector('#empty:not([hidden])'); await shot(pg, 'hub-empty');
      await pg.tap('[data-tab=shots]'); await pg.waitForSelector('#shotsEmpty:not([hidden])'); await wait(300); await shot(pg, 'shots-empty');
      await pg.close();
    });
    await withMock('offline', async () => {
      const pg = await page(true); await pg.waitForSelector('#skel');
      await wait(300); await pg.evaluate(async () => { await loadList(); await loadList(); }); await wait(500);
      await shot(pg, 'hub-offline');
      await pg.close();
    });
  }
} finally { await browser.close(); }
