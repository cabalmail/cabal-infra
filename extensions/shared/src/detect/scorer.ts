/** The scoring engine: sums signal contributions and applies the thresholds. */

import type { Classification, FormScore, SignalContribution } from '../models/index';
import { SIGNIN_THRESHOLD, SIGNUP_THRESHOLD } from './config';
import { findEmailField, SIGNAL_EXTRACTORS, type PageContext } from './signals';

// Lives with the signal extractors, which need it too; re-exported here
// because this is where callers have always found it.
export { findEmailField };

function classify(score: number, emailField: HTMLInputElement | null): Classification {
  if (!emailField) return 'not-an-auth-form';
  if (score >= SIGNUP_THRESHOLD) return 'signup';
  if (score <= SIGNIN_THRESHOLD) return 'signin';
  return 'ambiguous';
}

export function scoreForm(form: HTMLFormElement, ctx: PageContext): FormScore {
  const signals = SIGNAL_EXTRACTORS.map((fn) => fn(form, ctx)).filter(
    (s): s is SignalContribution => s !== null,
  );
  const score = signals.reduce((sum, c) => sum + c.contribution, 0);
  const emailField = findEmailField(form);
  return { form, emailField, score, classification: classify(score, emailField), signals };
}

/**
 * Stable key for a form, used to cache scores across MutationObserver churn
 * and to associate pending-address bookkeeping with the form it was minted for.
 */
export function formKey(form: HTMLFormElement): string {
  if (form.id) return `id:${form.id}`;
  if (form.getAttribute('name')) return `name:${form.getAttribute('name')}`;
  const fieldNames = Array.from(form.querySelectorAll<HTMLInputElement>('input'))
    .map((i) => i.name || i.id || i.type)
    .join(',');
  const action = form.getAttribute('action') ?? '';
  // Cheap stable hash (djb2) over the identifying string.
  let hash = 5381;
  const s = `${action}|${fieldNames}`;
  for (let i = 0; i < s.length; i += 1) {
    hash = ((hash << 5) + hash + s.charCodeAt(i)) | 0;
  }
  return `hash:${(hash >>> 0).toString(36)}`;
}
