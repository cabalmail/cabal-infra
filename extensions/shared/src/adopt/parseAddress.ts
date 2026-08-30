/**
 * Adopt-flow address parsing: decide whether a typed value looks like a
 * Cabalmail address (`<local>@<subdomain>.<apex>`) on one of the user's
 * authorized apex domains. Apex-shaped addresses (no subdomain) are
 * deliberately uninteresting — Cabalmail has no apex addressing.
 */

export interface ParsedCabalAddress {
  local: string;
  subdomain: string;
  apex: string;
  address: string;
}

export type AdoptParse =
  | { kind: 'not-an-address' }
  | { kind: 'foreign' } // parses, but not on an authorized apex
  | { kind: 'apex' } // on an authorized apex but with no subdomain
  | { kind: 'cabalmail'; parsed: ParsedCabalAddress };

const ADDRESS_RE = /^([^\s@]+)@([^\s@]+\.[^\s@]+)$/;

export function parseTypedAddress(value: string, apexDomains: string[]): AdoptParse {
  const match = ADDRESS_RE.exec(value.trim().toLowerCase());
  if (!match) return { kind: 'not-an-address' };
  const local = match[1] as string;
  const host = match[2] as string;

  // Longest-match against the apex list so multi-label apexes work.
  const apex = apexDomains
    .map((d) => d.toLowerCase())
    .filter((d) => host === d || host.endsWith(`.${d}`))
    .sort((a, b) => b.length - a.length)[0];
  if (!apex) return { kind: 'foreign' };
  if (host === apex) return { kind: 'apex' };

  const subdomain = host.slice(0, host.length - apex.length - 1);
  return {
    kind: 'cabalmail',
    parsed: { local, subdomain, apex, address: `${local}@${host}` },
  };
}
