/**
 * Errors from the Cognito JSON client, and the predicates the webmail
 * branches on.
 *
 * A CognitoError carries Cognito's exception name in both `code` and
 * `name`, the shape amazon-cognito-identity-js handed its callbacks, so
 * checks written against the library (`err.code === 'LimitExceededException'`,
 * signUpErrorMessage) keep working against this module.
 */

export class CognitoError extends Error {
  /**
   * @param {string} code - Cognito's exception name, without the
   *   `com.amazonaws...#` prefix, or one of this module's own codes
   *   (NetworkError, UnreadableResponse, UnsupportedChallenge,
   *   SessionExpired, NotSignedIn).
   * @param {string} message - Cognito's message, or this module's.
   * @param {{status?: number, cause?: unknown}} [options] - the HTTP status
   *   when the error came from a response, and the underlying error.
   */
  constructor(code, message, { status, cause } = {}) {
    super(message || code, cause === undefined ? undefined : { cause });
    this.name = code;
    this.code = code;
    this.status = status;
  }
}

/**
 * Build the error for a non-2xx Cognito response.
 *
 * Cognito names the exception in `__type`, sometimes prefixed with a
 * namespace (`com.amazonaws.cognito.identity.idp.model#NotAuthorizedException`),
 * and some operations use `code` instead.
 *
 * @param {number} status - HTTP status.
 * @param {object|null} body - parsed JSON body, or null when it wasn't JSON.
 * @returns {CognitoError}
 */
export function errorFromResponse(status, body) {
  const raw = (body && (body.__type || body.code)) || '';
  const code = String(raw).split('#').pop() || 'UnknownError';
  const message = (body && (body.message || body.Message)) || `Cognito returned HTTP ${status}.`;
  return new CognitoError(code, message, { status });
}

function hasCode(err, ...codes) {
  return !!err && codes.includes(err.code || err.name);
}

/**
 * The check_invite pre-sign-up trigger refused the invitation code. Cognito
 * wraps the trigger's "Invalid invitation code." in a
 * UserLambdaValidationException ("PreSignUp failed with error ...").
 *
 * @param {unknown} err
 * @returns {boolean}
 */
export function isInvalidInvitationCode(err) {
  return hasCode(err, 'UserLambdaValidationException')
    && /invitation code/i.test(err.message || '');
}

/**
 * The require_admin_mfa pre-token-generation trigger refused a sign-in
 * because the account has no second factor. The webmail answers it with
 * the locked-out TOTP setup through the enrollment client.
 *
 * Matched on the message alone, as the webmail always has: the trigger's
 * wording is the contract, and "admin accounts require" is its older
 * phrasing.
 *
 * @param {unknown} err
 * @returns {boolean}
 */
export function isMfaEnrollmentRequired(err) {
  return !!err && /require.*multi-factor|admin accounts require/i.test(err.message || '');
}

/**
 * A one-time code didn't match: the second factor at sign-in
 * (RespondToAuthChallenge), a confirmation or verification code, or the
 * first code from a new authenticator (VerifySoftwareToken, which reports
 * a wrong code as EnableSoftwareTokenMFAException).
 *
 * @param {unknown} err
 * @returns {boolean}
 */
export function isCodeMismatch(err) {
  return hasCode(err, 'CodeMismatchException', 'EnableSoftwareTokenMFAException');
}

/**
 * Cognito refused the credentials or the session: a wrong password, a
 * disabled user, or an MFA challenge session that has expired.
 *
 * @param {unknown} err
 * @returns {boolean}
 */
export function isNotAuthorized(err) {
  return hasCode(err, 'NotAuthorizedException');
}

/**
 * Cognito's per-user limit on sending codes (resend, forgot password,
 * attribute verification). The UI stops offering the action for a while.
 *
 * @param {unknown} err
 * @returns {boolean}
 */
export function isLimitExceeded(err) {
  return hasCode(err, 'LimitExceededException');
}

/**
 * The user has to sign in (again): there is no session, or Cognito refused
 * to refresh the one there was. Thrown by the session holder, never by the
 * client.
 *
 * @param {unknown} err
 * @returns {boolean}
 */
export function isSignInRequired(err) {
  return hasCode(err, 'SessionExpired', 'NotSignedIn');
}
