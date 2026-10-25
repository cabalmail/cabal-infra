import { describe, it, expect } from 'vitest';
import {
  PASSWORD_HINT,
  PASSWORD_MINIMUM,
  isE164Phone,
  normalizePhone,
} from './signUpFields';

// Issue #2141: the form accepted phone numbers the user pool cannot take and
// sent them as typed, so `+1 555 123 4567` passed every check here and came
// back from Cognito as InvalidParameterException ("Invalid phone number
// format.") — which the screen showed as a bare "Registration failed."
describe('normalizePhone', () => {
  it('strips the punctuation people type', () => {
    // The report's own example, and the placeholder the form used to show.
    expect(normalizePhone('+1 555 123 4567')).toBe('+15551234567');
    expect(normalizePhone('+1 (555) 123-4567')).toBe('+15551234567');
    expect(normalizePhone('+1.555.123.4567')).toBe('+15551234567');
    expect(normalizePhone('  +15551234567  ')).toBe('+15551234567');
  });

  it('leaves a number that is already E.164 alone', () => {
    expect(normalizePhone('+15551234567')).toBe('+15551234567');
  });

  it('does not invent a country code', () => {
    // It strips punctuation; it does not repair a number. `isE164Phone` is
    // what decides the result is usable, so a local number stays refused
    // rather than being sent as a guess.
    expect(normalizePhone('555-123-4567')).toBe('5551234567');
    expect(isE164Phone(normalizePhone('555-123-4567'))).toBe(false);
  });

  it('answers an empty string for nothing', () => {
    expect(normalizePhone('')).toBe('');
    expect(normalizePhone(undefined)).toBe('');
    expect(normalizePhone(null)).toBe('');
  });
});

describe('isE164Phone', () => {
  it('takes a leading plus, a country code and 7 to 15 digits', () => {
    expect(isE164Phone('+15551234567')).toBe(true);
    expect(isE164Phone('+442071234567')).toBe(true);
    expect(isE164Phone('+1234567')).toBe(true);
    expect(isE164Phone('+123456789012345')).toBe(true);
  });

  it('refuses what Cognito refuses', () => {
    expect(isE164Phone('5551234567')).toBe(false);
    expect(isE164Phone('+01234567')).toBe(false);
    expect(isE164Phone('+123456')).toBe(false);
    expect(isE164Phone('+1234567890123456')).toBe(false);
    expect(isE164Phone('+1 555 123 4567')).toBe(false);
    expect(isE164Phone('++15551234567')).toBe(false);
    expect(isE164Phone('')).toBe(false);
    expect(isE164Phone(undefined)).toBe(false);
  });
});

describe('PASSWORD_HINT', () => {
  // It used to read "At least 12 characters. A passphrase is better than a
  // clever one.", which recommended exactly what the pool refuses: no
  // `password_policy` is set, so Cognito's default applies and wants upper
  // and lower case, a digit and a symbol.
  it('names the pool\'s character classes as well as the length', () => {
    expect(PASSWORD_HINT).toContain(String(PASSWORD_MINIMUM));
    expect(PASSWORD_HINT).toMatch(/upper- and lowercase/);
    expect(PASSWORD_HINT).toMatch(/numbers/);
    expect(PASSWORD_HINT).toMatch(/symbols/);
  });

  it('no longer recommends a passphrase', () => {
    expect(PASSWORD_HINT).not.toMatch(/passphrase/i);
  });
});
