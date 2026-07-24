import AuthShell from '../Login/AuthShell';

/**
 * Post-login MFA enrollment nudge (identity plan Phase 1, all-users
 * extension). Shown after sign-in when the account has no MFA factor:
 * the require_admin_mfa trigger's user gate will eventually enforce
 * enrollment (new accounts get a grace window), so this screen is the
 * funnel that gets users enrolled while the gate is still soft.
 *
 * Deliberately skippable: enforcement lives server-side in the
 * pre-token-generation trigger, not in the client. The screen returns
 * at each sign-in until the user enrolls.
 */
function EnrollMfa({ onSetUp, onLater }) {
  const headerRight = onLater ? (
    <span><a href="#" onClick={onLater}>Later</a></span>
  ) : null;
  return (
    <AuthShell headerRight={headerRight} cardSize="narrow">
      <p className="auth__eyebrow">Security</p>
      <h1 className="auth__title">Protect your account.</h1>
      <p className="auth__subtitle">
        Your mailbox is only as safe as your password. Add an
        authenticator app so signing in takes a code only you can
        produce &mdash; enrollment may become required for continued
        access.
      </p>
      <button
        type="button"
        className="auth__btn-primary"
        onClick={onSetUp}
      >
        Set up two-factor authentication
      </button>
      {onLater ? (
        <p className="auth__alt">
          <a href="#" onClick={onLater}>Remind me later</a>
        </p>
      ) : null}
    </AuthShell>
  );
}

export default EnrollMfa;
