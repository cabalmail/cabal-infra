import AuthShell from '../Login/AuthShell';

/**
 * Second-factor challenge screen (identity plan Phase 1). Shown when
 * Cognito answers a password login with a SOFTWARE_TOKEN_MFA (TOTP) or
 * SMS_MFA challenge; App.jsx holds the pending CognitoUser and completes
 * the login via sendMFACode when this form submits.
 */
function MfaChallenge({
  onSubmit,
  onCodeChange,
  code,
  mfaType = 'totp',
  onBackToSignIn,
}) {
  const headerRight = onBackToSignIn ? (
    <span><a href="#" onClick={onBackToSignIn}>Back to sign in</a></span>
  ) : null;
  return (
    <AuthShell headerRight={headerRight} cardSize="narrow">
      <p className="auth__eyebrow">Two-factor</p>
      <h1 className="auth__title">Enter your code.</h1>
      <p className="auth__subtitle">
        {mfaType === 'totp'
          ? 'Enter the 6-digit code from your authenticator app.'
          : 'Enter the code we just sent to your phone.'}
      </p>
      <form className="auth__form" onSubmit={onSubmit} noValidate>
        <div className="auth__field">
          <div className="auth__field-header">
            <label className="auth__field-label" htmlFor="verificationCode">
              Authentication code
            </label>
          </div>
          <input
            id="verificationCode"
            name="verificationCode"
            type="text"
            className="mono"
            autoComplete="one-time-code"
            inputMode="numeric"
            placeholder="123456"
            onChange={onCodeChange}
            value={code || ''}
            required
            autoFocus
          />
        </div>
        <button type="submit" className="auth__btn-primary">Verify</button>
      </form>
    </AuthShell>
  );
}

export default MfaChallenge;
