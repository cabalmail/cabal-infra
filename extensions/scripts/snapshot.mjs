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
  // `networkidle` never settles on pages with long-polling or analytics
  // beacons, so treat the quiet period as a best-effort extra: load first,
  // then give client-rendered forms a chance to appear, then continue
  // regardless.
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForLoadState('networkidle', { timeout: 10_000 }).catch(() => {});
  // `attached`, not the default `visible`: we are capturing markup, not
  // interacting, and the first form on a page is very often a hidden one
  // (a collapsed search box, a CSRF stub). Waiting for visibility fails the
  // capture on pages whose auth form is present and perfectly usable.
  await page.waitForSelector('form', { state: 'attached', timeout: 15_000 });
  // eslint-disable-next-line no-undef -- runs in the page, where document exists
  const html = await page.evaluate(() => document.documentElement.outerHTML);
  const title = await page.title();

  // Script bodies are dropped: no detector signal reads them (the engine
  // works from attributes, structure, and text), they are the second-largest
  // contributor to fixture size, and a corpus is a poor place to accumulate
  // executable third-party code in a public repository. The elements and
  // their attributes stay, so document structure is unchanged.
  const stripped = html.replace(
    /(<script\b[^>]*>)[\s\S]*?(<\/script\b[^>]*>)/gi,
    (_match, open, close) => `${open}${close}`,
  );

  const out = [
    '<!DOCTYPE html>',
    `<!-- captured from ${url} on ${new Date().toISOString().slice(0, 10)} -->`,
    stripped.replace(
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
