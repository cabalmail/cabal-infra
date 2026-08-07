import { QRCodeSVG } from 'qrcode.react';
import AuthShell from '../Login/AuthShell';
import VerificationCodeField from '../Login/VerificationCodeField';
import './MfaSetup.css';

/**
 * Locked-out TOTP setup (identity plan Phase 1 follow-up). Shown when
 * the require_admin_mfa gate rejects a password login because the
 * account has no MFA factor: the normal client cannot issue a session
 * to enroll with, so App.jsx re-authenticates through the dedicated
 * enrollment app client and completes the enrollment here. Two phases:
 * an offer screen (no secret yet), then the QR/confirm form once
 * associateSoftwareToken has produced a secret.
 */
function MfaSetup({
  userName,
  secret,
  busy,
  code,
  onBegin,
  onCodeChange,
  onSubmit,
  onCancel,
}) {
  const headerRight = (
    <span><a href="#" onClick={onCancel}>Back to sign in</a></span>
  );

  // otpauth URI per the Key Uri Format; label is issuer:account so
  // authenticator apps group the entry under Cabalmail (matches the
  // Security view's enrollment).
  const otpauthUri = secret
    ? `otpauth://totp/${encodeURIComponent(`Cabalmail:${userName || 'user'}`)}?secret=${secret}&issuer=Cabalmail`
    : null;

  if (!secret) {
    return (
      <AuthShell headerRight={headerRight} cardSize="narrow">
        <p className="auth__eyebrow">Security</p>
        <h1 className="auth__title">Two-factor is required.</h1>
        <p className="auth__subtitle">
          This account requires multi-factor authentication before it
          can sign in. Set up an authenticator app now to restore
          access &mdash; it only takes a minute.
        </p>
        <button
          type="button"
          className="auth__btn-primary"
          onClick={onBegin}
          disabled={busy}
        >
          Set up authenticator app
        </button>
      </AuthShell>
    );
  }

  return (
    <AuthShell headerRight={headerRight} cardSize="narrow">
      <p className="auth__eyebrow">Security</p>
      <h1 className="auth__title">Scan, then confirm.</h1>
      <p className="auth__subtitle">
        Scan this QR code with an authenticator app (1Password, Google
        Authenticator, Authy, &hellip;), then enter the 6-digit code it
        shows.
      </p>
      <div className="mfa-setup__qr" aria-label="TOTP enrollment QR code">
        <QRCodeSVG value={otpauthUri} size={168} marginSize={2} />
      </div>
      <p className="mfa-setup__manual">
        Can&rsquo;t scan? Enter this key manually:{' '}
        <code className="mfa-setup__secret">{secret}</code>
      </p>
      <form className="auth__form" onSubmit={onSubmit} noValidate>
        <VerificationCodeField
          label="Code from your app"
          value={code}
          onChange={onCodeChange}
          autoFocus
        />
        <button
          type="submit"
          className="auth__btn-primary"
          disabled={busy || (code || '').length < 6}
        >
          Confirm
        </button>
      </form>
    </AuthShell>
  );
}

export default MfaSetup;
