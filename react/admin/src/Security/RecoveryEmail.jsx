import { useCallback, useEffect, useState } from 'react';
import { isCodeMismatch, isLimitExceeded } from '../auth';

const ADDRESS_SHAPE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * The Security view's recovery-email section: see, add, change and
 * verify the address. It is the only place after sign-up to add one,
 * which matters since docs/auth.md ("Sign-up") made the address optional
 * when the pool has SMS: the post-sign-in gate no longer asks a
 * phone-verified account for one.
 *
 * The Cognito calls live in App.jsx and arrive as the `recoveryApi`
 * prop, each returning a promise:
 *   load()         -> {address, verified}; address is null when there is none
 *   save(address)  -> UpdateUserAttributes; the pool auto-verifies email,
 *                     so Cognito sends the new address a code
 *   resend()       -> GetUserAttributeVerificationCode
 *   verify(code)   -> VerifyUserAttribute
 * A rejection is a CognitoError (src/auth/errors.js).
 */
function RecoveryEmail({ recoveryApi, smsEnabled, setMessage }) {
  // 'loading' | 'error' | 'ready' | 'editing' | 'verifying'
  const [status, setStatus] = useState('loading');
  const [current, setCurrent] = useState({ address: null, verified: false });
  const [draft, setDraft] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    setStatus('loading');
    recoveryApi.load().then((loaded) => {
      setCurrent(loaded);
      setStatus('ready');
    }, () => setStatus('error'));
  }, [recoveryApi]);

  useEffect(() => {
    load();
  }, [load]);

  const tooMany = (err) => (isLimitExceeded(err)
    ? 'Too many attempts. Please try again later.'
    : null);

  const startEditing = useCallback(() => {
    setDraft('');
    setStatus('editing');
  }, []);

  const save = useCallback((e) => {
    e.preventDefault();
    const address = draft.trim();
    setBusy(true);
    recoveryApi.save(address).then(() => {
      setBusy(false);
      setCurrent({ address, verified: false });
      setCode('');
      setStatus('verifying');
      setMessage(`A verification code has been sent to ${address}.`, false);
    }, (err) => {
      setBusy(false);
      setMessage(tooMany(err) || 'Could not save that address. Please try again.', true);
    });
  }, [recoveryApi, draft, setMessage]);

  const sendCode = useCallback(() => {
    setBusy(true);
    recoveryApi.resend().then(() => {
      setBusy(false);
      setCode('');
      setStatus('verifying');
      setMessage(`A verification code has been sent to ${current.address}.`, false);
    }, (err) => {
      setBusy(false);
      setMessage(tooMany(err) || 'Could not send a code. Please try again later.', true);
    });
  }, [recoveryApi, current.address, setMessage]);

  const verify = useCallback((e) => {
    e.preventDefault();
    setBusy(true);
    recoveryApi.verify(code.trim()).then(() => {
      setBusy(false);
      setCurrent((was) => ({ ...was, verified: true }));
      setCode('');
      setStatus('ready');
      setMessage('Email verified. It can now be used for account recovery.', false);
    }, (err) => {
      setBusy(false);
      setMessage(
        isCodeMismatch(err)
          ? 'That code did not match. Check the email and try again.'
          : tooMany(err) || 'Verification failed. Please check your code and try again.',
        true
      );
    });
  }, [recoveryApi, code, setMessage]);

  const cancel = useCallback(() => {
    setDraft('');
    setCode('');
    setStatus('ready');
  }, []);

  return (
    <section className="security__section">
      <h2 className="security__h2">Recovery email</h2>

      {status === 'loading' && <p>Checking your recovery email&hellip;</p>}

      {status === 'error' && (
        <p>
          Could not load your recovery email.{' '}
          <button type="button" className="security__link" onClick={load}>
            Retry
          </button>
        </p>
      )}

      {status === 'ready' && !current.address && (
        <>
          <p className="security__status">
            {smsEnabled
              ? 'You have no recovery email. Your phone number recovers your account; an address outside Cabalmail also gets you back in if you lose your phone.'
              : 'You have no recovery email. Add an address outside Cabalmail so you can get back in if you forget your password.'}
          </p>
          <button type="button" className="security__btn" onClick={startEditing}>
            Add recovery email
          </button>
        </>
      )}

      {status === 'ready' && current.address && (
        <>
          <p className="security__status">
            <strong className="security__address">{current.address}</strong>{' '}
            {current.verified
              ? 'is verified and can be used to recover your account.'
              : 'is not verified yet, so it cannot be used to recover your account.'}
          </p>
          <div className="security__confirm-actions">
            {!current.verified && (
              <button type="button" className="security__btn" onClick={sendCode} disabled={busy}>
                Verify address
              </button>
            )}
            <button type="button" className="security__btn security__btn--quiet" onClick={startEditing}>
              Change address
            </button>
          </div>
        </>
      )}

      {status === 'editing' && (
        <form className="security__confirm" onSubmit={save} noValidate>
          <label className="security__label" htmlFor="recoveryEmail">
            {current.address ? 'New recovery email' : 'Email address'}
          </label>
          <input
            id="recoveryEmail"
            name="recoveryEmail"
            type="email"
            className="mono security__input--wide"
            autoComplete="email"
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck="false"
            placeholder="you@example.com"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            required
          />
          <p className="security__help">
            {current.address
              ? `Use an address outside Cabalmail. Until you verify it, ${current.address} stops being used for recovery.`
              : 'Use an address outside Cabalmail: a mailbox you are locked out of cannot receive its own reset code.'}
          </p>
          <div className="security__confirm-actions">
            <button
              type="submit"
              className="security__btn"
              disabled={busy || !ADDRESS_SHAPE.test(draft.trim())}
            >
              Save and send code
            </button>
            <button
              type="button"
              className="security__btn security__btn--quiet"
              onClick={cancel}
              disabled={busy}
            >
              Cancel
            </button>
          </div>
        </form>
      )}

      {status === 'verifying' && (
        <form className="security__confirm" onSubmit={verify}>
          <p className="security__status">
            Enter the code sent to <strong className="security__address">{current.address}</strong>.
          </p>
          <label className="security__label" htmlFor="recoveryCode">
            Verification code
          </label>
          <input
            id="recoveryCode"
            name="recoveryCode"
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
              disabled={busy || code.trim().length < 6}
            >
              Verify
            </button>
            <button
              type="button"
              className="security__btn security__btn--quiet"
              onClick={sendCode}
              disabled={busy}
            >
              Send a new code
            </button>
            <button
              type="button"
              className="security__btn security__btn--quiet"
              onClick={cancel}
              disabled={busy}
            >
              Cancel
            </button>
          </div>
        </form>
      )}
    </section>
  );
}

export default RecoveryEmail;
