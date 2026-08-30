/**
 * Minimal fetch-based client for the four Lambda endpoints the extension
 * uses. Follows the React admin client's conventions: raw Cognito id token
 * in `Authorization` (no Bearer prefix); one retry after a forced refresh
 * on 401, then the session is treated as expired.
 */

import { AuthError, type HostedUiAuth } from '../auth/HostedUiAuth';
import type { Address } from '../models/index';

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export interface NewAddressRequest {
  username: string;
  subdomain: string;
  tld: string;
  comment?: string;
  pending?: boolean;
}

export class ApiClient {
  constructor(
    private readonly apiUrl: string,
    private readonly auth: HostedUiAuth,
  ) {}

  private async request<T>(
    method: 'GET' | 'POST' | 'PUT' | 'DELETE',
    path: string,
    body?: unknown,
  ): Promise<T> {
    let token = await this.auth.idToken();
    for (let attempt = 0; ; attempt += 1) {
      const resp = await fetch(`${this.apiUrl}${path}`, {
        method,
        headers: {
          Authorization: token,
          ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
        },
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      });
      if (resp.status === 401 && attempt === 0) {
        token = await this.auth.forceRefresh();
        continue;
      }
      if (resp.status === 401) {
        await this.auth.signOut();
        throw new AuthError('session-expired', 'API rejected refreshed token');
      }
      if (!resp.ok) {
        throw new ApiError(resp.status, await resp.text().catch(() => resp.statusText));
      }
      return (await resp.json()) as T;
    }
  }

  async listMyDomains(): Promise<string[]> {
    const data = await this.request<{ Domains: string[] }>('GET', '/list_my_domains');
    return data.Domains;
  }

  async listAddresses(): Promise<Address[]> {
    const data = await this.request<{ addresses?: Address[] } | Address[]>('GET', '/list');
    return Array.isArray(data) ? data : (data.addresses ?? []);
  }

  async newAddress(req: NewAddressRequest): Promise<string> {
    const address = `${req.username}@${req.subdomain}.${req.tld}`;
    const data = await this.request<{ address?: string }>('POST', '/new', {
      username: req.username,
      subdomain: req.subdomain,
      tld: req.tld,
      comment: req.comment ?? '',
      address,
      ...(req.pending ? { pending: true } : {}),
    });
    return data.address ?? address;
  }

  /** 409 (already confirmed) is success by design — see the plan doc. */
  async confirmAddress(address: string): Promise<void> {
    try {
      await this.request('POST', '/confirm_address', { address });
    } catch (err) {
      if (err instanceof ApiError && err.status === 409) return;
      throw err;
    }
  }

  async revokeAddress(address: string): Promise<void> {
    const [, host] = address.split('@');
    const firstDot = (host ?? '').indexOf('.');
    await this.request('DELETE', '/revoke', {
      address,
      subdomain: (host ?? '').slice(0, firstDot),
      tld: (host ?? '').slice(firstDot + 1),
    });
  }
}
