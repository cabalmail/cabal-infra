/**
 * Manifest/source invariant: an API the code calls must be declared in
 * every manifest that ships it, because WebKit's extension engine hands a
 * context only the APIs its permissions name.
 *
 * #1764 is the failure this pins. `nativeControlDomain()` asks the
 * containing mail app for the control domain through
 * `runtime.sendNativeMessage`, behind an `if (runtime.sendNativeMessage)`
 * guard — and Safari's manifest declared no `nativeMessaging`, so the
 * property was never there, the guard was always false, and the embedded
 * appex fell through to the popup's "which server?" form forever. Nothing
 * caught it because the suites hang `sendNativeMessage` straight off the
 * stub runtime object (`test/support/browser-stub.ts`), where no permission
 * gate exists, and a missing permission costs no exception at runtime.
 *
 * The scan is therefore the only seam: it reads the real manifest
 * templates and the real sources, and answers the question the stubs
 * cannot.
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const WORKSPACE_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SOURCE_ROOTS = ['shared/src', 'chrome/src'] as const;
const BROWSERS = ['chrome', 'safari'] as const;

/**
 * Each entry is "calling this is what requires that permission". Only
 * permission-gated namespaces belong here: `tabs`, `windows`, `runtime` and
 * `permissions` are available to every MV3 extension without a declaration
 * (what `tabs` buys is URL/title access, which this extension takes through
 * `optional_host_permissions` instead).
 */
const GATED_APIS: { permission: string; detector: RegExp }[] = [
  { permission: 'storage', detector: /\b(?:browser|chrome)\.storage\b/ },
  { permission: 'identity', detector: /\b(?:browser|chrome)\.identity\b/ },
  { permission: 'history', detector: /\b(?:browser|chrome)\.history\b/ },
  // The polyfill types stop at the standard surface, so the two native
  // verbs are reached off a locally-narrowed `runtime` rather than
  // `browser.runtime.…` — match the method name, not the namespace.
  { permission: 'nativeMessaging', detector: /\b(?:sendNativeMessage|connectNative)\b/ },
];

/** Comments carry API names in prose; a comment-blind scan accuses the docs. */
function stripComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}

function sourceFiles(): { path: string; body: string }[] {
  const out: { path: string; body: string }[] = [];
  const walk = (rel: string) => {
    for (const entry of readdirSync(join(WORKSPACE_ROOT, rel)).sort()) {
      const childRel = `${rel}/${entry}`;
      if (statSync(join(WORKSPACE_ROOT, childRel)).isDirectory()) {
        walk(childRel);
      } else if (/\.tsx?$/.test(entry)) {
        out.push({
          path: childRel,
          body: stripComments(readFileSync(join(WORKSPACE_ROOT, childRel), 'utf8')),
        });
      }
    }
  };
  for (const root of SOURCE_ROOTS) walk(root);
  return out;
}

function manifestPermissions(browser: string): string[] {
  const raw = readFileSync(
    join(WORKSPACE_ROOT, browser, 'manifest.template.json'),
    'utf8',
  );
  return (JSON.parse(raw).permissions as string[]) ?? [];
}

describe('manifest permissions cover the APIs the code calls', () => {
  const files = sourceFiles();

  it('scans the real source tree', () => {
    // Corpus floor per root, so a walk that silently stops reads as a
    // failure rather than as a clean scan. Measured at the fix: 18 shared,
    // 4 chrome (the whole of `chrome/src` is background, content, overlay
    // and popup).
    const counts = Object.fromEntries(
      SOURCE_ROOTS.map((root) => [root, files.filter((f) => f.path.startsWith(root)).length]),
    );
    expect(counts['shared/src']).toBeGreaterThanOrEqual(15);
    expect(counts['chrome/src']).toBeGreaterThanOrEqual(4);
  });

  it('knows which permission every gated call site needs', () => {
    // The inventory, asserted so a new call site is visible here rather
    // than silently exempt.
    const sites = GATED_APIS.map(({ permission, detector }) => [
      permission,
      files
        .filter((f) => detector.test(f.body))
        .map((f) => f.path)
        .sort(),
    ]);
    expect(Object.fromEntries(sites)).toEqual({
      storage: [
        'chrome/src/popup/popup.tsx',
        'shared/src/auth/HostedUiAuth.ts',
        'shared/src/auth/tokens.ts',
        'shared/src/config/ConfigService.ts',
        'shared/src/config/controlDomain.ts',
      ],
      identity: ['shared/src/auth/webAuthDriver.ts'],
      history: ['chrome/src/background.ts'],
      // Two call sites since #1765: the control-domain handoff and the
      // private-link token resolution, both answered by the appex embedded
      // in the macOS mail app.
      nativeMessaging: [
        'shared/src/config/controlDomain.ts',
        'shared/src/privateLink/handoff.ts',
      ],
    });
  });

  /**
   * What each bundle must declare, and — where a gated call site exists but
   * the permission is deliberately absent — why. An omission with a reason
   * is a decision; an omission without one is #1764.
   */
  const EXPECTED = {
    chrome: {
      permissions: ['storage', 'identity', 'history'] as string[],
      omitted: {
        // No native host is registered for the Chrome build, so the guard
        // in `nativeControlDomain()` is meant to be false there: Chrome
        // asks for the control domain in the popup. Declaring the
        // permission would buy nothing and cost a review prompt.
        nativeMessaging: 'no native host; the popup asks for the domain',
      },
    },
    safari: {
      // `nativeMessaging` is what makes the embedded appex's handoff
      // reachable: WebKit exposes `runtime.sendNativeMessage` only to an
      // extension that declares it.
      permissions: ['storage', 'identity', 'history', 'nativeMessaging'] as string[],
      omitted: {} as Record<string, string>,
    },
  };

  for (const browser of BROWSERS) {
    it(`${browser} declares exactly the permissions it is meant to`, () => {
      // Asserted as a set, so a permission added to a manifest without a
      // call site is as visible as a call site without a permission.
      expect(manifestPermissions(browser).slice().sort()).toEqual(
        EXPECTED[browser].permissions.slice().sort(),
      );
    });

    it(`${browser} declares every permission its call sites need`, () => {
      const declared = manifestPermissions(browser);
      const missing = GATED_APIS.filter(
        ({ permission, detector }) =>
          files.some((f) => detector.test(f.body)) &&
          !declared.includes(permission) &&
          !(permission in EXPECTED[browser].omitted),
      ).map(({ permission }) => permission);
      expect(missing).toEqual([]);
    });
  }

  it('every deliberate omission gives its reason in prose', () => {
    for (const [browser, { omitted }] of Object.entries(EXPECTED)) {
      for (const [permission, reason] of Object.entries(omitted)) {
        expect(reason.length, `${browser}/${permission}`).toBeGreaterThan(20);
      }
    }
  });

  it('detects the call shapes that are really in the tree, and only those', () => {
    // Self-tests: what stops a later rewrite making the detectors vacuous.
    const native = GATED_APIS.find((a) => a.permission === 'nativeMessaging')!.detector;
    expect(native.test('await runtime.sendNativeMessage("application.id", {})')).toBe(true);
    expect(native.test('browser.runtime.connectNative("application.id")')).toBe(true);
    expect(native.test('runtime.sendMessage({ kind: "get-control-domain" })')).toBe(false);
    const history = GATED_APIS.find((a) => a.permission === 'history')!.detector;
    expect(history.test('await browser.history?.deleteUrl({ url })')).toBe(true);
    expect(history.test('const history = useHistory()')).toBe(false);
    // Comment stripping: prose naming an API is not a call site.
    expect(stripComments('// calls browser.history.deleteUrl\nconst a = 1;')).not.toMatch(
      /browser\.history/,
    );
    expect(stripComments('/* browser.identity */\nconst b = 2;')).not.toMatch(
      /browser\.identity/,
    );
  });
});
