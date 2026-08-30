// Fixture snapshot tool (docs/1.x/browser-extension-plan.md, Phase 4.4):
// captures a live page's rendered HTML into the detector corpus.
//
//   node scripts/snapshot.mjs https://github.com/signup captured/signup/github-2026-08.html
//
// The output path is relative to extensions/fixtures/ and its middle
// directory (signup/signin/ambiguous) is the expected classification the
// corpus test asserts. Playwright is deliberately NOT a workspace
// dependency (its browser downloads are heavy and capture is a manual,
// occasional task): `npm i -D playwright && npx playwright install
// chromium` in extensions/ before first use.

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const [url, outRelative] = process.argv.slice(2);
if (!url || !outRelative) {
  console.error('usage: snapshot.mjs <url> <tree/{signup|signin|ambiguous}/name.html>');
  process.exit(2);
}
if (!/\/(signup|signin|ambiguous)\//.test(`/${outRelative}`)) {
  console.error('output path must contain a signup/, signin/, or ambiguous/ segment');
  process.exit(2);
}

let chromium;
try {
  ({ chromium } = await import('playwright'));
} catch {
  console.error(
    'playwright is not installed. Run: npm i -D playwright && npx playwright install chromium',
  );
  process.exit(1);
}

const browser = await chromium.launch();
try {
  const page = await browser.newPage();
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.waitForSelector('form', { timeout: 15_000 });
  // eslint-disable-next-line no-undef -- runs in the page, where document exists
  const html = await page.evaluate(() => document.documentElement.outerHTML);
  const title = await page.title();

  const out = [
    '<!DOCTYPE html>',
    `<!-- captured from ${url} on ${new Date().toISOString().slice(0, 10)} -->`,
    html.replace(
      /<head([^>]*)>/i,
      `<head$1>\n<meta name="fixture-url" content="${url}">` +
        `\n<meta name="fixture-title" content="${title.replaceAll('"', '&quot;')}">`,
    ),
    '',
  ].join('\n');

  const here = dirname(fileURLToPath(import.meta.url));
  const target = resolve(join(here, '..', 'fixtures', outRelative));
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, out);
  console.log(`[snapshot] ${url} -> ${target}`);
} finally {
  await browser.close();
}
