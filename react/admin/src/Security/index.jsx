import { useCallback, useEffect, useState } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import './Security.css';

/**
 * Account security view (identity plan Phase 1): TOTP two-factor
 * enrollment and management.
 *
 * The Cognito calls live in App.jsx (where the user pool client lives)
 * and arrive here as the `mfaApi` prop:
 *   getStatus(cb)            -> cb(err, enabled)
 *   beginEnroll(callbacks)   -> associateSecretCode(secret) / onFailure(err)
 *   confirmEnroll(code, cbs) -> onSuccess() / onFailure(err)
 *   disable(cb)              -> cb(err)
 *
 * Enrollment: fetch a secret, show it as a QR (otpauth:// URI) plus a
 * copyable manual key, then confirm with a code from the authenticator
 * app. Confirming also sets the user's MFA preference, so the next
 * login issues a SOFTWARE_TOKEN_MFA challenge.
 */
function Security({ userName, mfaApi, setMessage }) {
  // 'loading' | 'off' | 'on' | 'enrolling' | 'error'
  const [status, setStatus] = useState('loading');
  const [secret, setSecret] = useState(null);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);

  const refreshStatus = useCallback(() => {
    setStatus('loading');
    mfaApi.getStatus((err, enabled) => {
      if (err) {
        setStatus('error');
        return;
      }
      setStatus(enabled ? 'on' : 'off');
    });
  }, [mfaApi]);

  useEffect(() => {
    refreshStatus();
  }, [refreshStatus]);

  const beginEnroll = useCallback(() => {
    setBusy(true);
    mfaApi.beginEnroll({
      associateSecretCode: (secretCode) => {
        setBusy(false);
        setSecret(secretCode);
        setCode('');
        setStatus('enrolling');
      },
      onFailure: () => {
        setBusy(false);
        setMessage('Could not start enrollment. Please try again.', true);
      },
    });
  }, [mfaApi, setMessage]);

  const confirmEnroll = useCallback((e) => {
    e.preventDefault();
    setBusy(true);
    mfaApi.confirmEnroll(code, {
      onSuccess: () => {
        setBusy(false);
        setSecret(null);
        setCode('');
        setStatus('on');
        setMessage('Two-factor authentication is on. You will be asked for a code at your next sign-in.', false);
      },
      onFailure: () => {
        setBusy(false);
        setMessage('That code did not match. Check your authenticator app and try again.', true);
      },
    });
  }, [mfaApi, code, setMessage]);

  const cancelEnroll = useCallback(() => {
    setSecret(null);
    setCode('');
    setStatus('off');
  }, []);

  const disable = useCallback(() => {
    setBusy(true);
    mfaApi.disable((err) => {
      setBusy(false);
      if (err) {
        setMessage('Could not turn off two-factor authentication. Please try again.', true);
        return;
      }
      setStatus('off');
      setMessage('Two-factor authentication is off.', false);
    });
  }, [mfaApi, setMessage]);

  // otpauth URI per the Key Uri Format; label is issuer:account so
  // authenticator apps group the entry under Cabalmail.
  const otpauthUri = secret
    ? `otpauth://totp/${encodeURIComponent(`Cabalmail:${userName || 'user'}`)}?secret=${secret}&issuer=Cabalmail`
    : null;

  return (
    <div className="security">
      <header className="security__header">
        <h1 className="security__title">Security</h1>
        <p className="security__subtitle">
          Two-factor authentication protects your mailbox with a code from
          an authenticator app in addition to your password.
        </p>
      </header>

      <section className="security__section">
        <h2 className="security__h2">Two-factor authentication</h2>

        {status === 'loading' && <p>Checking status&hellip;</p>}

        {status === 'error' && (
          <p>
            Could not load your two-factor status.{' '}
            <button type="button" className="security__link" onClick={refreshStatus}>
              Retry
            </button>
          </p>
        )}

        {status === 'on' && (
          <>
            <p className="security__status security__status--on">
              Two-factor authentication is <strong>on</strong>. Signing in
              requires a code from your authenticator app.
            </p>
            <button
              type="button"
              className="security__btn security__btn--danger"
              onClick={disable}
              disabled={busy}
            >
              Turn off two-factor authentication
            </button>
          </>
        )}

        {status === 'off' && (
          <>
            <p className="security__status">
              Two-factor authentication is <strong>off</strong>. Anyone with
              your password can sign in.
            </p>
            <button
              type="button"
              className="security__btn"
              onClick={beginEnroll}
              disabled={busy}
            >
              Set up authenticator app
            </button>
          </>
        )}

        {status === 'enrolling' && secret && (
          <div className="security__enroll">
            <ol className="security__steps">
              <li>
                Scan this QR code with an authenticator app (1Password,
                Google Authenticator, Authy, &hellip;).
              </li>
              <li>Enter the 6-digit code the app shows to confirm.</li>
            </ol>
            <div className="security__qr" aria-label="TOTP enrollment QR code">
              <QRCodeSVG value={otpauthUri} size={168} marginSize={2} />
            </div>
            <p className="security__manual">
              Can&rsquo;t scan? Enter this key manually:{' '}
              <code className="security__secret">{secret}</code>
            </p>
            <form className="security__confirm" onSubmit={confirmEnroll}>
              <label className="security__label" htmlFor="totpCode">
                Code from your app
              </label>
              <input
                id="totpCode"
                name="totpCode"
                type="text"
                className="mono"
                autoComplete="one-time-code"
                inputMode="numeric"
                placeholder="123456"
                value={code}
                onChange={(e) => setCode(e.target.value)}
                required
              />
              <div className="security__confirm-actions">
                <button
                  type="submit"
                  className="security__btn"
                  disabled={busy || code.length < 6}
                >
                  Confirm
                </button>
                <button
                  type="button"
                  className="security__btn security__btn--quiet"
                  onClick={cancelEnroll}
                  disabled={busy}
                >
                  Cancel
                </button>
              </div>
            </form>
          </div>
        )}
      </section>
    </div>
  );
}

export default Security;
