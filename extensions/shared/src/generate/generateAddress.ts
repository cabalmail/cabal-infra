/**
 * Random address generation, mirroring react/admin/src/Addresses/Request.jsx:
 * 8-char local part (first/last alphanumeric, middle allows `.`, `_`, `-`) and
 * 8-char subdomain (first/last alphanumeric, middle allows `-` only).
 * Pure client-side; regenerating a suggestion never touches the API.
 */

const ALPHANUM = 'abcdefghijklmnopqrstuvwxyz0123456789';
const LOCAL_MID = ALPHANUM + '._-';
const SUBDOMAIN_MID = ALPHANUM + '-';

export interface GeneratedAddress {
  local: string;
  subdomain: string;
  address: string;
}

/** Uniformly pick `count` characters from `pool` using crypto randomness. */
function randomFromPool(pool: string, count: number): string {
  const out: string[] = [];
  // Rejection sampling to avoid modulo bias.
  const max = Math.floor(256 / pool.length) * pool.length;
  const buf = new Uint8Array(count * 2);
  while (out.length < count) {
    crypto.getRandomValues(buf);
    for (const byte of buf) {
      if (byte < max) {
        out.push(pool[byte % pool.length] as string);
        if (out.length === count) break;
      }
    }
  }
  return out.join('');
}

export function generateAddress(apex: string): GeneratedAddress {
  const local =
    randomFromPool(ALPHANUM, 1) + randomFromPool(LOCAL_MID, 6) + randomFromPool(ALPHANUM, 1);
  const subdomain =
    randomFromPool(ALPHANUM, 1) + randomFromPool(SUBDOMAIN_MID, 6) + randomFromPool(ALPHANUM, 1);
  return { local, subdomain, address: `${local}@${subdomain}.${apex}` };
}

/** Validation shape shared with the React admin app's request form. */
export const LOCAL_PART_RE = /^[a-z0-9][a-z0-9._-]{6}[a-z0-9]$/;
export const SUBDOMAIN_RE = /^[a-z0-9][a-z0-9-]{6}[a-z0-9]$/;
