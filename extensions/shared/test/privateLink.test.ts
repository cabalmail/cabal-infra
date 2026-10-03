/**
 * The private-link fragment, both forms. The token form exists because
 * WebKit implements no `history` API (#1765): on Safari the redirector's
 * normal-window history entry cannot be removed, so the fragment that
 * lands there must not be worth reading, and the target comes over the
 * native bridge instead.
 */

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  allowedPrivateLinkTarget,
  forgetPrivateLinkToken,
  parsePrivateLinkFragment,
  PRIVATE_LINK_TOKEN,
  privateLinkTarget,
  resolvePrivateLinkToken,
} from '../src/privateLink/handoff';
import { resetStorage, setNativeResponder } from './support/browser-stub';

const DOMAIN = 'cabalmail.example';
const TOKEN = '0123456789abcdef0123456789abcdef';
const redirector = (fragment: string) =>
  `https://admin.${DOMAIN}/private-link#${fragment}`;

beforeEach(() => {
  resetStorage();
});

describe('parsePrivateLinkFragment', () => {
  it('reads a percent-encoded target', () => {
    expect(parsePrivateLinkFragment(redirector('https%3A%2F%2Fexample.com%2Fa'), DOMAIN)).toEqual({
      kind: 'url',
      url: 'https://example.com/a',
    });
  });

  it('reads a token', () => {
    expect(parsePrivateLinkFragment(redirector(TOKEN), DOMAIN)).toEqual({
      kind: 'token',
      token: TOKEN,
    });
  });

  it('ignores a URL on another origin, and the redirector with no fragment', () => {
    expect(parsePrivateLinkFragment('https://admin.elsewhere.example/private-link#x', DOMAIN))
      .toBeNull();
    expect(parsePrivateLinkFragment(`https://admin.${DOMAIN}/private-link`, DOMAIN)).toBeNull();
  });

  it('does not mistake a percent-encoded URL for a token', () => {
    // The token test is anchored and length-exact; a hex-looking target is
    // still a target. `beefcafe...` is 32 hex characters inside a URL.
    const url = 'https://example.com/beefcafe0123456789abcdef01234567';
    expect(parsePrivateLinkFragment(redirector(encodeURIComponent(url)), DOMAIN)).toEqual({
      kind: 'url',
      url,
    });
  });
});

describe('allowedPrivateLinkTarget', () => {
  it('passes web URLs and rejects everything else', () => {
    expect(allowedPrivateLinkTarget('http://example.com/')).toBe('http://example.com/');
    for (const bad of [
      'javascript:alert(1)',
      ' javascript:alert(1)',
      'data:text/html,x',
      'file:///etc/passwd',
      'about:blank',
      'blob:https://example.com/x',
      'vbscript:x',
      'mailto:a@example.com',
      'not a url',
    ]) {
      expect(allowedPrivateLinkTarget(bad), bad).toBeNull();
    }
  });
});

describe('resolvePrivateLinkToken', () => {
  it('asks the containing app and returns its answer', async () => {
    const seen: unknown[] = [];
    setNativeResponder((message) => {
      seen.push(message);
      return { url: 'https://example.com/secret' };
    });
    expect(await resolvePrivateLinkToken(TOKEN)).toBe('https://example.com/secret');
    expect(seen).toEqual([{ kind: 'resolve-private-link', token: TOKEN }]);
  });

  it('is null where no native host answers', async () => {
    // Chrome and the standalone Safari host: the call rejects.
    expect(await resolvePrivateLinkToken(TOKEN)).toBeNull();
  });

  it('is null for an unknown or expired row', async () => {
    setNativeResponder(() => ({ url: null }));
    expect(await resolvePrivateLinkToken(TOKEN)).toBeNull();
  });
});

describe('privateLinkTarget', () => {
  it('resolves a token to its target and names the token to retire', async () => {
    setNativeResponder(() => ({ url: 'https://example.com/secret' }));
    expect(await privateLinkTarget(redirector(TOKEN), DOMAIN)).toEqual({
      target: 'https://example.com/secret',
      token: TOKEN,
    });
  });

  it('applies the scheme blocklist to the RESOLVED url, not just the fragment', async () => {
    // A token is opaque, so the blocklist cannot be applied before the
    // round-trip the way it can to a fragment-borne target.
    setNativeResponder(() => ({ url: 'javascript:alert(1)' }));
    expect(await privateLinkTarget(redirector(TOKEN), DOMAIN)).toBeNull();
  });

  it('passes a fragment-borne target through with no token to retire', async () => {
    expect(await privateLinkTarget(redirector('https%3A%2F%2Fexample.com%2Fa'), DOMAIN)).toEqual({
      target: 'https://example.com/a',
      token: null,
    });
  });

  it('is null for a token nothing can resolve', async () => {
    expect(await privateLinkTarget(redirector(TOKEN), DOMAIN)).toBeNull();
  });
});

describe('forgetPrivateLinkToken', () => {
  it('tells the app to drop the row', async () => {
    const seen: unknown[] = [];
    setNativeResponder((message) => {
      seen.push(message);
      return { ok: true };
    });
    await forgetPrivateLinkToken(TOKEN);
    expect(seen).toEqual([{ kind: 'forget-private-link', token: TOKEN }]);
  });

  it('swallows the absence of a host', async () => {
    await expect(forgetPrivateLinkToken(TOKEN)).resolves.toBeUndefined();
  });
});

/**
 * The token alphabet is a contract between three files in three languages
 * -- the app that mints it, this module, and the redirector page that has
 * to tell a token from a target without being able to resolve either. A
 * one-sided change would not fail any suite that only reads this side, so
 * the other two are scanned (the pattern of `_RUNBOOK_MAP` vs
 * docs/monitoring.md on the Lambda side).
 */
describe('the token shape agrees across the three implementations', () => {
  const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const read = (rel: string) => {
    const body = readFileSync(join(REPO_ROOT, rel), 'utf8');
    // Corpus floor: a path that silently moved must read as a failure
    // rather than as a clean scan.
    expect(body.length, rel).toBeGreaterThan(500);
    return body;
  };

  it('matches 32 lower-case hex characters and nothing adjacent', () => {
    expect(PRIVATE_LINK_TOKEN.test(TOKEN)).toBe(true);
    expect(PRIVATE_LINK_TOKEN.test(TOKEN.toUpperCase())).toBe(false);
    expect(PRIVATE_LINK_TOKEN.test(TOKEN.slice(1))).toBe(false);
    expect(PRIVATE_LINK_TOKEN.test(TOKEN + '0')).toBe(false);
    expect(PRIVATE_LINK_TOKEN.test('g'.repeat(32))).toBe(false);
  });

  it('is the guard the redirector page applies to the fragment', () => {
    const page = read('terraform/infra/modules/app/templates/private-link.html');
    expect(page).toContain(PRIVATE_LINK_TOKEN.source);
  });

  it('is what the app mints: 16 random bytes as lower-case hex', () => {
    const store = read('apple/Cabalmail/PrivateLinkTokenStore.swift');
    expect(store).toContain('(0..<16)');
    expect(store).toContain('"%02x"');
  });
});
