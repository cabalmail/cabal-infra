/**
 * Cognito Hosted UI + PKCE (public client, no secret). The interactive leg
 * is delegated to a per-browser WebAuthDriver (identity API on Chrome, an
 * admin-origin tab flow on Safari — see webAuthDriver.ts); the
 * code-for-token exchange and refresh hit `/oauth2/token` directly.
 */

import { computeCodeChallenge, generateCodeVerifier, generateState } from './pkce';
import { clearTokens, expiresSoon, loadTokens, saveTokens, type TokenSet } from './tokens';
import type { WebAuthDriver } from './webAuthDriver';

export class AuthError extends Error {
  constructor(
    public readonly reason: 'session-expired' | 'not-signed-in' | 'flow-failed' | 'network',
    message: string,
  ) {
    super(message);
    this.name = 'AuthError';
  }
}

export interface HostedUiConfig {
  authDomain: string; // e.g. cabal-123.auth.us-east-2.amazoncognito.com
  clientId: string;
}

interface TokenEndpointResponse {
  id_token: string;
  access_token: string;
  refresh_token?: string;
}

export class HostedUiAuth {
  constructor(
    private readonly config: HostedUiConfig,
    private readonly driver: WebAuthDriver,
  ) {}

  /** Run the interactive Hosted UI flow and persist the resulting tokens. */
  async signIn(): Promise<void> {
    const verifier = generateCodeVerifier();
    const challenge = await computeCodeChallenge(verifier);
    const state = generateState();
    const redirectUri = this.driver.redirectUri();

    const authorizeUrl = new URL(`https://${this.config.authDomain}/oauth2/authorize`);
    authorizeUrl.search = new URLSearchParams({
      response_type: 'code',
      client_id: this.config.clientId,
      redirect_uri: redirectUri,
      scope: 'openid email',
      state,
      code_challenge: challenge,
      code_challenge_method: 'S256',
    }).toString();

    let resultUrl: string;
    try {
      resultUrl = await this.driver.authorize(authorizeUrl.toString());
    } catch (err) {
      throw new AuthError('flow-failed', err instanceof Error ? err.message : String(err));
    }

    const params = new URL(resultUrl).searchParams;
    if (params.get('state') !== state) {
      throw new AuthError('flow-failed', 'auth flow state mismatch');
    }
    const code = params.get('code');
    if (!code) {
      throw new AuthError('flow-failed', params.get('error_description') ?? 'no code returned');
    }

    const tokens = await this.tokenRequest({
      grant_type: 'authorization_code',
      client_id: this.config.clientId,
      code,
      redirect_uri: redirectUri,
      code_verifier: verifier,
    });
    await saveTokens(tokens);
  }

  async signOut(): Promise<void> {
    await clearTokens();
  }

  async isSignedIn(): Promise<boolean> {
    return (await loadTokens()) !== null;
  }

  /** Return a currently-valid id token, refreshing if it expires soon. */
  async idToken(): Promise<string> {
    const tokens = await loadTokens();
    if (!tokens) throw new AuthError('not-signed-in', 'no session');
    if (!expiresSoon(tokens.idToken)) return tokens.idToken;
    return (await this.refresh(tokens)).idToken;
  }

  /** Force a refresh regardless of expiry (used on a 401 retry). */
  async forceRefresh(): Promise<string> {
    const tokens = await loadTokens();
    if (!tokens) throw new AuthError('not-signed-in', 'no session');
    return (await this.refresh(tokens)).idToken;
  }

  private async refresh(tokens: TokenSet): Promise<TokenSet> {
    if (!tokens.refreshToken) {
      await clearTokens();
      throw new AuthError('session-expired', 'no refresh token');
    }
    let refreshed: TokenSet;
    try {
      refreshed = await this.tokenRequest({
        grant_type: 'refresh_token',
        client_id: this.config.clientId,
        refresh_token: tokens.refreshToken,
      });
    } catch (err) {
      if (err instanceof AuthError && err.reason === 'network') throw err;
      await clearTokens();
      throw new AuthError('session-expired', 'refresh rejected');
    }
    // Cognito does not return a new refresh token on refresh; keep the old one.
    const merged: TokenSet = { ...refreshed, refreshToken: tokens.refreshToken };
    await saveTokens(merged);
    return merged;
  }

  private async tokenRequest(params: Record<string, string>): Promise<TokenSet> {
    let resp: Response;
    try {
      resp = await fetch(`https://${this.config.authDomain}/oauth2/token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(params).toString(),
      });
    } catch (err) {
      throw new AuthError('network', `token endpoint unreachable: ${String(err)}`);
    }
    if (!resp.ok) {
      throw new AuthError('flow-failed', `token endpoint returned ${resp.status}`);
    }
    const body = (await resp.json()) as TokenEndpointResponse;
    return {
      idToken: body.id_token,
      accessToken: body.access_token,
      refreshToken: body.refresh_token ?? null,
    };
  }
}
