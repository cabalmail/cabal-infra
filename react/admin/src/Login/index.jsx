import { useState } from 'react';
import AuthShell from './AuthShell';

/**
 * Sign-in screen per redesign §1: narrow card, eyebrow + title + subtitle,
 * mono username field, password field with Show/Hide adornment + inline
 * "Forgot password?" link, and a "Sign up" link in the header and below
 * the card.
 */
function Login({
  onSubmit,
  onUsernameChange,
  onPasswordChange,
  username,
  password,
  onForgotPassword,
  onSignUp,
}) {
  const [showPassword, setShowPassword] = useState(false);
  const headerRight = onSignUp ? (
    <span>
      New to Cabalmail?{' '}
      <a href="#" onClick={onSignUp}>Create an account</a>
    </span>
  ) : null;
  return (
    <AuthShell headerRight={headerRight} cardSize="narrow">
      <p className="auth__eyebrow">Sign in</p>
      <h1 className="auth__title">Welcome back.</h1>
      <p className="auth__subtitle">
        Log in with the username you chose when you signed up.
      </p>
      <form className="auth__form" onSubmit={onSubmit} noValidate>
        <div className="auth__field">
          <div className="auth__field-header">
            <label className="auth__field-label" htmlFor="userName">Username</label>
          </div>
          <input
            id="userName"
            name="userName"
            type="text"
            className="mono"
            autoComplete="username"
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck="false"
            placeholder="your-username"
            onChange={onUsernameChange}
            value={username || ''}
            required
          />
        </div>
        <div className="auth__field">
          <div className="auth__field-header">
            <label className="auth__field-label" htmlFor="password">Password</label>
            {onForgotPassword ? (
              <button
                type="button"
                className="auth__field-hint"
                onClick={onForgotPassword}
              >
                Forgot password?
              </button>
            ) : null}
          </div>
          <div className="auth__field-adorn">
            <input
              id="password"
              name="password"
              type={showPassword ? 'text' : 'password'}
              autoComplete="current-password"
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
        <button type="submit" className="auth__btn-primary">Sign in</button>
      </form>
      {onSignUp ? (
        <p className="auth__alt">
          Don&rsquo;t have an account yet?{' '}
          <a href="#" onClick={onSignUp}>Sign up</a>
        </p>
      ) : null}
    </AuthShell>
  );
}

export default Login;
