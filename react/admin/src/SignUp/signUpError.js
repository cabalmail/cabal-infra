/**
 * The message to show when Cognito refuses a sign-up.
 *
 * The check_invite pre-sign-up trigger refuses a wrong invitation code and
 * a username it cannot use. Cognito hands either back as a
 * UserLambdaValidationException whose message wraps the trigger's own:
 * "PreSignUp failed with error <message>." (the trigger's message keeps its
 * full stop, so the end is often ".."). That trigger writes its messages
 * for people, so show them. Any other trigger's failure (the
 * post-confirmation trigger runs inside the same call when the account is
 * confirmed at sign-up) stays the generic failure.
 *
 * Cognito's own refusals get their own sentences too, because "Registration
 * failed." left the user with no idea which field to fix (#2141). These are
 * the sentences the native clients use, so the same refusal reads the same
 * on every client - see
 * `apple/CabalmailUI/Session/SignUp/SignUpErrorText.swift`.
 *
 * @param {{code?: string, name?: string, message?: string}|null} err - the
 *   CognitoError the auth client's signUp rejected with (src/auth).
 * @returns {string} the message for the sign-up screen.
 */
const RATE_LIMIT_TYPES = [
  'LimitExceededException',
  'TooManyRequestsException',
  'TooManyFailedAttemptsException',
];

export function signUpErrorMessage(err) {
  const text = (err && err.message) || '';
  if (/invitation code/i.test(text)) return 'Invalid invitation code.';
  const type = err && (err.code || err.name);
  const wrapped = /^PreSignUp failed with error ([\s\S]*)$/.exec(text);
  if (type === 'UserLambdaValidationException' && wrapped) {
    const fromTrigger = wrapped[1].replace(/\.\.$/, '.').trim();
    if (fromTrigger) return fromTrigger;
  }
  if (RATE_LIMIT_TYPES.includes(type)) return 'Too many attempts. Please try again later.';
  if (type === 'UsernameExistsException') return 'That username is taken. Choose another.';
  if (type === 'InvalidPasswordException') {
    // "Password did not conform with policy: Password must have uppercase
    // characters" - the part after the colon says what to change. A
    // compromised-password refusal carries no policy clause, so it passes
    // through whole.
    return sentence(text.split('policy: ').pop()) || 'Registration failed.';
  }
  // "Invalid phone number format.", "Invalid email address format."
  if (type === 'InvalidParameterException') return sentence(text) || 'Registration failed.';
  return 'Registration failed.';
}

/**
 * Cognito's messages arrive with and without a full stop.
 *
 * @param {string} [text]
 * @returns {string} the sentence, or '' when there was nothing to show.
 */
function sentence(text) {
  const trimmed = (text || '').trim();
  if (!trimmed) return '';
  return /\.$/.test(trimmed) ? trimmed : `${trimmed}.`;
}
