/**
 * Runtime configuration. The only build-time value is the control domain
 * (Vite-injected `__CONTROL_DOMAIN__`); everything else comes from the
 * Terraform-generated `config.json` on the admin origin, cached in
 * browser.storage.local with a 24h soft expiry (serve stale when offline).
 */

import browser from 'webextension-polyfill';
import type { RuntimeConfig } from '../models/index';

const CACHE_KEY = 'cabalmail.config';
const SOFT_EXPIRY_MS = 24 * 60 * 60 * 1000;
const CONFIG_FETCH_TIMEOUT_MS = 10_000;

/** Raw shape of the Terraform-generated config.json. */
interface RawConfig {
  control_domain: string;
  domains: { domain: string }[];
  invokeUrl?: string;
  cognitoConfig: {
    region: string;
    poolData: { UserPoolId: string; ClientId: string };
    extensionClientId?: string;
    hostedUiDomain?: string;
  };
}

export function parseRawConfig(raw: RawConfig): RuntimeConfig {
  const region = raw.cognitoConfig.region;
  const hostedUiDomain = raw.cognitoConfig.hostedUiDomain ?? null;
  return {
    controlDomain: raw.control_domain,
    apiUrl: `https://admin.${raw.control_domain}/prod`,
    userPoolId: raw.cognitoConfig.poolData.UserPoolId,
    extensionClientId: raw.cognitoConfig.extensionClientId ?? null,
    authDomain: hostedUiDomain ? `${hostedUiDomain}.auth.${region}.amazoncognito.com` : null,
    region,
    apexDomains: raw.domains.map((d) => d.domain),
  };
}

interface CachedConfig {
  fetchedAt: number;
  config: RuntimeConfig;
}

export class ConfigService {
  constructor(private readonly controlDomain: string) {}

  private async readCache(): Promise<CachedConfig | null> {
    const stored = await browser.storage.local.get(CACHE_KEY);
    return (stored[CACHE_KEY] as CachedConfig | undefined) ?? null;
  }

  private async fetchFresh(): Promise<RuntimeConfig> {
    const url = `https://admin.${this.controlDomain}/config.json`;
    // Bounded: a background worker with no host permission for the admin
    // origin (Safari grants those per site, at the user's discretion) can
    // otherwise leave this hanging forever, which surfaces as a UI that
    // silently does nothing rather than an error the user can act on.
    let resp: Response;
    try {
      resp = await fetch(url, { signal: AbortSignal.timeout(CONFIG_FETCH_TIMEOUT_MS) });
    } catch (err) {
      const reason = err instanceof Error && err.name === 'TimeoutError' ? 'timed out' : String(err);
      throw new Error(`config.json fetch failed: ${reason}`);
    }
    if (!resp.ok) throw new Error(`config.json fetch failed: ${resp.status}`);
    const config = parseRawConfig((await resp.json()) as RawConfig);
    const cached: CachedConfig = { fetchedAt: Date.now(), config };
    await browser.storage.local.set({ [CACHE_KEY]: cached });
    return config;
  }

  /** Fresh-if-stale, cached-if-offline. */
  async get(): Promise<RuntimeConfig> {
    const cached = await this.readCache();
    if (cached && Date.now() - cached.fetchedAt < SOFT_EXPIRY_MS) return cached.config;
    try {
      return await this.fetchFresh();
    } catch (err) {
      if (cached) return cached.config;
      throw err;
    }
  }
}
