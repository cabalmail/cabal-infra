import { describe, expect, it } from 'vitest';
import { parseTypedAddress } from '../src/adopt/parseAddress';

const APEXES = ['cabalmail.com', 'my-mail.co.uk'];

describe('parseTypedAddress', () => {
  it('recognizes a Cabalmail-shaped address on an authorized apex', () => {
    const r = parseTypedAddress('test@made-up.cabalmail.com', APEXES);
    expect(r.kind).toBe('cabalmail');
    if (r.kind === 'cabalmail') {
      expect(r.parsed).toEqual({
        local: 'test',
        subdomain: 'made-up',
        apex: 'cabalmail.com',
        address: 'test@made-up.cabalmail.com',
      });
    }
  });

  it('lowercases and trims input', () => {
    const r = parseTypedAddress('  Test@Sub.CABALMAIL.com ', APEXES);
    expect(r.kind).toBe('cabalmail');
    if (r.kind === 'cabalmail') expect(r.parsed.address).toBe('test@sub.cabalmail.com');
  });

  it('classifies apex-shaped addresses as apex (no addressing there)', () => {
    expect(parseTypedAddress('someone@cabalmail.com', APEXES).kind).toBe('apex');
  });

  it('ignores foreign domains', () => {
    expect(parseTypedAddress('someone@gmail.com', APEXES).kind).toBe('foreign');
    // Suffix similarity is not membership.
    expect(parseTypedAddress('a@notcabalmail.com', APEXES).kind).toBe('foreign');
  });

  it('handles multi-label apexes with a longest-match', () => {
    const r = parseTypedAddress('a@shop.my-mail.co.uk', APEXES);
    expect(r.kind).toBe('cabalmail');
    if (r.kind === 'cabalmail') {
      expect(r.parsed.apex).toBe('my-mail.co.uk');
      expect(r.parsed.subdomain).toBe('shop');
    }
  });

  it('supports multi-label subdomains', () => {
    const r = parseTypedAddress('a@deep.sub.cabalmail.com', APEXES);
    expect(r.kind).toBe('cabalmail');
    if (r.kind === 'cabalmail') expect(r.parsed.subdomain).toBe('deep.sub');
  });

  it('rejects non-addresses', () => {
    expect(parseTypedAddress('', APEXES).kind).toBe('not-an-address');
    expect(parseTypedAddress('not an email', APEXES).kind).toBe('not-an-address');
    expect(parseTypedAddress('a@b', APEXES).kind).toBe('not-an-address');
    expect(parseTypedAddress('a@@b.com', APEXES).kind).toBe('not-an-address');
  });
});
