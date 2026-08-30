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
import type { FormScore } from '../models/index';
import { insertValue } from './insertValue';

/** What the controller needs from the background service worker. */
export interface BackgroundPort {
  listDomains(): Promise<string[]>;
  listAddresses(): Promise<string[]>;
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
  /** Submit-time confirm failed (Phase 5.3). */
  showConfirmFailedBanner(anchor: HTMLElement): Promise<'retry' | 'submit-anyway' | 'cancel'>;
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
  status: 'pending' | 'confirmed';
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
      const relevant = mutations.some((m) =>
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
    observer.observe(this.ctx.document.documentElement, { childList: true, subtree: true });
  }

  /** Score every form once per stable key; attach behavior per class. */
  scan(): void {
    for (const form of Array.from(this.ctx.document.querySelectorAll('form'))) {
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
        void this.checkAdopt(score, key);
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
    if (existing.includes(parsed.parsed.address)) {
      // Exists (pending counts as existing); a legitimate reuse.
      this.adoptOffer.delete(key);
      this.overlay.hideAdoptBanner();
      return;
    }
    // Reusing an existing subdomain has correlation implications; say so.
    const subdomainHost = `${parsed.parsed.subdomain}.${parsed.parsed.apex}`;
    if (existing.some((a) => a.endsWith(`@${subdomainHost}`))) {
      this.overlay.showSubdomainReuseNotice(field, subdomainHost);
    }
    this.adoptOffer.set(key, parsed.parsed.address);
    const choice = await this.overlay.showAdoptBanner(field, parsed.parsed.address);
    if (this.adoptOffer.get(key) !== parsed.parsed.address) return; // superseded
    if (choice === 'create') {
      await this.createTyped(parsed.parsed.address, key);
      this.adoptOffer.delete(key);
    } else {
      // Explicit dismissal: the submit guard no longer holds the form.
      this.adoptOffer.delete(key);
    }
  }

  private async createTyped(address: string, key: string): Promise<void> {
    const [local] = address.split('@') as [string, string];
    const apexDomains = await this.background.listDomains();
    const parsed = parseTypedAddress(address, apexDomains);
    if (parsed.kind !== 'cabalmail') return;
    await this.background.createAddress({
      username: local,
      subdomain: parsed.parsed.subdomain,
      tld: parsed.parsed.apex,
      comment: hostnameOf(this.ctx.url),
      pending: true,
    });
    this.tracked.set(key, { address, status: 'pending' });
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
    const holds = (tracked && tracked.status === 'pending') || offer;
    if (!holds) return; // nothing of ours needs the submit held
    event.preventDefault();
    event.stopImmediatePropagation();
    void this.resolveSubmit(score.form, key);
  }

  private async resolveSubmit(form: HTMLFormElement, key: string): Promise<void> {
    const offer = this.adoptOffer.get(key);
    if (offer) {
      // Typed a creatable address, ignored the banner, hit submit.
      const choice = await this.overlay.showSubmitGuardModal(offer);
      if (choice === 'cancel') return;
      if (choice === 'create-and-submit') {
        try {
          await this.createTyped(offer, key);
          await this.background.confirmAddress(offer);
          this.tracked.set(key, { address: offer, status: 'confirmed' });
        } catch {
          // The modal path is deliberate user intent; a failure here falls
          // through to release rather than trapping the form.
        }
      }
      this.adoptOffer.delete(key);
      this.releaseSubmit(form, key);
      return;
    }
    const tracked = this.tracked.get(key);
    if (tracked && tracked.status === 'pending') {
      try {
        await this.background.confirmAddress(tracked.address);
        this.tracked.set(key, { ...tracked, status: 'confirmed' });
      } catch {
        const anchor = form.querySelector<HTMLElement>('button, input[type="submit"]') ?? form;
        const choice = await this.overlay.showConfirmFailedBanner(anchor);
        if (choice === 'retry') {
          return this.resolveSubmit(form, key);
        }
        if (choice === 'cancel') return;
        // submit-anyway: the address stays pending; the reaper is the floor.
      }
    }
    this.releaseSubmit(form, key);
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
