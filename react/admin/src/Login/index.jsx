import { useState } from 'react';
import AuthShell from './AuthShell';
import PasswordField from './PasswordField';
import UsernameField from './UsernameField';

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
        <UsernameField value={username} onChange={onUsernameChange} />
        <PasswordField
          label="Password"
          autoComplete="current-password"
          value={password}
          onChange={onPasswordChange}
          visible={showPassword}
          onToggleVisible={() => setShowPassword(s => !s)}
          headerHint={onForgotPassword ? (
            <button
              type="button"
              className="auth__field-hint"
              onClick={onForgotPassword}
            >
              Forgot password?
            </button>
          ) : null}
        />
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
