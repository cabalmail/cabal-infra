// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  ContentController,
  type BackgroundPort,
  type OverlayPort,
  type SuggestOutcome,
} from '../src/content/controller';
import { scoreForm } from '../src/detect/scorer';

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
    addresses: string[];
    failConfirm: boolean;
  };
  overlay: OverlayPort & {
    banners: string[];
    suggestResult: SuggestOutcome | ((model: unknown) => Promise<SuggestOutcome>);
    adoptChoice: 'create' | 'dismiss';
    guardChoice: 'create-and-submit' | 'submit-anyway' | 'cancel';
    confirmFailedChoices: ('retry' | 'submit-anyway' | 'cancel')[];
    reuseNotices: string[];
  };
}

function makeFakes(): Fakes {
  const background: Fakes['background'] = {
    created: [],
    confirmed: [],
    revoked: [],
    addresses: [],
    failConfirm: false,
    listDomains: async () => ['cabalmail.com'],
    listAddresses: async () => background.addresses,
    createAddress: async (req) => {
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
    showSubmitGuardModal: async () => overlay.guardChoice,
    showConfirmFailedBanner: async () =>
      overlay.confirmFailedChoices.shift() ?? 'cancel',
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
