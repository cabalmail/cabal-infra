import AuthShell from '../Login/AuthShell';
import VerificationCodeField from '../Login/VerificationCodeField';

/**
 * Post-login email gate (identity plan Phase 1). Two modes:
 *
 * - "add": the account has no email attribute (users who signed up
 *   before email collection existed). Prompts for a recovery address;
 *   App.jsx saves it via updateAttributes, which makes Cognito send a
 *   verification code automatically.
 * - "verify": an email is on file but not verified. Code entry plus a
 *   "Send a new code" action (getAttributeVerificationCode).
 *
 * Both modes are skippable: existing SMS-only users must keep working
 * (the plan's migration constraint) and email is a recovery fallback,
 * not an access gate. The screen reappears at each login until the
 * address is verified.
 */
function VerifyEmail({
  mode,
  address,
  email,
  onEmailChange,
  onSaveEmail,
  onSubmit,
  onCodeChange,
  code,
  onSendCode,
  sendInFlight = false,
  onChangeEmail,
  onSkip,
}) {
  const headerRight = onSkip ? (
    <span><a href="#" onClick={onSkip}>Skip for now</a></span>
  ) : null;

  if (mode === 'add') {
    return (
      <AuthShell headerRight={headerRight} cardSize="narrow">
        <p className="auth__eyebrow">Recovery</p>
        <h1 className="auth__title">Add a recovery email.</h1>
        <p className="auth__subtitle">
          If you lose your phone, a verified email address is how you get
          back in. It is never used for mail delivery.
        </p>
        <form className="auth__form" onSubmit={onSaveEmail} noValidate>
          <div className="auth__field">
            <div className="auth__field-header">
              <label className="auth__field-label" htmlFor="email">Email address</label>
            </div>
            <input
              id="email"
              name="email"
              type="email"
              className="mono"
              autoComplete="email"
              autoCapitalize="off"
              autoCorrect="off"
              spellCheck="false"
              placeholder="you@example.com"
              onChange={onEmailChange}
              value={email || ''}
              required
            />
            <p className="auth__field-help">
              An existing address outside Cabalmail.
            </p>
          </div>
          <button type="submit" className="auth__btn-primary">
            Send verification code
          </button>
        </form>
        {onSkip ? (
          <p className="auth__alt">
            <a href="#" onClick={onSkip}>Skip for now</a>
          </p>
        ) : null}
      </AuthShell>
    );
  }

  return (
    <AuthShell headerRight={headerRight} cardSize="narrow">
      <p className="auth__eyebrow">Recovery</p>
      <h1 className="auth__title">Verify your email.</h1>
      <p className="auth__subtitle">
        We need to confirm <strong>{address}</strong> before it can be
        used for account recovery. Request a code, then enter it below.
      </p>
      <form className="auth__form" onSubmit={onSubmit} noValidate>
        <VerificationCodeField
          label="Verification code"
          value={code}
          onChange={onCodeChange}
        />
        <button type="submit" className="auth__btn-primary">Verify</button>
      </form>
      <p className="auth__alt auth__resend" aria-live="polite">
        {sendInFlight ? (
          <button type="button" disabled>Sending...</button>
        ) : (
          <>
            Need a code?{' '}
            <button type="button" onClick={onSendCode} disabled={!onSendCode}>
              Send a new code
            </button>
          </>
        )}
      </p>
      {onChangeEmail ? (
        <p className="auth__alt">
          Wrong address?{' '}
          <a href="#" onClick={onChangeEmail}>Use a different email</a>
        </p>
      ) : null}
    </AuthShell>
  );
}

export default VerifyEmail;
