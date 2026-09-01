/**
 * The control domain is chosen at runtime rather than compiled in, so that
 * one build serves any deployment — and so the extension can be embedded in
 * the mail apps, which are themselves environment-agnostic.
 */

import { beforeEach, describe, expect, it } from 'vitest';
import {
  clearControlDomain,
  normalizeControlDomain,
  requiredOrigins,
  resolveControlDomain,
  saveControlDomain,
} from '../src/config/controlDomain';
import { resetStorage } from './support/browser-stub';

beforeEach(() => {
  resetStorage();
});

describe('normalizeControlDomain', () => {
  it('accepts a bare domain', () => {
    expect(normalizeControlDomain('cabalmail.net')).toBe('cabalmail.net');
  });

  it('reduces what people actually paste', () => {
    // A pasted admin URL is the likeliest input: it is what the user sees
    // in the address bar of the app they already use.
    expect(normalizeControlDomain('https://admin.cabalmail.net/')).toBe('cabalmail.net');
    expect(normalizeControlDomain('  HTTPS://Admin.Cabalmail.NET/prod  ')).toBe(
      'cabalmail.net',
    );
    expect(normalizeControlDomain('admin.cabal-mail.example')).toBe('cabal-mail.example');
  });

  it('rejects things that are not domains', () => {
    for (const bad of ['', '   ', 'localhost', 'not a domain', 'https://', '.com', 'a..b']) {
      expect(normalizeControlDomain(bad), bad).toBeNull();
    }
  });
});

describe('resolveControlDomain', () => {
  it('is null before the install has been told anything', async () => {
    // No stored value, and the test build carries no baked default.
    expect(await resolveControlDomain()).toBeNull();
  });

  it('returns what was saved, normalized', async () => {
    await saveControlDomain('https://admin.cabalmail.net/');
    expect(await resolveControlDomain()).toBe('cabalmail.net');
  });

  it('refuses to save something that is not a domain', async () => {
    await expect(saveControlDomain('nope')).rejects.toThrow('not a domain');
    expect(await resolveControlDomain()).toBeNull();
  });

  it('forgets the deployment on clear', async () => {
    await saveControlDomain('cabalmail.net');
    await clearControlDomain();
    expect(await resolveControlDomain()).toBeNull();
  });
});

describe('requiredOrigins', () => {
  it('covers the admin origin and the Hosted UI', () => {
    expect(requiredOrigins('cabalmail.net')).toEqual([
      'https://admin.cabalmail.net/*',
      'https://*.amazoncognito.com/*',
    ]);
  });
});
