import { describe, expect, it } from 'vitest';

import {
  absolutizeCssUrls,
  captureFailureMessage,
  describeNavigation,
  inlineStylesheets,
} from '../../scripts/snapshot-capture.mjs';

// The reported failure, measured on stackoverflow.com/users/login: headless
// Chromium is served a 403 interstitial titled "Just a moment...", headed
// Chromium the real page.
const CHALLENGE = { status: 403, title: 'Just a moment...' };

describe('describeNavigation', () => {
  it('reads a challenge off the title, which the status cannot distinguish', () => {
    expect(describeNavigation(CHALLENGE).challenged).toBe(true);
    // Same status, an ordinary refusal: refused but not a challenge, so the
    // message must not claim an interstitial it has no evidence for.
    expect(describeNavigation({ status: 403, title: 'Forbidden' })).toEqual({
      challenged: false,
      refused: true,
      summary: 'HTTP 403, title "Forbidden"',
    });
  });

  it('does not call an ordinary page a refusal', () => {
    const nav = describeNavigation({ status: 200, title: 'Log In - Stack Overflow' });
    expect(nav).toMatchObject({ challenged: false, refused: false });
  });
});

describe('captureFailureMessage', () => {
  it('names the status and the title instead of the selector alone', () => {
    const message = captureFailureMessage({ ...CHALLENGE, selector: 'form', headed: false });
    expect(message).toContain('HTTP 403');
    expect(message).toContain('Just a moment...');
    expect(message).toContain('--headed');
  });

  it('does not suggest --headed to a capture that already ran headed', () => {
    const message = captureFailureMessage({ ...CHALLENGE, selector: 'form', headed: true });
    expect(message).not.toContain('Re-run with --headed');
    expect(message).toContain('refuses this browser outright');
  });

  it('says the page simply had no form when nothing refused it', () => {
    const message = captureFailureMessage({
      status: 200,
      title: 'Docs',
      selector: 'form',
      headed: false,
    });
    expect(message).toContain('no form found: HTTP 200');
    expect(message).toContain('has no form within the wait');
    expect(message).not.toContain('--headed');
  });
});

describe('inlineStylesheets', () => {
  const page = [
    '<html><head>',
    '<link rel="stylesheet" href="https://example.test/a.css">',
    "<link rel='preload' href='https://example.test/b.css'>",
    '<link rel="alternate stylesheet" href="https://example.test/c.css">',
    '<link rel="icon" href="/favicon.ico">',
    '</head><body></body></html>',
  ].join('\n');

  it('replaces a fetched stylesheet with its text', () => {
    const result = inlineStylesheets(
      page,
      new Map([['https://example.test/a.css', '#modal { visibility: hidden }']]),
    );
    expect(result.html).toContain('<style data-fixture-inlined-from="https://example.test/a.css">');
    expect(result.html).toContain('#modal { visibility: hidden }');
    expect(result.inlined).toEqual(['https://example.test/a.css']);
  });

  it('leaves links that are not stylesheets alone', () => {
    const result = inlineStylesheets(
      page,
      new Map([
        ['https://example.test/b.css', 'a{}'],
        ['/favicon.ico', 'a{}'],
      ]),
    );
    expect(result.inlined).toEqual([]);
    expect(result.html).toContain("<link rel='preload' href='https://example.test/b.css'>");
    expect(result.html).toContain('<link rel="icon" href="/favicon.ico">');
  });

  it('honours a multi-valued rel, which is how rel~=stylesheet matches', () => {
    const result = inlineStylesheets(page, new Map([['https://example.test/c.css', 'a{}']]));
    expect(result.inlined).toEqual(['https://example.test/c.css']);
  });

  it('reports the sheets it could not inline rather than dropping them silently', () => {
    const result = inlineStylesheets(page, new Map());
    expect(result.skipped).toContainEqual({
      href: 'https://example.test/a.css',
      reason: 'not fetched',
    });
    expect(result.html).toContain('<link rel="stylesheet" href="https://example.test/a.css">');
  });

  it('refuses css that would close the style element it is inlined into', () => {
    const result = inlineStylesheets(
      page,
      new Map([['https://example.test/a.css', 'a::before { content: "</style>" }']]),
    );
    expect(result.skipped).toContainEqual({
      href: 'https://example.test/a.css',
      reason: 'contains </style',
    });
    expect(result.html).toContain('<link rel="stylesheet" href="https://example.test/a.css">');
  });
});

describe('absolutizeCssUrls', () => {
  it('resolves relative targets against the sheet, not the fixture', () => {
    expect(
      absolutizeCssUrls('a{background:url(img/x.png)}', 'https://example.test/css/site.css'),
    ).toBe('a{background:url(https://example.test/css/img/x.png)}');
  });

  it('leaves absolute, protocol-relative and fragment targets untouched', () => {
    const css = 'a{background:url("https://cdn.test/x.png")}b{mask:url(//cdn.test/y.svg)}c{fill:url(#g)}';
    expect(absolutizeCssUrls(css, 'https://example.test/css/site.css')).toBe(css);
  });

  it('preserves the quoting style it found', () => {
    expect(absolutizeCssUrls("a{background:url('x.png')}", 'https://example.test/s.css')).toBe(
      "a{background:url('https://example.test/x.png')}",
    );
  });
});
