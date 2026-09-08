import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';

/**
 * The unread dot and the bulk checkbox are two children of one 20x20 grid
 * cell, and bulk mode used to hide the dot to make room. The rule that did
 * it was one line of CSS, which no rendering test can see: jsdom does not
 * apply stylesheets. These hold the sheet to giving each control its own
 * column instead (#1427).
 */
const css = readFileSync(path.resolve('src/Email/Messages/Envelopes.css'), 'utf8');

describe('Envelopes.css leading cell', () => {
  it('does not hide the unread dot in bulk mode', () => {
    expect(css).not.toMatch(/\.envelope-list\.bulk-mode\s+\.envelope-dot\s*\{[^}]*opacity:\s*0/);
  });

  it('gives the dot and the checkbox their own columns in bulk mode', () => {
    expect(css).toMatch(/\.envelope-list\.bulk-mode\s+\.envelope-dot\s*\{[^}]*grid-area:\s*1\s*\/\s*1/);
    expect(css).toMatch(/\.envelope-list\.bulk-mode\s+\.envelope-checkbox\s*\{[^}]*grid-area:\s*1\s*\/\s*2/);
  });

  it('widens the leading cell and the row to hold both', () => {
    expect(css).toMatch(/\.envelope-list\.bulk-mode\s+\.envelope-leading\s*\{[^}]*grid-template-columns:\s*6px\s+15px/);
    expect(css).toMatch(/\.envelope-list\.bulk-mode\s+\.envelope-content\s*\{[^}]*grid-template-columns:\s*30px/);
  });
});
