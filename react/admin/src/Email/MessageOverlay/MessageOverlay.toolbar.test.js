import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';

/**
 * The reader's action bar collapsed its labels on a viewport media query,
 * but the reader is one pane of several: with the addresses sidebar open a
 * 1440px window left it 417px, the labelled bar kept its 562px, and More
 * actions and Close were pushed past `.reader { overflow: hidden }` where no
 * click could reach them (#1606). The rules that fix it are CSS, which jsdom
 * does not apply, so these hold the sheet to them.
 */
const css = readFileSync(path.resolve('src/Email/MessageOverlay/MessageOverlay.css'), 'utf8');

/** The declarations of the rule whose selector starts a line and matches exactly. */
const block = (sheet, selector) => {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const m = sheet.match(new RegExp(`^${escaped}\\s*\\{([^}]*)\\}`, 'm'));
  return m ? m[1] : null;
};

/** Each `@container (max-width: Npx) { ... }` with its width, body and offset. */
const containerQueries = (sheet) =>
  [...sheet.matchAll(/@container\s*\(max-width:\s*(\d+)px\)\s*\{([\s\S]*?)\n\}/g)]
    .map((m) => ({ width: Number(m[1]), body: m[2], index: m.index }));

describe('MessageOverlay.css action bar (#1606)', () => {
  it('is a size container, so it can respond to its own width', () => {
    expect(block(css, '.reader-actions')).toMatch(/container-type:\s*inline-size/);
  });

  it('drops the labels on its own width, after the viewport rule that shows them', () => {
    const shows = css.search(/@media\s*\(min-width:\s*768px\)\s*\{\s*\.reader-actions \.reader-btn \.reader-btn-label\s*\{\s*display:\s*inline/);
    expect(shows).toBeGreaterThan(-1);
    const hides = containerQueries(css).filter((q) =>
      /\.reader-actions \.reader-btn \.reader-btn-label\s*\{\s*display:\s*none/.test(q.body));
    expect(hides).toHaveLength(1);
    // Equal specificity, so source order decides: before the media rule, it loses.
    expect(hides[0].index).toBeGreaterThan(shows);
    // The labelled bar's content measured 538px; a query below that clips again.
    expect(hides[0].width).toBeGreaterThanOrEqual(538);
  });

  it('anchors the Move and More actions popups to the bar when it is narrow', () => {
    // Button-anchored, both open leftwards and ran past the pane's left edge
    // once the labels dropped or the row wrapped.
    const narrow = containerQueries(css).find((q) => /reader-btn-label/.test(q.body));
    expect(narrow.body).toMatch(/\.reader-actions \.reader-move,\s*\.reader-actions \.reader-overflow\s*\{\s*position:\s*static/);
  });

  it('never shrinks a button, and wraps the row instead of clipping it', () => {
    expect(block(css, '.reader-actions .reader-btn')).toMatch(/flex-shrink:\s*0/);
    const bar = block(css, '.reader-actions');
    expect(bar).toMatch(/flex-wrap:\s*wrap/);
    // A fixed height would clip the second row.
    expect(bar).not.toMatch(/(^|[\s;])height:/);
  });

  it('reads the rules it names (detector self-test)', () => {
    const sample = '.reader-actions {\n  height: 48px;\n}\n.reader[data-layout="sheet"] .reader-actions { display: none; }\n@container (max-width: 12px) {\n  .x { a: b; }\n}\n';
    expect(block(sample, '.reader-actions')).toMatch(/height: 48px/);
    expect(block('.a .reader-actions { display: none; }', '.reader-actions')).toBeNull();
    expect(containerQueries(sample)).toEqual([expect.objectContaining({ width: 12 })]);
  });
});
