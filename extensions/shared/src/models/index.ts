/** Shapes shared across the extension. Server-side shapes mirror the Lambda API. */

/** A row in `cabal-addresses`, as returned by `/list` and accepted by `/new`. */
export interface Address {
  address: string;
  tld: string;
  subdomain: string;
  username: string;
  comment?: string;
  pending?: boolean;
}

/** An apex mail domain the user may mint addresses on (from `config.js` / `/list_my_domains`). */
export interface Domain {
  domain: string;
  arn?: string;
  zone_id?: string;
}

/**
 * Runtime configuration derived from `https://admin.<control-domain>/config.json`
 * (the Terraform-generated config the React and Apple clients also read).
 */
export interface RuntimeConfig {
  controlDomain: string;
  /** Same convention as the React app: `https://admin.<control-domain>/prod`. */
  apiUrl: string;
  userPoolId: string;
  /** The extension's own Cognito app client (public, PKCE). */
  extensionClientId: string | null;
  /** Hosted UI host, e.g. `cabal-<acct>.auth.<region>.amazoncognito.com`. */
  authDomain: string | null;
  region: string;
  apexDomains: string[];
}

export type Classification = 'signup' | 'signin' | 'ambiguous' | 'not-an-auth-form';

/** One signal's contribution to a form's score, kept for dev-mode explainability. */
export interface SignalContribution {
  name: string;
  weight: number;
  contribution: number;
}

export interface FormScore {
  form: HTMLFormElement;
  emailField: HTMLInputElement | null;
  score: number; // positive -> signup, negative -> signin
  classification: Classification;
  signals: SignalContribution[];
}

/** Bookkeeping for an eagerly-created (pending) address, kept in browser.storage.local. */
export interface PendingAddressRecord {
  address: string;
  status: 'pending' | 'confirmed';
  createdAt: number;
  formKey: string;
  origin: string;
}
