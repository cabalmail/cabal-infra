/**
 * Which Cabalmail deployment this install talks to.
 *
 * The control domain used to be a build constant, which made every bundle
 * environment-specific. That is untenable once the extension ships inside
 * the mail apps: those are deliberately environment-agnostic — the user
 * types a control domain at sign-in and nothing about prod or stage is
 * compiled in — so an appex with a domain baked at build time would make
 * every mail release environment-specific too.
 *
 * So the domain is resolved at runtime: whatever was stored for this
 * install, falling back to the value baked at build time when there is one.
 * The build default is what lets a store-listed Chrome build work out of
 * the box for the operator who published it; a build made without it (the
 * `cabalmail.example` placeholder) has no default and must be told.
 *
 * Safari's embedded build gets the value from the mail app through the
 * shared App Group; Chrome asks in the popup.
 */

import browser from 'webextension-polyfill';

const DOMAIN_KEY = 'cabalmail.controlDomain';

/** The deliberately non-functional default in `build-extension.mjs`. */
const PLACEHOLDER_DOMAIN = 'cabalmail.example';

declare const __CONTROL_DOMAIN__: string;

/**
 * Reduce user input to a bare domain: people paste URLs, type the admin
 * host they see in the address bar, and add trailing slashes.
 */
export function normalizeControlDomain(raw: string): string | null {
  let value = raw.trim().toLowerCase();
  if (!value) return null;
  value = value.replace(/^[a-z]+:\/\//, '').replace(/\/.*$/, '');
  // `admin.` is the API host, not the control domain; accepting it saves a
  // confusing failure for anyone copying from the browser's address bar.
  value = value.replace(/^admin\./, '');
  if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(value)) {
    return null;
  }
  return value;
}

/** The build-time default, or null when the build carries the placeholder. */
export function buildDefaultDomain(): string | null {
  const baked = typeof __CONTROL_DOMAIN__ === 'string' ? __CONTROL_DOMAIN__ : '';
  if (!baked || baked === PLACEHOLDER_DOMAIN) return null;
  return baked;
}

/** The domain this install should use, or null when it has not been told. */
export async function resolveControlDomain(): Promise<string | null> {
  const stored = await browser.storage.local.get(DOMAIN_KEY);
  const value = stored[DOMAIN_KEY];
  if (typeof value === 'string' && value) return value;
  return buildDefaultDomain();
}

/** Persist an explicit choice, overriding any build default. */
export async function saveControlDomain(domain: string): Promise<void> {
  const normalized = normalizeControlDomain(domain);
  if (!normalized) throw new Error(`not a domain: ${domain}`);
  await browser.storage.local.set({ [DOMAIN_KEY]: normalized });
}

export async function clearControlDomain(): Promise<void> {
  await browser.storage.local.remove(DOMAIN_KEY);
}

/** Every origin the extension needs granted for a given deployment. */
export function requiredOrigins(controlDomain: string): string[] {
  return [`https://admin.${controlDomain}/*`, 'https://*.amazoncognito.com/*'];
}
