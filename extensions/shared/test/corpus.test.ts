// @vitest-environment jsdom
/**
 * Corpus regression test (Phase 4.5): every fixture under
 * extensions/fixtures/ must classify as its directory says. The synthetic/
 * tree is hand-authored seed material; captured real-site snapshots (via
 * scripts/snapshot.mjs) land as sibling category dirs and are picked up
 * automatically. Tuning the weights means making the whole corpus pass.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { isRendered } from '../src/content/controller';
import { scoreForm } from '../src/detect/scorer';

const FIXTURES_ROOT = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  '..',
  'fixtures',
);
const CATEGORIES = ['signup', 'signin', 'ambiguous'] as const;

function fixtureSets(): { file: string; expected: string; html: string }[] {
  const out: { file: string; expected: string; html: string }[] = [];
  for (const tree of readdirSync(FIXTURES_ROOT)) {
    for (const category of CATEGORIES) {
      let files: string[] = [];
      try {
        files = readdirSync(join(FIXTURES_ROOT, tree, category));
      } catch {
        continue;
      }
      for (const file of files.filter((f) => f.endsWith('.html'))) {
        out.push({
          file: `${tree}/${category}/${file}`,
          expected: category,
          html: readFileSync(join(FIXTURES_ROOT, tree, category, file), 'utf8'),
        });
      }
    }
  }
  return out;
}

describe('detector corpus', () => {
  const fixtures = fixtureSets();

  it('has fixtures to run against', () => {
    expect(fixtures.length).toBeGreaterThan(0);
  });

  for (const fixture of fixtures) {
    it(`classifies ${fixture.file} as ${fixture.expected}`, () => {
      document.documentElement.innerHTML = fixture.html;
      const url =
        document
          .querySelector('meta[name="fixture-url"]')
          ?.getAttribute('content') ?? 'https://example.com/';
      const forms = Array.from(document.querySelectorAll('form'));
      expect(forms.length).toBeGreaterThan(0);
      // The controller's own predicate, not a copy: a fixture must be judged
      // on the form the content script would actually pick, and a second
      // implementation here would drift from it (#1393).
      //
      // Its reach here is narrower than at runtime. jsdom does no layout, but
      // it does apply inline `style` attributes and embedded <style> blocks to
      // computed style -- and it does NOT fetch external stylesheets. A real
      // site that hides its sign-up modal from a linked CSS file therefore
      // looks visible to this test however faithfully it was captured, which
      // is why the regression fixture for that shape is synthetic and hides
      // its modal with an embedded rule.
      const rendered = forms.filter((form) => isRendered(form, document));
      const scores = rendered.map((form) => scoreForm(form, { url, document }));
      // A fixture passes when its primary auth form (the first rendered form
      // with an email field) gets the expected label.
      const primary = scores.find((s) => s.emailField !== null);
      expect(primary, 'no form with an email field').toBeDefined();
      expect(primary?.classification, JSON.stringify(primary?.signals)).toBe(
        fixture.expected,
      );
    });
  }
});
