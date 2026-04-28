import AuthShell from '../Login/AuthShell';

/**
 * Forgot-password screen per §3: single username field submits a Cognito
 * `forgotPassword` request. On success (controlled by `submitted` prop),
 * swap the form for a check-mark success state with "Back to sign in" and
 * "Enter reset code" actions. Flow continues in ResetPassword/.
 */
function ForgotPassword({
  onSubmit,
  onUsernameChange,
  username,
  onBackToSignIn,
  submitted,
  onProceed,
}) {
  const headerRight = onBackToSignIn ? (
    <span>
      Remembered it? <a href="#" onClick={onBackToSignIn}>Sign in</a>
    </span>
  ) : null;

  if (submitted) {
    return (
      <AuthShell headerRight={headerRight} cardSize="narrow">
        <div className="auth__success">
          <span className="auth__success-icon" aria-hidden="true">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none"
              stroke="currentColor" strokeWidth="2.5"
              strokeLinecap="round" strokeLinejoin="round">
              <polyline points="20 6 9 17 4 12" />
            </svg>
          </span>
          <h1 className="auth__success-title">Check your phone</h1>
          <p className="auth__success-body">
            If an account exists for <strong>{username}</strong>,
            you&rsquo;ll receive a reset code shortly.
          </p>
          <button
            type="button"
            className="auth__btn-primary"
            onClick={onProceed}
          >
            Enter reset code
          </button>
          <p className="auth__alt">
            <a href="#" onClick={onBackToSignIn}>Back to sign in</a>
          </p>
        </div>
      </AuthShell>
    );
  }

  return (
    <AuthShell headerRight={headerRight} cardSize="narrow">
      <p className="auth__eyebrow">Reset</p>
      <h1 className="auth__title">Forgot your password?</h1>
      <p className="auth__subtitle">
        Enter your username and we&rsquo;ll send a reset code to the phone
        number on file.
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
        <button type="submit" className="auth__btn-primary">
          Send reset code
        </button>
      </form>
      {onBackToSignIn ? (
        <p className="auth__alt">
          <a href="#" onClick={onBackToSignIn}>Back to sign in</a>
        </p>
      ) : null}
    </AuthShell>
  );
}

export default ForgotPassword;
