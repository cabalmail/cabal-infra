/** Token persistence and expiry inspection for the Cognito session. */

import browser from 'webextension-polyfill';

/** Exported so UI contexts can watch it via `storage.onChanged`. */
export const TOKEN_KEY = 'cabalmail.tokens';

export interface TokenSet {
  idToken: string;
  accessToken: string;
  refreshToken: string | null;
}

export async function loadTokens(): Promise<TokenSet | null> {
  const stored = await browser.storage.local.get(TOKEN_KEY);
  return (stored[TOKEN_KEY] as TokenSet | undefined) ?? null;
}

export async function saveTokens(tokens: TokenSet): Promise<void> {
  await browser.storage.local.set({ [TOKEN_KEY]: tokens });
}

export async function clearTokens(): Promise<void> {
  await browser.storage.local.remove(TOKEN_KEY);
}

/** Decode a JWT's payload without verifying (we only read `exp` locally). */
export function decodeJwtPayload(jwt: string): Record<string, unknown> | null {
  const part = jwt.split('.')[1];
  if (!part) return null;
  try {
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(atob(b64)) as Record<string, unknown>;
  } catch {
    return null;
  }
}

/** True when the token expires within `windowMs` (default 5 minutes). */
export function expiresSoon(jwt: string, windowMs = 5 * 60 * 1000, now = Date.now()): boolean {
  const payload = decodeJwtPayload(jwt);
  const exp = typeof payload?.exp === 'number' ? payload.exp : null;
  if (exp === null) return true;
  return exp * 1000 - now < windowMs;
}
