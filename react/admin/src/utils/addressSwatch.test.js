import { describe, it, expect } from 'vitest';
import {
  ADDRESS_SWATCH_COUNT,
  ADDRESS_SWATCHES,
  swatchIndexFor,
  swatchFor,
} from './addressSwatch';

describe('addressSwatch', () => {
  it('exposes exactly four swatches matching the prototype', () => {
    expect(ADDRESS_SWATCH_COUNT).toBe(4);
    expect(ADDRESS_SWATCHES).toHaveLength(4);
  });

  it('is stable for the same address', () => {
    const addr = 'chris@main.cabalmail.com';
    const a = swatchIndexFor(addr);
    const b = swatchIndexFor(addr);
    expect(a).toBe(b);
  });

  it('is case-insensitive', () => {
    const lower = swatchIndexFor('me@inbox.cabalmail.com');
    const upper = swatchIndexFor('ME@INBOX.CABALMAIL.COM');
    expect(lower).toBe(upper);
  });

  it('returns an index inside [0, 4)', () => {
    const samples = [
      'a', 'ab', 'abcde',
      'me@inbox.cabalmail.com',
      'ops@team.cabalmail.com',
      'hello@public.cabalmail.com',
      'x@y.z',
      '1234@567.cabalmail.com',
    ];
    for (const s of samples) {
      const idx = swatchIndexFor(s);
      expect(idx).toBeGreaterThanOrEqual(0);
      expect(idx).toBeLessThan(ADDRESS_SWATCH_COUNT);
    }
  });

  it('distributes a realistic pool of addresses across all four swatches', () => {
    const services = [
      'github', 'linkedin', 'stripe', 'aws', 'figma', 'vercel',
      'cloudflare', 'netlify', 'notion', 'slack', 'twilio', 'sentry',
      'newsletter-hn', 'newsletter-tldr', 'substack-patio11',
      'delta', 'united', 'marriott', 'airbnb', 'uber', 'lyft',
      'costco', 'amazon', 'amex', 'chase', 'vanguard',
    ];
    const seen = new Set();
    for (const s of services) {
      seen.add(swatchIndexFor(`${s}@inbox.cabalmail.com`));
    }
    expect(seen.size).toBe(ADDRESS_SWATCH_COUNT);
  });

  it('swatchFor resolves to one of the declared swatches', () => {
    const colour = swatchFor('me@inbox.cabalmail.com');
    expect(ADDRESS_SWATCHES).toContain(colour);
  });

  it('handles empty and null input without throwing', () => {
    expect(() => swatchFor('')).not.toThrow();
    expect(() => swatchFor(null)).not.toThrow();
    expect(() => swatchFor(undefined)).not.toThrow();
  });
});
