/**
 * Field rules the sign-up form and the sign-up call share.
 *
 * The form used to validate shapes the user pool cannot accept and then
 * send what was typed, so `+1 555 123 4567` passed the form and came back
 * as an unexplained "Registration failed." (#2141). These are the same
 * rules the native clients apply, so a sign-up that the form accepts is one
 * Cognito accepts on every client — see
 * `apple/CabalmailUI/Session/SignUp/SignUpModel.swift`.
 */

/**
 * The webmail's own password floor. The pool's character-class policy
 * (Cognito's default: upper and lower case, a digit and a symbol) is
 * checked by Cognito, and its refusal names the part that failed —
 * `signUpErrorMessage` passes that reason through.
 */
export const PASSWORD_MINIMUM = 12;

/** What the password field tells the user to type, matching the pool. */
export const PASSWORD_HINT =
  `At least ${PASSWORD_MINIMUM} characters, mixing upper- and lowercase letters, numbers and symbols.`;

/**
 * Drops everything Cognito will not take from a typed phone number,
 * leaving E.164. Digits and `+` survive wherever they were typed, so
 * `isE164Phone` is still what decides the result is usable: this does not
 * repair a number, it only strips the punctuation people type.
 *
 * @param {string} [phone]
 * @returns {string} the phone number in E.164 form, or what is left of it.
 */
export function normalizePhone(phone) {
  return (phone || '').replace(/[^0-9+]/g, '');
}

/**
 * `+`, a country code that doesn't start with 0, and 7 to 15 digits in all
 * — the shape Cognito's `phone_number` attribute requires.
 *
 * @param {string} [phone] - already through `normalizePhone`.
 * @returns {boolean}
 */
export function isE164Phone(phone) {
  return /^\+[1-9][0-9]{6,14}$/.test(phone || '');
}
