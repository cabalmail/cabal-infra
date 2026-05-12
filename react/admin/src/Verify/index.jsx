import AuthShell from '../Login/AuthShell';

function formatLockout(seconds) {
  if (seconds >= 60) {
    const mins = Math.ceil(seconds / 60);
    return `${mins} minute${mins === 1 ? '' : 's'}`;
  }
  return `${seconds} second${seconds === 1 ? '' : 's'}`;
}

function Verify({
  onSubmit,
  onCodeChange,
  code,
  onBackToSignIn,
  onResend,
  resendCooldown = 0,
  resendLocked = false,
  resendLockoutRemaining = 0,
}) {
  const headerRight = onBackToSignIn ? (
    <span><a href="#" onClick={onBackToSignIn}>Back to sign in</a></span>
  ) : null;
  const resendDisabled = resendLocked || resendCooldown > 0;
  let resendBody;
  if (resendLocked) {
    resendBody = (
      <span className="auth__resend-locked">
        Too many resend attempts. Try again in {formatLockout(resendLockoutRemaining)}.
      </span>
    );
  } else if (resendCooldown > 0) {
    resendBody = (
      <span className="auth__resend-cooldown">
        Resend available in {resendCooldown}s
      </span>
    );
  } else {
    resendBody = (
      <>
        Didn&rsquo;t get it?{' '}
        <button
          type="button"
          onClick={onResend}
          disabled={resendDisabled || !onResend}
        >
          Resend code
        </button>
      </>
    );
  }
  return (
    <AuthShell headerRight={headerRight} cardSize="narrow">
      <p className="auth__eyebrow">Verify</p>
      <h1 className="auth__title">Enter your code.</h1>
      <p className="auth__subtitle">
        A verification code has been sent to your phone. Enter it below to
        complete registration.
      </p>
      <form className="auth__form" onSubmit={onSubmit} noValidate>
        <div className="auth__field">
          <div className="auth__field-header">
            <label className="auth__field-label" htmlFor="verificationCode">Verification code</label>
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
          />
        </div>
        <button type="submit" className="auth__btn-primary">Verify</button>
      </form>
      {onResend ? (
        <p className="auth__alt auth__resend" aria-live="polite">
          {resendBody}
        </p>
      ) : null}
    </AuthShell>
  );
}

export default Verify;
