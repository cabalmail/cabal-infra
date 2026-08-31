/**
 * Cognito Hosted UI + PKCE (public client, no secret). The interactive leg
 * is delegated to a per-browser WebAuthDriver (identity API on Chrome, an
 * admin-origin tab flow on Safari — see webAuthDriver.ts); the
 * code-for-token exchange and refresh hit `/oauth2/token` directly.
 *
 * The flow is split in two — `signIn()` starts it, `completeSignIn()`
 * finishes it from the redirect URL — because the tab driver's redirect
 * arrives as a `tabs.onUpdated` event in a background worker that may have
 * been suspended in between. The PKCE verifier and `state` therefore live
 * in extension storage for the duration of the flow, not in a closure.
 */

import browser from 'webextension-polyfill';
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

/** An interactive flow that has been started and is awaiting its redirect. */
interface PendingFlow {
  verifier: string;
  state: string;
  redirectUri: string;
  startedAt: number;
}

const PENDING_KEY = 'cabalmail.pendingAuth';
/** Long enough for a password + MFA code, short enough to not linger. */
const PENDING_TTL_MS = 10 * 60 * 1000;

async function loadPendingFlow(): Promise<PendingFlow | null> {
  const stored = await browser.storage.local.get(PENDING_KEY);
  return (stored[PENDING_KEY] as PendingFlow | undefined) ?? null;
}

async function savePendingFlow(flow: PendingFlow): Promise<void> {
  await browser.storage.local.set({ [PENDING_KEY]: flow });
}

/** Exported so a sign-out can drop an abandoned flow without a config fetch. */
export async function clearPendingFlow(): Promise<void> {
  await browser.storage.local.remove(PENDING_KEY);
}

export class HostedUiAuth {
  constructor(
    private readonly config: HostedUiConfig,
    private readonly driver: WebAuthDriver,
  ) {}

  /**
   * Start the interactive Hosted UI flow. Resolves `true` when sign-in
   * completed inline (the identity API observes its own redirect), `false`
   * when the flow is now running in a tab and `completeSignIn` will finish
   * it from the background's redirect interception.
   */
  async signIn(): Promise<boolean> {
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

    await savePendingFlow({ verifier, state, redirectUri, startedAt: Date.now() });

    let resultUrl: string | null;
    try {
      resultUrl = await this.driver.authorize(authorizeUrl.toString());
    } catch (err) {
      await clearPendingFlow();
      throw new AuthError('flow-failed', err instanceof Error ? err.message : String(err));
    }
    if (resultUrl === null) return false;
    await this.completeSignIn(resultUrl);
    return true;
  }

  /**
   * Finish a started flow from the OAuth redirect URL, persisting tokens.
   * Safe to call for a URL that is not a live flow's redirect: it throws
   * rather than half-completing.
   */
  async completeSignIn(redirectUrl: string): Promise<void> {
    const pending = await loadPendingFlow();
    if (!pending) throw new AuthError('flow-failed', 'no sign-in is in progress');
    // The authorization code is single-use either way; drop the flow before
    // spending it so a failed exchange cannot be retried against stale state.
    await clearPendingFlow();
    if (Date.now() - pending.startedAt > PENDING_TTL_MS) {
      throw new AuthError('flow-failed', 'sign-in took too long; start it again');
    }

    const params = new URL(redirectUrl).searchParams;
    if (params.get('state') !== pending.state) {
      throw new AuthError('flow-failed', 'auth flow state mismatch');
    }
    const code = params.get('code');
    if (!code) {
      const reported = params.get('error_description') ?? params.get('error');
      throw new AuthError('flow-failed', reported ?? 'no code returned');
    }

    const tokens = await this.tokenRequest({
      grant_type: 'authorization_code',
      client_id: this.config.clientId,
      code,
      redirect_uri: pending.redirectUri,
      code_verifier: pending.verifier,
    });
    await saveTokens(tokens);
  }

  async signOut(): Promise<void> {
    await clearPendingFlow();
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
