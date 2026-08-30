import { describe, expect, it } from 'vitest';
import {
  LOCAL_PART_RE,
  SUBDOMAIN_RE,
  generateAddress,
} from '../src/generate/generateAddress';

describe('generateAddress', () => {
  it('produces 8-char local parts and subdomains matching the admin-app shape', () => {
    for (let i = 0; i < 500; i += 1) {
      const { local, subdomain, address } = generateAddress('cabalmail.com');
      expect(local).toMatch(LOCAL_PART_RE);
      expect(subdomain).toMatch(SUBDOMAIN_RE);
      expect(address).toBe(`${local}@${subdomain}.cabalmail.com`);
    }
  });

  it('handles apexes with hyphens and multiple labels', () => {
    const { address } = generateAddress('my-mail.co.uk');
    expect(address.endsWith('.my-mail.co.uk')).toBe(true);
    const host = address.split('@')[1] as string;
    expect(host.split('.').length).toBe(4);
  });

  it('draws from the full pools over many samples', () => {
    const localChars = new Set<string>();
    const subChars = new Set<string>();
    for (let i = 0; i < 2000; i += 1) {
      const { local, subdomain } = generateAddress('cabalmail.com');
      for (const c of local) localChars.add(c);
      for (const c of subdomain) subChars.add(c);
    }
    // 36 alphanumerics + . _ - in local; 36 + - in subdomain.
    expect(localChars.size).toBeGreaterThan(35);
    expect(localChars.has('.')).toBe(true);
    expect(localChars.has('_')).toBe(true);
    expect(localChars.has('-')).toBe(true);
    expect(subChars.has('-')).toBe(true);
    expect(subChars.has('.')).toBe(false);
    expect(subChars.has('_')).toBe(false);
  });

  it('never places separators at the edges', () => {
    for (let i = 0; i < 500; i += 1) {
      const { local, subdomain } = generateAddress('cabalmail.com');
      expect('._-').not.toContain(local[0]);
      expect('._-').not.toContain(local[7]);
      expect('-').not.toContain(subdomain[0] as string);
      expect('-').not.toContain(subdomain[7] as string);
    }
  });
});
