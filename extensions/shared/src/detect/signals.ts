/**
 * Individual signal extractors for the sign-up/sign-in classifier.
 * Each is a pure function of (form, context); it returns `null` when the
 * signal is absent, or a contribution whose sign points at sign-up (+) or
 * sign-in (-). The GET-vs-POST distinction is deliberately not a signal:
 * both verbs appear on both kinds of form (see the plan doc).
 */

import type { SignalContribution } from '../models/index';
import {
  AGREEMENT_TERMS,
  LEGAL_DOCUMENT_TERMS,
  SIGNIN_PATH_TERMS,
  SIGNIN_TERMS,
  SIGNUP_PATH_TERMS,
  SIGNUP_TERMS,
  WEIGHTS,
} from './config';

export interface PageContext {
  /** Full page URL (content script: location.href; fixtures: recorded URL). */
  url: string;
  /** Document the form belongs to, for out-of-form lookups (headings, labels). */
  document: Document;
}

export type SignalExtractor = (
  form: HTMLFormElement,
  ctx: PageContext,
) => SignalContribution | null;

/** The form's fields a user can actually fill. */
function fillableFields(form: HTMLFormElement): HTMLInputElement[] {
  return Array.from(form.querySelectorAll<HTMLInputElement>('input')).filter(
    (i) => i.type !== 'hidden' && !i.disabled,
  );
}

/** Locate the form's email field, or null when the form has none we'd fill. */
export function findEmailField(form: HTMLFormElement): HTMLInputElement | null {
  const fillable = fillableFields(form);
  const byType = fillable.find((i) => i.type === 'email');
  if (byType) return byType;
  const byAutocomplete = fillable.find((i) =>
    i.autocomplete.toLowerCase().includes('email'),
  );
  if (byAutocomplete) return byAutocomplete;
  const emailish = (s: string | null) => !!s && /e-?mail/i.test(s);
  return (
    fillable.find(
      (i) =>
        i.type === 'text' &&
        (emailish(i.name) || emailish(i.id) || emailish(i.placeholder) ||
          emailish(i.getAttribute('aria-label'))),
    ) ?? null
  );
}

function passwordFields(form: HTMLFormElement): HTMLInputElement[] {
  return Array.from(form.querySelectorAll<HTMLInputElement>('input[type="password"]'));
}

function containsAny(haystack: string, terms: readonly string[]): boolean {
  const lower = haystack.toLowerCase();
  return terms.some((t) => lower.includes(t));
}

/** Visible-ish text of the form's submit controls (buttons + submit inputs). */
function submitText(form: HTMLFormElement): string {
  const parts: string[] = [];
  for (const el of Array.from(
    form.querySelectorAll<HTMLElement>(
      'button, input[type="submit"], [role="button"]',
    ),
  )) {
    if (el instanceof HTMLInputElement) {
      parts.push(el.value);
    } else {
      parts.push(el.textContent ?? '');
      const aria = el.getAttribute('aria-label');
      if (aria) parts.push(aria);
    }
  }
  return parts.join(' ');
}

/** Text of labels, placeholders, and aria-labels for the form's fields. */
function fieldAnnotationText(form: HTMLFormElement, ctx: PageContext): string {
  const parts: string[] = [];
  for (const input of Array.from(form.querySelectorAll<HTMLInputElement>('input'))) {
    if (input.placeholder) parts.push(input.placeholder);
    const aria = input.getAttribute('aria-label');
    if (aria) parts.push(aria);
    if (input.id) {
      // htmlFor comparison instead of an attribute selector: no need to
      // CSS-escape arbitrary host-page ids (CSS.escape is also missing in
      // some test environments).
      for (const label of Array.from(ctx.document.querySelectorAll('label'))) {
        if (label.htmlFor === input.id && label.textContent) {
          parts.push(label.textContent);
        }
      }
    }
    const wrapping = input.closest('label');
    if (wrapping?.textContent) parts.push(wrapping.textContent);
  }
  return parts.join(' ');
}

export const newPasswordAutocomplete: SignalExtractor = (form) => {
  const hit = passwordFields(form).some(
    (f) => f.autocomplete.toLowerCase().includes('new-password'),
  );
  if (!hit) return null;
  return {
    name: 'newPasswordAutocomplete',
    weight: WEIGHTS.newPasswordAutocomplete,
    contribution: WEIGHTS.newPasswordAutocomplete,
  };
};

export const currentPasswordAutocomplete: SignalExtractor = (form) => {
  const fields = passwordFields(form);
  const current = fields.some((f) => f.autocomplete.toLowerCase().includes('current-password'));
  const fresh = fields.some((f) => f.autocomplete.toLowerCase().includes('new-password'));
  // A change-password form can carry both; the pair cancels here and the
  // remaining signals decide.
  if (!current || fresh) return null;
  return {
    name: 'currentPasswordAutocomplete',
    weight: WEIGHTS.currentPasswordAutocomplete,
    contribution: -WEIGHTS.currentPasswordAutocomplete,
  };
};

export const twoPasswordFields: SignalExtractor = (form) => {
  if (passwordFields(form).length < 2) return null;
  return {
    name: 'twoPasswordFields',
    weight: WEIGHTS.twoPasswordFields,
    contribution: WEIGHTS.twoPasswordFields,
  };
};

export const signupButtonText: SignalExtractor = (form) => {
  if (!containsAny(submitText(form), SIGNUP_TERMS)) return null;
  return {
    name: 'signupButtonText',
    weight: WEIGHTS.signupButtonText,
    contribution: WEIGHTS.signupButtonText,
  };
};

export const signinButtonText: SignalExtractor = (form) => {
  const text = submitText(form);
  // "Sign in" vocab on the submit is only a sign-in signal when the form's
  // buttons don't also carry sign-up vocab (e.g. "Sign up" next to a
  // "sign in instead" link inside the form counts as sign-up context).
  if (!containsAny(text, SIGNIN_TERMS) || containsAny(text, SIGNUP_TERMS)) return null;
  return {
    name: 'signinButtonText',
    weight: WEIGHTS.signinButtonText,
    contribution: -WEIGHTS.signinButtonText,
  };
};

function pathSignal(name: keyof typeof WEIGHTS, raw: string | null): SignalContribution | null {
  if (!raw) return null;
  const lower = raw.toLowerCase();
  const up = SIGNUP_PATH_TERMS.some((t) => lower.includes(t));
  const down = SIGNIN_PATH_TERMS.some((t) => lower.includes(t));
  if (up === down) return null;
  const weight = WEIGHTS[name];
  return { name, weight, contribution: up ? weight : -weight };
}

export const formActionUrl: SignalExtractor = (form) => {
  return pathSignal('formActionUrl', form.getAttribute('action'));
};

export const pageUrl: SignalExtractor = (_form, ctx) => {
  let pathname = ctx.url;
  try {
    pathname = new URL(ctx.url).pathname;
  } catch {
    /* keep raw string */
  }
  return pathSignal('pageUrl', pathname);
};

/**
 * How many preceding headings the walk may consult. One non-committal
 * heading between the real one and the form used to be enough to lose the
 * signal (#1396: WordPress puts a terms-of-service h2 between "Create your
 * account" and its sign-up form), so the walk continues past a heading that
 * matches neither vocabulary. It is bounded rather than open-ended because
 * far enough up any page there is a nav or footer heading that says
 * "Sign in" about something other than this form.
 */
const HEADING_LOOKBACK = 3;

export const headingText: SignalExtractor = (form, ctx) => {
  // Nearest first: headings inside the form, then the preceding ones walking
  // back up the document.
  const preceding = Array.from(ctx.document.querySelectorAll('h1, h2, h3')).filter(
    (h) => !!(form.compareDocumentPosition(h) & Node.DOCUMENT_POSITION_PRECEDING),
  );
  const candidates = [
    ...Array.from(form.querySelectorAll('h1, h2, h3')),
    ...preceding.reverse().slice(0, HEADING_LOOKBACK),
  ];
  for (const candidate of candidates) {
    const heading = candidate.textContent;
    if (!heading) continue;
    const up = containsAny(heading, SIGNUP_TERMS);
    const down = containsAny(heading, SIGNIN_TERMS);
    // Says both or neither: not this heading's answer to give.
    if (up === down) continue;
    return {
      name: 'headingText',
      weight: WEIGHTS.headingText,
      contribution: up ? WEIGHTS.headingText : -WEIGHTS.headingText,
    };
  }
  return null;
};

const SIGNUP_FIELD_TERMS = ['confirm password', 'choose username', 'choose a username', 'pick a password', 'choose a password', 'create password', 'create a password', 'repeat password', 'verify password'];

export const fieldLabels: SignalExtractor = (form, ctx) => {
  if (!containsAny(fieldAnnotationText(form, ctx), SIGNUP_FIELD_TERMS)) return null;
  return {
    name: 'fieldLabels',
    weight: WEIGHTS.fieldLabels,
    contribution: WEIGHTS.fieldLabels,
  };
};

/**
 * Everything a field says about itself, for role matching. Sites label the
 * same field through any of these and agree on none of them.
 */
function fieldIdentity(input: HTMLInputElement): string {
  return [
    input.name,
    input.id,
    input.autocomplete,
    input.placeholder,
    input.getAttribute('aria-label') ?? '',
  ]
    .join(' ')
    .toLowerCase();
}

const USERNAME_PATTERN = /user\s*[-_]?name|nickname|screen\s*[-_]?name|\bhandle\b|\bpseudo\b/;
// `\bname\b` catches `name="name"` and `id="new-account-name"` without
// matching `username`, where the `name` has a word character before it.
const FULL_NAME_PATTERN = /full\s*[-_]?name|first\s*[-_]?name|last\s*[-_]?name|given\s*[-_]?name|family\s*[-_]?name|real\s*[-_]?name|\bname\b/;

/**
 * A form collecting an email *and* a separate username *and* a name is
 * registration-shaped: sign-in forms ask for one identifier, not three.
 * This is the general counterweight to a site that mislabels its sign-up
 * password (#1395: Discourse's older sign-up form carries
 * `autocomplete="current-password"` on a new-account password field, worth
 * -3.0, on a form whose id is even `login-form`).
 *
 * Deliberately structural rather than vocabulary: the same page defeats a
 * label-text fix twice over, because its "Password Again" label points at an
 * id that does not exist on the page. Three *distinct* fillable fields are
 * required, so the common "username or email" single input does not count
 * twice.
 */
export const multipleIdentityFields: SignalExtractor = (form) => {
  const email = findEmailField(form);
  if (!email) return null;
  const others = fillableFields(form).filter((i) => i !== email && i.type === 'text');
  const username = others.find((i) => USERNAME_PATTERN.test(fieldIdentity(i)));
  if (!username) return null;
  const fullName = others.find(
    (i) => i !== username && FULL_NAME_PATTERN.test(fieldIdentity(i)),
  );
  if (!fullName) return null;
  return {
    name: 'multipleIdentityFields',
    weight: WEIGHTS.multipleIdentityFields,
    contribution: WEIGHTS.multipleIdentityFields,
  };
};

/**
 * How far above the form the agreement text may sit. A passwordless
 * first-step sign-up puts it outside the form entirely: WordPress's
 * `/start/account/user` renders "By continuing ... you agree to our Terms of
 * Service" in an h2 four levels above the <form> (#1408). The walk stops at
 * <body> as well as at this bound, so a site-wide footer linking the terms
 * never counts as this form's agreement.
 */
const AGREEMENT_LOOKUP = 4;

/** The form and the bounded run of ancestors an agreement may live in. */
function agreementRegions(form: HTMLFormElement): Element[] {
  const regions: Element[] = [form];
  let parent = form.parentElement;
  for (
    let level = 0;
    level < AGREEMENT_LOOKUP && parent && parent.tagName !== 'BODY' && parent.tagName !== 'HTML';
    level += 1
  ) {
    regions.push(parent);
    parent = parent.parentElement;
  }
  return regions;
}

/**
 * The user is being asked to enter a legal agreement, which is what account
 * creation is and what signing in, subscribing to a newsletter or sending a
 * contact form is not. Two shapes count, and they are one signal rather than
 * two because they are one piece of evidence: an explicit terms checkbox
 * inside the form, or agreement prose next to it naming a legal document.
 *
 * Both halves are required in the prose case. A reference on its own is a
 * link (every page footer has one) and an agreement phrase on its own is
 * ordinary copy ("by continuing you accept a longer delivery time"); it is
 * the pair, inside a bounded region around the form, that means an account.
 *
 * Weighted below the contextual signals on purpose: on its own it can only
 * move a form within `ambiguous`, so it takes a second signal -- a committal
 * heading, a self-describing URL -- to reach an automatic offer.
 */
export const legalAgreement: SignalExtractor = (form) => {
  const checkboxes = Array.from(
    form.querySelectorAll<HTMLInputElement>('input[type="checkbox"]'),
  );
  const checked = checkboxes.some((box) => {
    const label = box.closest('label') ?? box.parentElement;
    return containsAny(label?.textContent ?? '', ['terms', 'privacy policy', 'conditions']);
  });
  const acknowledged =
    checked ||
    agreementRegions(form).some((region) => {
      const text = region.textContent ?? '';
      return containsAny(text, AGREEMENT_TERMS) && containsAny(text, LEGAL_DOCUMENT_TERMS);
    });
  if (!acknowledged) return null;
  return {
    name: 'legalAgreement',
    weight: WEIGHTS.legalAgreement,
    contribution: WEIGHTS.legalAgreement,
  };
};

export const SIGNAL_EXTRACTORS: SignalExtractor[] = [
  newPasswordAutocomplete,
  currentPasswordAutocomplete,
  twoPasswordFields,
  signupButtonText,
  signinButtonText,
  formActionUrl,
  pageUrl,
  headingText,
  fieldLabels,
  multipleIdentityFields,
  legalAgreement,
];
