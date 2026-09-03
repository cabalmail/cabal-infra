// Fixture snapshot tool (docs/1.x/browser-extension-plan.md, Phase 4.4):
// captures a live page's rendered HTML into the detector corpus.
//
//   node scripts/snapshot.mjs [--headed] https://github.com/signup captured/signup/github-2026-08.html
//
// The output path is relative to extensions/fixtures/ and its middle
// directory (signup/signin/ambiguous) is the expected classification the
// corpus test asserts. Playwright is deliberately NOT a workspace
// dependency (its browser downloads are heavy and capture is a manual,
// occasional task): `npm i -D playwright && npx playwright install
// chromium` in extensions/ before first use.
//
// `--headed` runs a visible browser. Some sites serve a bot interstitial to
// headless Chromium and the real page to a headed one (measured on
// stackoverflow.com/users/login: 403 "Just a moment..." headless, 200
// "Log In - Stack Overflow" headed), so it is the first thing to try when a
// capture reports a challenge.

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { captureFailureMessage, inlineStylesheets } from './snapshot-capture.mjs';

const args = process.argv.slice(2);
const headed = args.includes('--headed');
const [url, outRelative] = args.filter((arg) => arg !== '--headed');
if (!url || !outRelative) {
  console.error('usage: snapshot.mjs [--headed] <url> <tree/{signup|signin|ambiguous}/name.html>');
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

const browser = await chromium.launch({ headless: !headed });
let failure = null;
try {
  const page = await browser.newPage();
  // `networkidle` never settles on pages with long-polling or analytics
  // beacons, so treat the quiet period as a best-effort extra: load first,
  // then give client-rendered forms a chance to appear, then continue
  // regardless.
  const response = await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForLoadState('networkidle', { timeout: 10_000 }).catch(() => {});
  // `attached`, not the default `visible`: we are capturing markup, not
  // interacting, and the first form on a page is very often a hidden one
  // (a collapsed search box, a CSRF stub). Waiting for visibility fails the
  // capture on pages whose auth form is present and perfectly usable.
  const sawForm = await page
    .waitForSelector('form', { state: 'attached', timeout: 15_000 })
    .then(() => true)
    .catch(() => false);
  const title = await page.title();
  if (!sawForm) {
    // The response and the document already say why. This used to exit with
    // playwright's bare selector timeout, which names the locator and
    // nothing else — so a challenge and a genuinely form-less page failed
    // identically.
    failure = captureFailureMessage({
      status: response ? response.status() : 0,
      title,
      selector: 'form',
      headed,
    });
  } else {
    // eslint-disable-next-line no-undef -- runs in the page, where document exists
    const html = await page.evaluate(() => document.documentElement.outerHTML);
    const hrefs = await page.evaluate(() =>
      // eslint-disable-next-line no-undef -- runs in the page, where document exists
      [...document.querySelectorAll('link[rel~="stylesheet"]')].map((link) =>
        link.getAttribute('href'),
      ),
    );

    // A fixture is replayed from a different origin than it was captured
    // from, so every external stylesheet is re-requested at replay time and
    // may not arrive — on a challenged site the sheets are served the
    // challenge too. Whatever those rules decided is then missing from the
    // fixture, which is how a modal that computes `visibility: hidden` live
    // reads as visible in the corpus. Fetching them here, from node, where
    // no CORS or cross-origin policy applies, makes the capture carry its
    // own CSS.
    const cssByHref = new Map();
    const fetchFailures = new Map();
    for (const href of hrefs) {
      if (!href) continue;
      const absolute = new URL(href, url).href;
      try {
        const sheet = await fetch(absolute);
        if (!sheet.ok) throw new Error(`HTTP ${sheet.status}`);
        cssByHref.set(href, await sheet.text());
      } catch (error) {
        fetchFailures.set(href, error.message);
      }
    }
    const styled = inlineStylesheets(html, cssByHref);

    // Script bodies are dropped: no detector signal reads them (the engine
    // works from attributes, structure, and text), they are the second-largest
    // contributor to fixture size, and a corpus is a poor place to accumulate
    // executable third-party code in a public repository. The elements and
    // their attributes stay, so document structure is unchanged.
    const stripped = styled.html.replace(
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
    console.log(`[snapshot] stylesheets inlined: ${styled.inlined.length} of ${hrefs.length}`);
    // Say which CSS the fixture still depends on a network fetch for, so a
    // visibility-dependent assertion written against it is a known risk
    // rather than a surprise.
    for (const { href, reason } of styled.skipped) {
      console.warn(`[snapshot] not inlined: ${href} (${fetchFailures.get(href) ?? reason})`);
    }
  }
} finally {
  await browser.close();
}

if (failure) {
  console.error(failure);
  process.exit(1);
}
