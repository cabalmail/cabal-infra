// @vitest-environment jsdom
/**
 * The redirector page itself (terraform/infra/modules/app/templates/
 * private-link.html), rendered in jsdom.
 *
 * It is the graceful degradation for every case where nothing intercepted
 * the navigation, and since #1765 it has two fragment forms to tell apart:
 * a url-encoded target, which it offers as a link, and an opaque token,
 * which only the Cabalmail app can resolve -- so it must say so rather
 * than show the token or claim the scheme is unsafe. The page is served
 * from S3 as a Terraform-managed object, so this suite is its only gate.
 */

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const PAGE = readFileSync(
  join(REPO_ROOT, 'terraform/infra/modules/app/templates/private-link.html'),
  'utf8',
);
const TOKEN = '0123456789abcdef0123456789abcdef';

/** The page's markup, and its inline script, taken apart once. */
const MARKUP = PAGE.replace(/^[\s\S]*?<html[^>]*>/, '').replace(/<\/html>[\s\S]*$/, '');
const SCRIPT = /<script>([\s\S]*?)<\/script>/.exec(PAGE)?.[1] ?? '';

/**
 * Install the page, point `location.hash` at `fragment`, then run its
 * inline script -- the environment's own jsdom rather than an imported
 * one, which keeps the suite off a type-less dependency. The script is an
 * IIFE reading `window.location.hash`, so this is the same order the
 * browser does it in.
 */
function render(fragment: string): Document {
  // Floor, so a renamed template or a moved script tag reads as a failure
  // rather than as four clean passes over an empty page.
  expect(MARKUP.length).toBeGreaterThan(500);
  expect(SCRIPT.length).toBeGreaterThan(500);
  document.documentElement.innerHTML = MARKUP;
  window.location.hash = fragment ? `#${fragment}` : '';
  new Function(SCRIPT)();
  return document;
}

const text = (doc: Document, id: string) => doc.getElementById(id)?.textContent ?? '';
const hidden = (doc: Document, id: string) =>
  (doc.getElementById(id) as HTMLElement | null)?.hidden;

describe('the redirector page', () => {
  it('offers a fragment-borne target as a link', () => {
    const target = 'https://example.com/page?q=a%20b';
    const doc = render(encodeURIComponent(target));
    expect(text(doc, 'target-display')).toBe(target);
    expect(doc.getElementById('open-link')?.getAttribute('href')).toBe(target);
    expect(hidden(doc, 'open-link')).toBe(false);
    expect(hidden(doc, 'copy-link')).toBe(false);
    expect(doc.querySelector('.error')).toBeNull();
  });

  it('says only Cabalmail can resolve a token, and never shows it', () => {
    const doc = render(TOKEN);
    expect(text(doc, 'explain')).toContain("doesn't carry the link itself");
    // The token is a key to the link for as long as it lives; the whole
    // point of this form is that what lands in history reveals nothing.
    expect(doc.body.textContent).not.toContain(TOKEN);
    expect(hidden(doc, 'target-display')).toBe(true);
    expect(hidden(doc, 'open-link')).toBe(true);
    expect(hidden(doc, 'copy-link')).toBe(true);
    // Not the scheme complaint: nothing is wrong with the link.
    expect(doc.querySelector('.error')).toBeNull();
  });

  it('still refuses a target whose scheme cannot be opened safely', () => {
    const doc = render(encodeURIComponent('javascript:alert(1)'));
    expect(doc.querySelector('.error')?.textContent).toContain('cannot be opened safely');
    expect(hidden(doc, 'open-link')).toBe(true);
  });

  it('leaves the empty fragment alone', () => {
    const doc = render('');
    expect(text(doc, 'target-display')).toBe('(no link)');
    expect(hidden(doc, 'open-link')).toBe(true);
    expect(doc.querySelector('.error')).toBeNull();
  });
});
