// Pure helpers for the fixture snapshot tool (scripts/snapshot.mjs).
//
// They live apart from the script so the two decisions a capture gets wrong
// silently — "why did this page not yield a form?" and "which stylesheets
// does the fixture still depend on a network fetch for?" — are testable
// without driving a browser. See shared/test/snapshotCapture.test.ts.

// Titles a bot interstitial serves in place of the page. The status alone is
// not enough: a challenge answers 403 like an ordinary refusal does, and a
// plain 200 page can carry one too.
const CHALLENGE_TITLES = [
  /^just a moment/i,
  /^checking your browser/i,
  /^attention required/i,
  /^access denied/i,
  /^one more step/i,
];

/**
 * Classify a navigation from what the response and the document say about
 * themselves, so a capture that fails can name the reason instead of
 * reporting the selector that timed out.
 *
 * A challenge is read off the TITLE, not the status: it answers 403 the way
 * an ordinary refusal does, so the status alone cannot tell them apart.
 *
 * @param {{status: number, title: string}} nav
 * @returns {{challenged: boolean, refused: boolean, summary: string}}
 */
export function describeNavigation({ status, title }) {
  return {
    challenged: CHALLENGE_TITLES.some((pattern) => pattern.test(title.trim())),
    refused: status >= 400,
    summary: `HTTP ${status}, title ${JSON.stringify(title)}`,
  };
}

/**
 * The message a failed capture exits with. The reported failure was a bare
 * `waitForSelector` timeout that named the selector and nothing else, while
 * the response the tool already held said 403 and the document said
 * "Just a moment...".
 *
 * @param {{status: number, title: string, selector: string, headed: boolean}} context
 * @returns {string}
 */
export function captureFailureMessage({ status, title, selector, headed }) {
  const { challenged, refused, summary } = describeNavigation({ status, title });
  const lines = [`[snapshot] no ${selector} found: ${summary}`];
  if (challenged) {
    lines.push('That title is a bot interstitial, not the page you asked for.');
  } else if (refused) {
    lines.push('The server refused the request, which a bot interstitial also does.');
  } else {
    lines.push(`The page loaded but has no ${selector} within the wait.`);
  }
  if ((challenged || refused) && !headed) {
    lines.push('Re-run with --headed: a visible browser is often served the real page.');
  } else if (challenged || refused) {
    lines.push('The capture already ran headed, so this site refuses this browser outright.');
  }
  return lines.join('\n');
}

// A stylesheet whose text could end the element it is being inlined into
// cannot be inlined safely, and CSS has no escape for the sequence outside a
// string. Vanishingly rare, and reported rather than silently mangled.
const STYLE_TERMINATOR = /<\/style/i;

/**
 * Rewrite `url(...)` targets so an inlined sheet still points where it did
 * when it was fetched: once inside the document they would otherwise resolve
 * against the fixture's own path.
 *
 * @param {string} css
 * @param {string} baseHref
 * @returns {string}
 */
export function absolutizeCssUrls(css, baseHref) {
  return css.replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/gi, (match, quote, target) => {
    if (/^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i.test(target)) return match;
    try {
      return `url(${quote}${new URL(target, baseHref).href}${quote})`;
    } catch {
      return match;
    }
  });
}

/**
 * Replace every `<link rel=stylesheet>` whose text we managed to fetch with
 * an inline `<style>`, so the fixture carries its own CSS.
 *
 * A capture served from localhost re-requests these hrefs, and a site that
 * challenges the capture challenges them too (measured on Stack Overflow:
 * four sheets, `ERR_BLOCKED_BY_RESPONSE.NotSameOrigin` behind a 403 carrying
 * `cross-origin-resource-policy: same-origin`). Whatever those rules decided
 * — `visibility`, `display` — is then absent from the fixture.
 *
 * @param {string} html
 * @param {Map<string, string>} cssByHref fetched sheet text, keyed by the href as the page resolved it
 * @returns {{html: string, inlined: string[], skipped: Array<{href: string, reason: string}>}}
 */
export function inlineStylesheets(html, cssByHref) {
  const inlined = [];
  const skipped = [];
  const rewritten = html.replace(/<link\b[^>]*>/gi, (tag) => {
    const rel = /\brel\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(tag);
    const relValue = rel ? (rel[1] ?? rel[2] ?? rel[3] ?? '') : '';
    if (!/(?:^|\s)stylesheet(?:\s|$)/i.test(relValue)) return tag;
    const href = /\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(tag);
    const hrefValue = href ? (href[1] ?? href[2] ?? href[3] ?? '') : '';
    const css = cssByHref.get(hrefValue);
    if (css === undefined) {
      skipped.push({ href: hrefValue, reason: 'not fetched' });
      return tag;
    }
    if (STYLE_TERMINATOR.test(css)) {
      skipped.push({ href: hrefValue, reason: 'contains </style' });
      return tag;
    }
    inlined.push(hrefValue);
    const escapedHref = hrefValue.replaceAll('&', '&amp;').replaceAll('"', '&quot;');
    return `<style data-fixture-inlined-from="${escapedHref}">\n${absolutizeCssUrls(css, hrefValue)}\n</style>`;
  });
  return { html: rewritten, inlined, skipped };
}
