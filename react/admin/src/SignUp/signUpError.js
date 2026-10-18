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
 * confirmed at sign-up) and anything else stays the generic failure.
 *
 * @param {{code?: string, name?: string, message?: string}|null} err - the
 *   error amazon-cognito-identity-js passed to the signUp callback.
 * @returns {string} the message for the sign-up screen.
 */
export function signUpErrorMessage(err) {
  const text = (err && err.message) || '';
  if (/invitation code/i.test(text)) return 'Invalid invitation code.';
  const type = err && (err.code || err.name);
  const wrapped = /^PreSignUp failed with error ([\s\S]*)$/.exec(text);
  if (type === 'UserLambdaValidationException' && wrapped) {
    const fromTrigger = wrapped[1].replace(/\.\.$/, '.').trim();
    if (fromTrigger) return fromTrigger;
  }
  return 'Registration failed.';
}
