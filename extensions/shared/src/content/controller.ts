/**
 * The content-script orchestrator for the suggest (Phase 5) and adopt
 * (Phase 6) flows. UI and I/O are injected (`OverlayPort`, `BackgroundPort`)
 * so the flow logic is unit-testable under jsdom; the browser packages
 * provide the real Preact overlay and runtime messaging.
 */

import { parseTypedAddress } from '../adopt/parseAddress';
import { formKey, scoreForm } from '../detect/scorer';
import type { PageContext } from '../detect/signals';
import { generateAddress } from '../generate/generateAddress';
import { failureMessage, isRefusal } from '../messaging/messages';
import type { FormScore } from '../models/index';
import { insertValue } from './insertValue';

/** What the controller needs from the background service worker. */
export interface BackgroundPort {
  listDomains(): Promise<string[]>;
  /** `fresh` reads past the background's short-lived cache. */
  listAddresses(options?: { fresh?: boolean }): Promise<string[]>;
  createAddress(req: {
    username: string;
    subdomain: string;
    tld: string;
    comment: string;
    pending: boolean;
  }): Promise<void>;
  confirmAddress(address: string): Promise<void>;
  revokeAddress(address: string): Promise<void>;
  isSignedIn(): Promise<boolean>;
}

/** What the controller needs from the overlay UI package. */
export interface OverlayPort {
  /** The suggest popover. Resolves with the user's choice. */
  showSuggestPopover(anchor: HTMLElement, model: SuggestModel): Promise<SuggestOutcome>;
  /** Passive badge on an ambiguous form's email field; click opens suggest. */
  showAmbiguousBadge(anchor: HTMLElement, onOpen: () => void): void;
  /** The adopt banner. Resolves with the user's choice. */
  showAdoptBanner(anchor: HTMLElement, address: string): Promise<'create' | 'dismiss'>;
  /** The typed-and-ignored blocking modal (Phase 6.3). */
  showSubmitGuardModal(address: string): Promise<'create-and-submit' | 'submit-anyway' | 'cancel'>;
  /**
   * Submit-time confirm failed (Phase 5.3), or, with `stage: 'create'`, the
   * create behind "Create the address and submit" failed for a reason other
   * than a refusal. `message` is the sentence the failure carried.
   */
  showConfirmFailedBanner(
    anchor: HTMLElement,
    failure?: { stage: 'create' | 'confirm'; message?: string },
  ): Promise<'retry' | 'submit-anyway' | 'cancel'>;
  /**
   * Submit-time create refused: the address is already in use. Blocking,
   * with Edit address as the only way out, so the form is not sent with an
   * address that could not be created.
   */
  showCreateRefused(address: string, message: string): Promise<'edit'>;
  /** The adopt banner's create failed or was refused: a passive note at the field. */
  showCreateProblem(anchor: HTMLElement, message: string): void;
  /** Informational subdomain-reuse notice (Phase 6.4). */
  showSubdomainReuseNotice(anchor: HTMLElement, subdomain: string): void;
  hideAdoptBanner(): void;
}

export interface SuggestModel {
  apexDomains: string[];
  defaultComment: string;
  generate(apex: string): { local: string; subdomain: string; address: string };
  /** Called on commit; rejects on API failure (popover shows inline error). */
  commit(choice: { local: string; subdomain: string; apex: string; comment: string }): Promise<string>;
}

export type SuggestOutcome = { kind: 'used'; address: string } | { kind: 'dismissed' };

interface TrackedAddress {
  address: string;
  /**
   * `submitted`: still pending on the server, but the form went out with it
   * (Submit anyway after a failed confirm). The site has the address now,
   * so page hide must not revoke it; mail arriving or the reaper decides.
   */
  status: 'pending' | 'confirmed' | 'submitted';
}

/** How a create the user asked for came out. */
type CreateOutcome =
  // Created and tracked as pending.
  | { kind: 'created' }
  // Already one of the user's addresses: nothing created, nothing tracked.
  | { kind: 'yours' }
  // The API refused it: the address is already in use.
  | { kind: 'refused'; message: string }
  // Anything else: a network failure, a 5xx, a session problem.
  | { kind: 'failed'; message: string };

/** Addresses are compared ignoring case, as the mail tier compares them. */
export function sameAddress(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

/**
 * Is the form drawn on the page? A form the site has hidden with CSS is
 * scored exactly like a visible one (the `type !== 'hidden'` filter in
 * `findEmailField` is the HTML input type, not CSS), so pages that ship a
 * hidden signup modal alongside the login form they display would get our
 * listeners on a form the user cannot reach (#1393).
 *
 * `visibility` is inherited, so the form's own computed value already
 * answers for an ancestor that hid it - and for a descendant that opted
 * back in. `display: none` is not inherited and a child of a `display: none`
 * parent still reports its own display, so that one wants the walk.
 *
 * Deliberately not a layout-box test (`getClientRects()`/`offsetParent`):
 * the shape this was reported for, `#signup-modal-signup-form` on
 * stackoverflow.com/users/login, is `visibility: hidden` and *does* have a
 * box, and jsdom does no layout at all, which would read every form under
 * test as hidden.
 */
export function isRendered(form: HTMLFormElement, document: Document): boolean {
  const view = document.defaultView;
  if (!view) return true;
  const visibility = view.getComputedStyle(form).visibility;
  if (visibility === 'hidden' || visibility === 'collapse') return false;
  for (let el: Element | null = form; el; el = el.parentElement) {
    if (view.getComputedStyle(el).display === 'none') return false;
  }
  return true;
}

const SCAN_DEBOUNCE_MS = 200;
const ADOPT_DEBOUNCE_MS = 300;

export class ContentController {
  /** Committed-but-unconfirmed address per form key. */
  private tracked = new Map<string, TrackedAddress>();

  private scored = new Map<HTMLFormElement, FormScore>();

  private scoredKeys = new Set<string>();

  private scanTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly background: BackgroundPort,
    private readonly overlay: OverlayPort,
    private readonly ctx: PageContext,
  ) {}

  /** Wire up: initial scan plus a debounced MutationObserver rescan. */
  start(): void {
    this.scan();
    const observer = new MutationObserver((mutations) => {
      const relevant = mutations.some(
        (m) =>
          // A form we skipped as hidden becomes ours the moment the page
          // reveals it, and revealing a modal is an attribute write.
          m.type === 'attributes' ||
          Array.from(m.addedNodes).some(
            (n) =>
              n instanceof HTMLElement &&
              (n.matches('form, input') || n.querySelector('form, input') !== null),
          ),
      );
      if (!relevant) return;
      if (this.scanTimer) clearTimeout(this.scanTimer);
      this.scanTimer = setTimeout(() => this.scan(), SCAN_DEBOUNCE_MS);
    });
    observer.observe(this.ctx.document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['style', 'class', 'hidden', 'open'],
    });
  }

  /** Score every form once per stable key; attach behavior per class. */
  scan(): void {
    for (const form of Array.from(this.ctx.document.querySelectorAll('form'))) {
      // Nothing is recorded for a hidden form, so the next scan reconsiders
      // it - the page revealing it is what makes it ours.
      if (!isRendered(form, this.ctx.document)) continue;
      const key = formKey(form);
      if (this.scoredKeys.has(`${key}|connected`) && form.isConnected && this.scored.has(form)) {
        continue;
      }
      const score = scoreForm(form, this.ctx);
      this.scored.set(form, score);
      this.scoredKeys.add(`${key}|connected`);
      this.attach(score, key);
    }
  }

  private attach(score: FormScore, key: string): void {
    const { classification, emailField, form } = score;
    if (!emailField) return;
    if (classification === 'signup') {
      emailField.addEventListener('focus', () => {
        // Edit address hands focus back to fix a typed address; offering a
        // generated one over it then would be in the way.
        if (this.returningFocus) return;
        void this.openSuggest(score, key);
      });
    } else if (classification === 'ambiguous') {
      this.overlay.showAmbiguousBadge(emailField, () => {
        void this.openSuggest(score, key);
      });
    } else {
      return; // signin / not-an-auth-form: do nothing, ever.
    }
    this.attachAdopt(score, key);
    form.addEventListener('submit', (event) => this.onSubmit(event, score, key), {
      capture: true,
    });
  }

  private suggestOpen = false;

  async openSuggest(score: FormScore, key: string): Promise<void> {
    if (this.suggestOpen || !score.emailField) return;
    if (!(await this.background.isSignedIn())) return;
    const apexDomains = await this.background.listDomains();
    if (apexDomains.length === 0) return; // popup explains the empty state
    this.suggestOpen = true;
    try {
      const outcome = await this.overlay.showSuggestPopover(score.emailField, {
        apexDomains,
        defaultComment: hostnameOf(this.ctx.url),
        generate: generateAddress,
        commit: async (choice) => {
          const address = `${choice.local}@${choice.subdomain}.${choice.apex}`;
          // A previously committed address for this form is superseded:
          // revoke it before recording the new one (Phase 5.4).
          const previous = this.tracked.get(key);
          await this.background.createAddress({
            username: choice.local,
            subdomain: choice.subdomain,
            tld: choice.apex,
            comment: choice.comment,
            pending: true,
          });
          if (previous && previous.status === 'pending') {
            await this.background.revokeAddress(previous.address).catch(() => {
              // Best-effort; the TTL reaper is the floor.
            });
          }
          this.tracked.set(key, { address, status: 'pending' });
          return address;
        },
      });
      if (outcome.kind === 'used' && score.emailField) {
        insertValue(score.emailField, outcome.address);
      }
    } finally {
      this.suggestOpen = false;
    }
  }

  private attachAdopt(score: FormScore, key: string): void {
    const field = score.emailField;
    if (!field) return;
    let timer: ReturnType<typeof setTimeout> | null = null;
    field.addEventListener('input', () => {
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => {
        this.checkAdopt(score, key).catch((err: unknown) => {
          console.warn('[cabalmail] address check failed:', err);
        });
      }, ADOPT_DEBOUNCE_MS);
    });
  }

  /** Address the adopt banner is currently offering to create, per form. */
  private adoptOffer = new Map<string, string>();

  async checkAdopt(score: FormScore, key: string): Promise<void> {
    const field = score.emailField;
    if (!field) return;
    const value = field.value;
    // Our own suggest insertion is tracked; no banner for it.
    if (this.tracked.get(key)?.address === value.trim().toLowerCase()) return;
    if (!(await this.background.isSignedIn())) return;
    const apexDomains = await this.background.listDomains();
    const parsed = parseTypedAddress(value, apexDomains);
    if (parsed.kind !== 'cabalmail') {
      this.adoptOffer.delete(key);
      this.overlay.hideAdoptBanner();
      return;
    }
    const existing = await this.background.listAddresses();
    if (existing.some((a) => sameAddress(a, parsed.parsed.address))) {
      // Exists (pending counts as existing); a legitimate reuse.
      this.adoptOffer.delete(key);
      this.overlay.hideAdoptBanner();
      return;
    }
    // Reusing an existing subdomain has correlation implications; say so.
    const subdomainHost = `${parsed.parsed.subdomain}.${parsed.parsed.apex}`;
    if (existing.some((a) => a.toLowerCase().endsWith(`@${subdomainHost}`))) {
      this.overlay.showSubdomainReuseNotice(field, subdomainHost);
    }
    this.adoptOffer.set(key, parsed.parsed.address);
    const choice = await this.overlay.showAdoptBanner(field, parsed.parsed.address);
    if (this.adoptOffer.get(key) !== parsed.parsed.address) return; // superseded
    if (choice === 'create') {
      const address = parsed.parsed.address;
      const outcome = await this.createTyped(address, key);
      if (outcome.kind === 'created' || outcome.kind === 'yours') {
        this.adoptOffer.delete(key);
        return;
      }
      // Say why at the field, and keep the offer: the submit guard still
      // holds the form, and for a refusal goes straight to saying so again.
      if (outcome.kind === 'refused') this.refused.set(key, { address, message: outcome.message });
      this.overlay.showCreateProblem(field, outcome.message);
    } else {
      // Explicit dismissal: the submit guard no longer holds the form.
      this.adoptOffer.delete(key);
    }
  }

  /** Typed addresses the API refused, per form, with the sentence it gave. */
  private refused = new Map<string, { address: string; message: string }>();

  /** Is the address one of the user's, by a list read past the cache? */
  private async isYours(address: string): Promise<boolean> {
    const fresh = await this.background.listAddresses({ fresh: true });
    return fresh.some((a) => sameAddress(a, address));
  }

  /** Create a typed address on the user's explicit click. Never throws. */
  private async createTyped(address: string, key: string): Promise<CreateOutcome> {
    try {
      // The cached list can predate an address made elsewhere a moment ago.
      // Creating one of the user's own addresses here would track it, and
      // page hide would then revoke an address the extension did not make.
      if (await this.isYours(address)) return { kind: 'yours' };
      const apexDomains = await this.background.listDomains();
      const parsed = parseTypedAddress(address, apexDomains);
      if (parsed.kind !== 'cabalmail') {
        return { kind: 'failed', message: `${address} is not on one of your domains.` };
      }
      await this.background.createAddress({
        username: parsed.parsed.local,
        subdomain: parsed.parsed.subdomain,
        tld: parsed.parsed.apex,
        comment: hostnameOf(this.ctx.url),
        pending: true,
      });
      this.tracked.set(key, { address, status: 'pending' });
      return { kind: 'created' };
    } catch (err) {
      if (!isRefusal(err)) return { kind: 'failed', message: failureMessage(err) };
      // The API also refuses the user's own address typed in another letter
      // case, which is fine to submit with. The list tells that apart from
      // an address in use elsewhere without reading the sentence.
      const yours = await this.isYours(address).catch(() => false);
      return yours ? { kind: 'yours' } : { kind: 'refused', message: failureMessage(err) };
    }
  }

  /** Forms we have already resolved and re-submitted; pass straight through. */
  private released = new Set<string>();

  /**
   * Submit interception (Phases 5.3 and 6.3). Never silent: any hold shows
   * UI with an explicit escape hatch.
   */
  onSubmit(event: Event, score: FormScore, key: string): void {
    if (this.released.delete(key)) return; // our own requestSubmit re-entry
    const tracked = this.tracked.get(key);
    const offer = this.adoptOffer.get(key);
    const holds = (tracked && tracked.status !== 'confirmed') || offer;
    if (!holds) return; // nothing of ours needs the submit held
    event.preventDefault();
    event.stopImmediatePropagation();
    void this.resolveSubmit(score, key);
  }

  private async resolveSubmit(score: FormScore, key: string): Promise<void> {
    const { form } = score;
    const anchor = form.querySelector<HTMLElement>('button, input[type="submit"]') ?? form;
    const offer = this.adoptOffer.get(key);
    if (offer) {
      const known = this.refused.get(key);
      if (known?.address === offer) {
        // Already refused: say so again rather than offer to create it.
        return this.holdRefused(score, offer, known.message);
      }
      // Typed a creatable address, ignored the banner, hit submit.
      const choice = await this.overlay.showSubmitGuardModal(offer);
      if (choice === 'cancel') return;
      let created = false;
      while (choice === 'create-and-submit') {
        const outcome = await this.createTyped(offer, key);
        if (outcome.kind === 'refused') {
          // Not released: the address could not be created, so the site
          // would be mailing an address that is not the user's. The offer
          // stays, so a re-submit comes back here.
          this.refused.set(key, { address: offer, message: outcome.message });
          return this.holdRefused(score, offer, outcome.message);
        }
        if (outcome.kind !== 'failed') {
          created = outcome.kind === 'created';
          break;
        }
        const next = await this.overlay.showConfirmFailedBanner(anchor, {
          stage: 'create',
          message: outcome.message,
        });
        if (next === 'retry') continue;
        if (next === 'cancel') return;
        break; // submit-anyway, as before: the form goes with the address uncreated
      }
      this.adoptOffer.delete(key);
      if (!created) {
        // Submit anyway, or the address was already the user's: nothing
        // new to confirm.
        this.releaseSubmit(form, key);
        return;
      }
      // Created, and tracked as pending: confirmed below, so a failed
      // confirm shows the banner rather than releasing silently.
    }
    const tracked = this.tracked.get(key);
    if (tracked && tracked.status !== 'confirmed') {
      try {
        await this.background.confirmAddress(tracked.address);
        this.tracked.set(key, { ...tracked, status: 'confirmed' });
      } catch (err) {
        const choice = await this.overlay.showConfirmFailedBanner(anchor, {
          stage: 'confirm',
          message: failureMessage(err),
        });
        if (choice === 'retry') {
          return this.resolveSubmit(score, key);
        }
        if (choice === 'cancel') return;
        // submit-anyway: the address stays pending and the reaper is the
        // floor, but the site has it now, so page hide must leave it alone.
        this.tracked.set(key, { ...tracked, status: 'submitted' });
      }
    }
    this.releaseSubmit(form, key);
  }

  /** Is focus being handed back to a field on purpose (Edit address)? */
  private returningFocus = false;

  /** Show a refused create and hold the form; Edit address returns to the field. */
  private async holdRefused(score: FormScore, address: string, message: string): Promise<void> {
    await this.overlay.showCreateRefused(address, message);
    const field = score.emailField;
    if (!field) return;
    this.returningFocus = true;
    try {
      field.focus();
    } finally {
      this.returningFocus = false;
    }
  }

  private releaseSubmit(form: HTMLFormElement, key: string): void {
    // We preventDefaulted the original event; requestSubmit re-runs the
    // browser's validation + submit machinery. Our capture listener fires
    // again on the re-entry, so mark the form released for one pass.
    this.released.add(key);
    if (typeof form.requestSubmit === 'function') {
      form.requestSubmit();
    } else {
      form.submit();
    }
  }

  /** Best-effort cleanup on pagehide (Phase 5.4): revoke uncommitted pendings. */
  onPageHide(): void {
    for (const [key, tracked] of this.tracked) {
      if (tracked.status === 'pending') {
        void this.background.revokeAddress(tracked.address).catch(() => {});
        this.tracked.delete(key);
      }
    }
  }
}

export function hostnameOf(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return '';
  }
}
