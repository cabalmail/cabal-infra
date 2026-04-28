import AuthShell from '../Login/AuthShell';

function Verify({ onSubmit, onCodeChange, code, onBackToSignIn }) {
  const headerRight = onBackToSignIn ? (
    <span><a href="#" onClick={onBackToSignIn}>Back to sign in</a></span>
  ) : null;
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
    </AuthShell>
  );
}

export default Verify;
