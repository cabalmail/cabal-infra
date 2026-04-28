import { useState } from 'react';
import AuthShell from '../Login/AuthShell';

function ResetPassword({ onSubmit, onCodeChange, onPasswordChange, code, password, onBackToSignIn }) {
  const [showPassword, setShowPassword] = useState(false);
  const headerRight = onBackToSignIn ? (
    <span><a href="#" onClick={onBackToSignIn}>Back to sign in</a></span>
  ) : null;
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
    </AuthShell>
  );
}

export default ResetPassword;
