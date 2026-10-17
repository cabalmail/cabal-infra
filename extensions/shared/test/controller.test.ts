// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  ContentController,
  type BackgroundPort,
  type OverlayPort,
  type SuggestOutcome,
} from '../src/content/controller';
import { scoreForm } from '../src/detect/scorer';
import { BackgroundCallError } from '../src/messaging/messages';

function signupForm(): HTMLFormElement {
  document.body.innerHTML = `
    <form id="signup" action="/register">
      <input type="email" name="email" />
      <input type="password" name="pw" autocomplete="new-password" />
      <button type="submit">Sign up</button>
    </form>`;
  return document.querySelector('form') as HTMLFormElement;
}

interface Fakes {
  background: BackgroundPort & {
    created: { username: string; subdomain: string; tld: string; pending: boolean }[];
    confirmed: string[];
    revoked: string[];
    /** The server's list, which a fresh read returns. */
    addresses: string[];
    /** What the background's cache answers; null serves `addresses`. */
    cached: string[] | null;
    /** Answers for successive fresh reads, ahead of `addresses`. */
    freshLists: string[][];
    freshReads: number;
    /** Thrown by successive creates, in order; an empty queue succeeds. */
    createErrors: unknown[];
    createAttempts: number;
    failConfirm: boolean;
  };
  overlay: OverlayPort & {
    banners: string[];
    suggestResult: SuggestOutcome | ((model: unknown) => Promise<SuggestOutcome>);
    adoptChoice: 'create' | 'dismiss';
    guardChoice: 'create-and-submit' | 'submit-anyway' | 'cancel';
    confirmFailedChoices: ('retry' | 'submit-anyway' | 'cancel')[];
    confirmFailures: ({ stage: 'create' | 'confirm'; message?: string } | undefined)[];
    refusals: { address: string; message: string }[];
    problems: string[];
    guardShown: number;
    reuseNotices: string[];
  };
}

function makeFakes(): Fakes {
  const background: Fakes['background'] = {
    created: [],
    confirmed: [],
    revoked: [],
    addresses: [],
    cached: null,
    freshLists: [],
    freshReads: 0,
    createErrors: [],
    createAttempts: 0,
    failConfirm: false,
    listDomains: async () => ['cabalmail.com'],
    listAddresses: async (options) => {
      if (!options?.fresh) return background.cached ?? background.addresses;
      background.freshReads += 1;
      return background.freshLists.shift() ?? background.addresses;
    },
    createAddress: async (req) => {
      background.createAttempts += 1;
      const error = background.createErrors.shift();
      if (error) throw error;
      background.created.push({
        username: req.username,
        subdomain: req.subdomain,
        tld: req.tld,
        pending: req.pending,
      });
      background.addresses.push(`${req.username}@${req.subdomain}.${req.tld}`);
    },
    confirmAddress: async (address) => {
      if (background.failConfirm) throw new Error('offline');
      background.confirmed.push(address);
    },
    revokeAddress: async (address) => {
      background.revoked.push(address);
    },
    isSignedIn: async () => true,
  };
  const overlay: Fakes['overlay'] = {
    banners: [],
    suggestResult: { kind: 'dismissed' },
    adoptChoice: 'dismiss',
    guardChoice: 'cancel',
    confirmFailedChoices: [],
    confirmFailures: [],
    refusals: [],
    problems: [],
    guardShown: 0,
    reuseNotices: [],
    showSuggestPopover: async (_anchor, model) => {
      if (typeof overlay.suggestResult === 'function') return overlay.suggestResult(model);
      return overlay.suggestResult;
    },
    showAmbiguousBadge: () => {},
    showAdoptBanner: async (_anchor, address) => {
      overlay.banners.push(address);
      return overlay.adoptChoice;
    },
    showSubmitGuardModal: async () => {
      overlay.guardShown += 1;
      return overlay.guardChoice;
    },
    showConfirmFailedBanner: async (_anchor, failure) => {
      overlay.confirmFailures.push(failure);
      return overlay.confirmFailedChoices.shift() ?? 'cancel';
    },
    showCreateRefused: async (address, message) => {
      overlay.refusals.push({ address, message });
      return 'edit';
    },
    showCreateProblem: (_anchor, message) => {
      overlay.problems.push(message);
    },
    showSubdomainReuseNotice: (_anchor, subdomain) => {
      overlay.reuseNotices.push(subdomain);
    },
    hideAdoptBanner: () => {},
  };
  return { background, overlay };
}

function make(form: HTMLFormElement) {
  const fakes = makeFakes();
  const controller = new ContentController(fakes.background, fakes.overlay, {
    url: 'https://shop.example.com/signup',
    document,
  });
  const score = scoreForm(form, { url: 'https://shop.example.com/signup', document });
  return { ...fakes, controller, score };
}

beforeEach(() => {
  document.body.innerHTML = '';
});

describe('suggest flow', () => {
  it('commits an address as pending and fills the field', async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    overlay.suggestResult = async (model) => {
      const m = model as {
        apexDomains: string[];
        defaultComment: string;
        commit: (c: { local: string; subdomain: string; apex: string; comment: string }) => Promise<string>;
      };
      expect(m.apexDomains).toEqual(['cabalmail.com']);
      expect(m.defaultComment).toBe('shop.example.com');
      const address = await m.commit({
        local: 'abcdef12',
        subdomain: 'ghijkl34',
        apex: 'cabalmail.com',
        comment: 'shop.example.com',
      });
      return { kind: 'used', address };
    };
    await controller.openSuggest(score, 'k1');
    expect(background.created).toEqual([
      { username: 'abcdef12', subdomain: 'ghijkl34', tld: 'cabalmail.com', pending: true },
    ]);
    expect(score.emailField?.value).toBe('abcdef12@ghijkl34.cabalmail.com');
  });

  it('revokes a superseded commit when the user commits a second address', async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    const commitOnce = (local: string) => async (model: unknown) => {
      const m = model as { commit: (c: object) => Promise<string> };
      const address = await m.commit({
        local,
        subdomain: 'ghijkl34',
        apex: 'cabalmail.com',
        comment: '',
      });
      return { kind: 'used', address } as SuggestOutcome;
    };
    overlay.suggestResult = commitOnce('first111');
    await controller.openSuggest(score, 'k1');
    overlay.suggestResult = commitOnce('second22');
    await controller.openSuggest(score, 'k1');
    expect(background.revoked).toEqual(['first111@ghijkl34.cabalmail.com']);
  });

  it('does nothing when signed out', async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    background.isSignedIn = async () => false;
    let opened = false;
    overlay.showSuggestPopover = async () => {
      opened = true;
      return { kind: 'dismissed' };
    };
    await controller.openSuggest(score, 'k1');
    expect(opened).toBe(false);
  });
});

describe('adopt flow', () => {
  it('offers to create a typed, non-existing Cabalmail address', async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    overlay.adoptChoice = 'create';
    score.emailField!.value = 'test@made-up.cabalmail.com';
    await controller.checkAdopt(score, 'k1');
    expect(overlay.banners).toEqual(['test@made-up.cabalmail.com']);
    expect(background.created).toEqual([
      { username: 'test', subdomain: 'made-up', tld: 'cabalmail.com', pending: true },
    ]);
  });

  it('ignores existing addresses, foreign domains, and apex-shaped input', async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    background.addresses = ['have@it.cabalmail.com'];
    for (const value of [
      'have@it.cabalmail.com',
      'someone@gmail.com',
      'someone@cabalmail.com',
      'not an email',
    ]) {
      score.emailField!.value = value;
      await controller.checkAdopt(score, 'k1');
    }
    expect(overlay.banners).toEqual([]);
    expect(background.created).toEqual([]);
  });

  it('notices subdomain reuse without blocking', async () => {
    const form = signupForm();
    const { controller, overlay, background, score } = make(form);
    background.addresses = ['old@shared.cabalmail.com'];
    overlay.adoptChoice = 'create';
    score.emailField!.value = 'new@shared.cabalmail.com';
    await controller.checkAdopt(score, 'k1');
    expect(overlay.reuseNotices).toEqual(['shared.cabalmail.com']);
    expect(background.created).toHaveLength(1);
  });
});

describe('submit interception', () => {
  function submitEvent(): Event {
    const event = new Event('submit', { bubbles: true, cancelable: true });
    return event;
  }

  it('confirms a committed address on submit and releases the form', async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    overlay.suggestResult = async (model) => {
      const m = model as { commit: (c: object) => Promise<string> };
      const address = await m.commit({
        local: 'abcdef12',
        subdomain: 'ghijkl34',
        apex: 'cabalmail.com',
        comment: '',
      });
      return { kind: 'used', address };
    };
    await controller.openSuggest(score, 'k1');
    form.requestSubmit = vi.fn();
    const event = submitEvent();
    controller.onSubmit(event, score, 'k1');
    expect(event.defaultPrevented).toBe(true);
    await vi.waitFor(() => {
      expect(background.confirmed).toEqual(['abcdef12@ghijkl34.cabalmail.com']);
      expect(form.requestSubmit).toHaveBeenCalledOnce();
    });
    // The re-entry (our own requestSubmit) passes straight through.
    const reentry = submitEvent();
    controller.onSubmit(reentry, score, 'k1');
    expect(reentry.defaultPrevented).toBe(false);
  });

  it('does not intercept forms it never touched', () => {
    const form = signupForm();
    const { controller, score } = make(form);
    const event = submitEvent();
    controller.onSubmit(event, score, 'k1');
    expect(event.defaultPrevented).toBe(false);
  });

  it('guards the typed-and-ignored path with the blocking modal', async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    score.emailField!.value = 'test@made-up.cabalmail.com';
    overlay.adoptChoice = 'dismiss';
    // Banner is pending an answer (user ignored it) when submit fires: model
    // that by making showAdoptBanner never resolve until after submit.
    let resolveBanner!: (c: 'create' | 'dismiss') => void;
    overlay.showAdoptBanner = async (_a, address) => {
      overlay.banners.push(address);
      return new Promise((res) => {
        resolveBanner = res;
      });
    };
    const adoptCheck = controller.checkAdopt(score, 'k1');
    await vi.waitFor(() => expect(overlay.banners).toHaveLength(1));
    overlay.guardChoice = 'create-and-submit';
    form.requestSubmit = vi.fn();
    const event = submitEvent();
    controller.onSubmit(event, score, 'k1');
    expect(event.defaultPrevented).toBe(true);
    await vi.waitFor(() => {
      expect(background.created).toHaveLength(1);
      expect(background.confirmed).toEqual(['test@made-up.cabalmail.com']);
      expect(form.requestSubmit).toHaveBeenCalledOnce();
    });
    resolveBanner('dismiss');
    await adoptCheck;
  });

  it('offers retry / submit-anyway / cancel when confirm fails', async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    overlay.suggestResult = async (model) => {
      const m = model as { commit: (c: object) => Promise<string> };
      const address = await m.commit({
        local: 'abcdef12',
        subdomain: 'ghijkl34',
        apex: 'cabalmail.com',
        comment: '',
      });
      return { kind: 'used', address };
    };
    await controller.openSuggest(score, 'k1');
    background.failConfirm = true;
    overlay.confirmFailedChoices = ['retry', 'submit-anyway'];
    form.requestSubmit = vi.fn();
    const recover = vi.waitFor(() => {
      expect(form.requestSubmit).toHaveBeenCalledOnce();
    });
    controller.onSubmit(submitEvent(), score, 'k1');
    await recover;
    // Two failed confirm attempts (initial + retry), then released anyway.
    expect(overlay.confirmFailedChoices).toHaveLength(0);
    expect(background.confirmed).toEqual([]);
  });
});

describe('abandonment', () => {
  it('revokes still-pending addresses on pagehide', async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    overlay.suggestResult = async (model) => {
      const m = model as { commit: (c: object) => Promise<string> };
      const address = await m.commit({
        local: 'abcdef12',
        subdomain: 'ghijkl34',
        apex: 'cabalmail.com',
        comment: '',
      });
      return { kind: 'used', address };
    };
    await controller.openSuggest(score, 'k1');
    controller.onPageHide();
    await vi.waitFor(() => {
      expect(background.revoked).toEqual(['abcdef12@ghijkl34.cabalmail.com']);
    });
  });
});

describe('a create the API refuses or cannot answer', () => {
  const TAKEN = 'taken@made-up.cabalmail.com';
  const SENTENCE = `${TAKEN} is already taken. Choose another username or subdomain.`;
  const refusal = () => new BackgroundCallError('refused', SENTENCE, 409);

  function submitEvent(): Event {
    return new Event('submit', { bubbles: true, cancelable: true });
  }

  /**
   * Leave the adopt banner unanswered, as a user who ignores it does, so the
   * offer is standing when submit fires. Returns the check to settle at the end.
   */
  async function ignoreBanner(
    fakes: ReturnType<typeof make>,
    value: string,
  ): Promise<() => Promise<void>> {
    const { controller, overlay, score } = fakes;
    let answer!: (c: 'create' | 'dismiss') => void;
    overlay.showAdoptBanner = async (_a, address) => {
      overlay.banners.push(address);
      return new Promise((res) => {
        answer = res;
      });
    };
    score.emailField!.value = value;
    const check = controller.checkAdopt(score, 'k1');
    await vi.waitFor(() => expect(overlay.banners).toHaveLength(1));
    return async () => {
      answer('dismiss');
      await check;
    };
  }

  it('holds a guarded form the API refuses, says why, and hands the field back', async () => {
    const form = signupForm();
    const fakes = make(form);
    const { controller, background, overlay, score } = fakes;
    // Attach the real listeners, so focusing the field would open the
    // suggest popover if the controller did not hold it back.
    controller.scan();
    let suggestOpened = 0;
    overlay.showSuggestPopover = async () => {
      suggestOpened += 1;
      return { kind: 'dismissed' };
    };
    const settle = await ignoreBanner(fakes, TAKEN);
    overlay.guardChoice = 'create-and-submit';
    background.createErrors = [refusal()];
    form.requestSubmit = vi.fn();

    const first = submitEvent();
    controller.onSubmit(first, score, 'k1');
    expect(first.defaultPrevented).toBe(true);
    await vi.waitFor(() => expect(overlay.refusals).toEqual([{ address: TAKEN, message: SENTENCE }]));
    expect(form.requestSubmit).not.toHaveBeenCalled();
    expect(document.activeElement).toBe(score.emailField);
    expect(suggestOpened).toBe(0);

    // Submitting the same address again says so again, without offering to
    // create it (whose Submit anyway would send it) or asking the API twice.
    const second = submitEvent();
    controller.onSubmit(second, score, 'k1');
    expect(second.defaultPrevented).toBe(true);
    await vi.waitFor(() => expect(overlay.refusals).toHaveLength(2));
    expect(overlay.guardShown).toBe(1);
    expect(background.createAttempts).toBe(1);
    expect(form.requestSubmit).not.toHaveBeenCalled();

    // An ordinary focus still opens the popover: the hold-back was one-shot.
    score.emailField!.blur();
    score.emailField!.focus();
    await vi.waitFor(() => expect(suggestOpened).toBe(1));
    await settle();
  });

  it('shows a refused adopt create at the field and keeps the form held', async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    overlay.adoptChoice = 'create';
    background.createErrors = [refusal()];
    score.emailField!.value = TAKEN;
    await controller.checkAdopt(score, 'k1');
    expect(overlay.problems).toEqual([SENTENCE]);
    expect(background.created).toEqual([]);

    form.requestSubmit = vi.fn();
    const event = submitEvent();
    controller.onSubmit(event, score, 'k1');
    expect(event.defaultPrevented).toBe(true);
    await vi.waitFor(() => expect(overlay.refusals).toEqual([{ address: TAKEN, message: SENTENCE }]));
    expect(overlay.guardShown).toBe(0);
    expect(form.requestSubmit).not.toHaveBeenCalled();
  });

  it("releases a refused address the fresh list shows is the user's own in another case", async () => {
    const form = signupForm();
    const fakes = make(form);
    const { controller, background, overlay, score } = fakes;
    const settle = await ignoreBanner(fakes, 'mine@made-up.cabalmail.com');
    overlay.guardChoice = 'create-and-submit';
    // Not in the list before the create; there (as the server stores it)
    // when the refusal sends the controller back to look.
    background.freshLists = [[], ['Mine@Made-Up.cabalmail.com']];
    background.createErrors = [
      new BackgroundCallError('refused', 'You already have this address as Mine@Made-Up.cabalmail.com.', 409),
    ];
    form.requestSubmit = vi.fn();
    controller.onSubmit(submitEvent(), score, 'k1');
    await vi.waitFor(() => expect(form.requestSubmit).toHaveBeenCalledOnce());
    expect(overlay.refusals).toEqual([]);
    expect(background.confirmed).toEqual([]);
    controller.onPageHide();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(background.revoked).toEqual([]);
    await settle();
  });

  it("creates nothing for one of the user's addresses the cache had not seen", async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    // Made elsewhere a moment ago, in mixed case: the cache predates it.
    background.cached = [];
    background.addresses = ['Fresh@Made-Up.cabalmail.com'];
    overlay.adoptChoice = 'create';
    score.emailField!.value = 'fresh@made-up.cabalmail.com';
    await controller.checkAdopt(score, 'k1');
    expect(overlay.banners).toEqual(['fresh@made-up.cabalmail.com']);
    expect(background.freshReads).toBe(1);
    expect(background.createAttempts).toBe(0);
    expect(overlay.problems).toEqual([]);

    const event = submitEvent();
    controller.onSubmit(event, score, 'k1');
    expect(event.defaultPrevented).toBe(false);
    controller.onPageHide();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(background.revoked).toEqual([]);
  });

  it("does not offer the user's own address stored in another case", async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    background.addresses = ['Have@It.cabalmail.com', 'old@Shared.cabalmail.com'];
    score.emailField!.value = 'have@it.cabalmail.com';
    await controller.checkAdopt(score, 'k1');
    expect(overlay.banners).toEqual([]);

    overlay.adoptChoice = 'dismiss';
    score.emailField!.value = 'new@shared.cabalmail.com';
    await controller.checkAdopt(score, 'k1');
    expect(overlay.reuseNotices).toEqual(['shared.cabalmail.com']);
  });

  it('shows a create that failed to reach the server, and Retry creates it', async () => {
    const form = signupForm();
    const fakes = make(form);
    const { controller, background, overlay, score } = fakes;
    const settle = await ignoreBanner(fakes, 'test@made-up.cabalmail.com');
    overlay.guardChoice = 'create-and-submit';
    background.createErrors = [new BackgroundCallError('network', 'TypeError: Failed to fetch')];
    overlay.confirmFailedChoices = ['retry'];
    form.requestSubmit = vi.fn();
    controller.onSubmit(submitEvent(), score, 'k1');
    await vi.waitFor(() => expect(form.requestSubmit).toHaveBeenCalledOnce());
    expect(overlay.confirmFailures).toEqual([
      { stage: 'create', message: 'TypeError: Failed to fetch' },
    ]);
    // Retry went back to the create, not to the guard modal.
    expect(overlay.guardShown).toBe(1);
    expect(background.createAttempts).toBe(2);
    expect(background.confirmed).toEqual(['test@made-up.cabalmail.com']);
    await settle();
  });

  it('sends the form with nothing created on Submit anyway after a failed create', async () => {
    const form = signupForm();
    const fakes = make(form);
    const { controller, background, overlay, score } = fakes;
    const settle = await ignoreBanner(fakes, 'test@made-up.cabalmail.com');
    overlay.guardChoice = 'create-and-submit';
    background.createErrors = [new BackgroundCallError('api', 'The Cabalmail server answered 502.', 502)];
    overlay.confirmFailedChoices = ['submit-anyway'];
    form.requestSubmit = vi.fn();
    controller.onSubmit(submitEvent(), score, 'k1');
    await vi.waitFor(() => expect(form.requestSubmit).toHaveBeenCalledOnce());
    expect(background.created).toEqual([]);
    expect(background.confirmed).toEqual([]);
    await settle();
  });

  it('keeps an address the form went out with after a failed confirm', async () => {
    const form = signupForm();
    const { controller, background, overlay, score } = make(form);
    overlay.suggestResult = async (model) => {
      const m = model as { commit: (c: object) => Promise<string> };
      const address = await m.commit({
        local: 'abcdef12',
        subdomain: 'ghijkl34',
        apex: 'cabalmail.com',
        comment: '',
      });
      return { kind: 'used', address };
    };
    await controller.openSuggest(score, 'k1');
    background.failConfirm = true;
    overlay.confirmFailedChoices = ['submit-anyway'];
    form.requestSubmit = vi.fn();
    controller.onSubmit(submitEvent(), score, 'k1');
    await vi.waitFor(() => expect(form.requestSubmit).toHaveBeenCalledOnce());
    expect(overlay.confirmFailures).toEqual([{ stage: 'confirm', message: 'offline' }]);
    // The submit's own navigation fires pagehide; the site has the address
    // now, so the reaper or arriving mail decides, not the extension.
    controller.onPageHide();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(background.revoked).toEqual([]);
  });
});

describe('form visibility', () => {
  // The shape #1393 was reported for: a hidden signup modal earlier in the
  // DOM than the login form the page actually shows. The modal scores
  // `signup` (new-password + signup button + signup action), the login form
  // scores `signin`.
  const LOGIN_PAGE = `
    <div id="modal-wrap">
      <form id="signup-modal" action="/users/signup">
        <input type="email" name="email" />
        <input type="password" name="pw" autocomplete="new-password" />
        <button type="submit">Sign up</button>
      </form>
    </div>
    <form id="login-form" action="/users/login">
      <input type="email" name="email" />
      <input type="password" name="pw" autocomplete="current-password" />
      <button type="submit">Log in</button>
    </form>`;

  function page(html: string, url = 'https://forum.example.com/users/login') {
    document.body.innerHTML = html;
    const fakes = makeFakes();
    const suggested: HTMLElement[] = [];
    const badged: HTMLElement[] = [];
    fakes.overlay.showSuggestPopover = async (anchor) => {
      suggested.push(anchor);
      return { kind: 'dismissed' };
    };
    fakes.overlay.showAmbiguousBadge = (anchor) => {
      badged.push(anchor);
    };
    const controller = new ContentController(fakes.background, fakes.overlay, { url, document });
    return { ...fakes, controller, suggested, badged };
  }

  /**
   * Focus the form's email field and let the async suggest path settle.
   * The event is dispatched directly because jsdom does not enforce
   * focusability - which is the point: we are asserting on whether the
   * listener was ever attached, not on whether the field can be reached.
   */
  async function focusEmail(id: string): Promise<void> {
    document.querySelector<HTMLInputElement>(`#${id} input[type="email"]`)!
      .dispatchEvent(new Event('focus'));
    await new Promise((resolve) => setTimeout(resolve, 0));
  }

  it('ignores a signup form its ancestor hid with visibility: hidden', async () => {
    const { controller, suggested } = page(LOGIN_PAGE);
    document.getElementById('modal-wrap')!.setAttribute('style', 'visibility: hidden');
    controller.scan();
    await focusEmail('signup-modal');
    expect(suggested).toEqual([]);
  });

  it('ignores a signup form its ancestor hid with display: none', async () => {
    const { controller, suggested } = page(LOGIN_PAGE);
    document.getElementById('modal-wrap')!.setAttribute('style', 'display: none');
    controller.scan();
    await focusEmail('signup-modal');
    expect(suggested).toEqual([]);
  });

  it('still attaches to a visible signup form', async () => {
    const { controller, suggested } = page(LOGIN_PAGE);
    controller.scan();
    await focusEmail('signup-modal');
    expect(suggested).toHaveLength(1);
  });

  it('draws no ambiguous badge on a hidden form', () => {
    // A bare email field on a URL with no auth vocabulary scores 0, which is
    // the ambiguous band - the one classification that draws UI passively.
    const { controller, badged } = page(
      '<div id="wrap" style="visibility: hidden">' +
        '<form id="maybe"><input type="email" name="email" /></form></div>',
      'https://forum.example.com/account',
    );
    controller.scan();
    expect(badged).toEqual([]);
  });

  it('draws the ambiguous badge once that form is visible', () => {
    const { controller, badged } = page(
      '<div id="wrap"><form id="maybe"><input type="email" name="email" /></form></div>',
      'https://forum.example.com/account',
    );
    controller.scan();
    expect(badged).toHaveLength(1);
  });

  it('picks the form up once the page reveals it', async () => {
    const { controller, suggested } = page(LOGIN_PAGE);
    const wrap = document.getElementById('modal-wrap')!;
    wrap.setAttribute('style', 'visibility: hidden');
    controller.scan();
    wrap.setAttribute('style', '');
    controller.scan();
    await focusEmail('signup-modal');
    expect(suggested).toHaveLength(1);
  });

  it('rescans when an attribute write reveals a hidden form', async () => {
    const { controller, suggested } = page(LOGIN_PAGE);
    const wrap = document.getElementById('modal-wrap')!;
    wrap.setAttribute('style', 'visibility: hidden');
    controller.start();
    wrap.setAttribute('style', '');
    // The observer debounces at 200ms.
    await new Promise((resolve) => setTimeout(resolve, 300));
    await focusEmail('signup-modal');
    expect(suggested).toHaveLength(1);
  });
});
