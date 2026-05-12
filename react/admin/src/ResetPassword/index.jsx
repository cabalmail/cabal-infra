import { useState } from 'react';
import AuthShell from '../Login/AuthShell';

function formatLockout(seconds) {
  if (seconds >= 60) {
    const mins = Math.ceil(seconds / 60);
    return `${mins} minute${mins === 1 ? '' : 's'}`;
  }
  return `${seconds} second${seconds === 1 ? '' : 's'}`;
}

function ResetPassword({
  onSubmit,
  onCodeChange,
  onPasswordChange,
  code,
  password,
  onBackToSignIn,
  onResend,
  resendCooldown = 0,
  resendLocked = false,
  resendLockoutRemaining = 0,
}) {
  const [showPassword, setShowPassword] = useState(false);
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
      <p className="auth__eyebrow">Reset</p>
      <h1 className="auth__title">Choose a new password.</h1>
      <p className="auth__subtitle">
        Enter the code sent to your phone and your new password.
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
        <div className="auth__field">
          <div className="auth__field-header">
            <label className="auth__field-label" htmlFor="password">New password</label>
          </div>
          <div className="auth__field-adorn">
            <input
              id="password"
              name="password"
              type={showPassword ? 'text' : 'password'}
              autoComplete="new-password"
              placeholder="••••••••"
              onChange={onPasswordChange}
              value={password || ''}
              required
            />
            <button
              type="button"
              className="auth__field-adorn-btn"
              onClick={() => setShowPassword(s => !s)}
              aria-label={showPassword ? 'Hide password' : 'Show password'}
            >
              {showPassword ? 'Hide' : 'Show'}
            </button>
          </div>
        </div>
        <button type="submit" className="auth__btn-primary">Reset password</button>
      </form>
      {onResend ? (
        <p className="auth__alt auth__resend" aria-live="polite">
          {resendBody}
        </p>
      ) : null}
    </AuthShell>
  );
}

export default ResetPassword;
