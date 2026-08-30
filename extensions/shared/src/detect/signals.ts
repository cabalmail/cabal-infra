/**
 * Individual signal extractors for the sign-up/sign-in classifier.
 * Each is a pure function of (form, context); it returns `null` when the
 * signal is absent, or a contribution whose sign points at sign-up (+) or
 * sign-in (-). The GET-vs-POST distinction is deliberately not a signal:
 * both verbs appear on both kinds of form (see the plan doc).
 */

import type { SignalContribution } from '../models/index';
import {
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

export const headingText: SignalExtractor = (form, ctx) => {
  // Nearest heading: inside the form, else the closest preceding h1/h2/h3.
  let heading = form.querySelector('h1, h2, h3')?.textContent ?? null;
  if (!heading) {
    const headings = Array.from(ctx.document.querySelectorAll('h1, h2, h3'));
    for (const h of headings) {
      const pos = form.compareDocumentPosition(h);
      if (pos & Node.DOCUMENT_POSITION_PRECEDING) heading = h.textContent;
    }
  }
  if (!heading) return null;
  const up = containsAny(heading, SIGNUP_TERMS);
  const down = containsAny(heading, SIGNIN_TERMS);
  if (up === down) return null;
  return {
    name: 'headingText',
    weight: WEIGHTS.headingText,
    contribution: up ? WEIGHTS.headingText : -WEIGHTS.headingText,
  };
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

export const termsCheckbox: SignalExtractor = (form) => {
  const checkboxes = Array.from(
    form.querySelectorAll<HTMLInputElement>('input[type="checkbox"]'),
  );
  const hit = checkboxes.some((box) => {
    const label = box.closest('label') ?? box.parentElement;
    return containsAny(label?.textContent ?? '', ['terms', 'privacy policy', 'conditions']);
  });
  if (!hit) return null;
  return {
    name: 'termsCheckbox',
    weight: WEIGHTS.termsCheckbox,
    contribution: WEIGHTS.termsCheckbox,
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
  termsCheckbox,
];
