import { useState, useMemo } from 'react';
import AuthShell from '../Login/AuthShell';
import { useAuth } from '../contexts/AuthContext';

/**
 * Strength meter per §2: four segments, each lights as a zxcvbn-style
 * check passes. Returns the count of passed checks (0–4).
 */
function strengthScore(pw) {
  if (!pw) return 0;
  let score = 0;
  if (pw.length >= 8) score += 1;
  if (/\d/.test(pw)) score += 1;
  if (/[^A-Za-z0-9]/.test(pw)) score += 1;
  if (/[a-z]/.test(pw) && /[A-Z]/.test(pw)) score += 1;
  return score;
}

/**
 * Signup screen per §2: wider card, username + phone + password + confirm,
 * strength meter, terms paragraph, Create account button disabled until all
 * fields validate, and "Sign in" links in the header and below the card.
 */
function SignUp({
  onSubmit,
  onUsernameChange,
  onPhoneChange,
  onPasswordChange,
  username,
  phone,
  password,
  onSignIn,
}) {
  // Legal pages live on the front door site at www.<control_domain>.
  // control_domain is loaded asynchronously from /config.js by App.jsx;
  // if the signup screen renders before it resolves (rare in practice),
  // fall back to "#" so we don't navigate to https://www.null/...
  const { control_domain } = useAuth();
  const frontDoorOrigin = control_domain ? `https://www.${control_domain}` : null;
  const termsHref = frontDoorOrigin ? `${frontDoorOrigin}/terms.html` : '#';
  const privacyHref = frontDoorOrigin ? `${frontDoorOrigin}/privacy.html` : '#';
  const [showPassword, setShowPassword] = useState(false);
  const [confirm, setConfirm] = useState('');
  const score = useMemo(() => strengthScore(password), [password]);
  const usernameValid = /^[a-z0-9-]{3,32}$/.test(username || '') &&
    !/^-/.test(username || '') && !/-$/.test(username || '');
  const phoneValid = /^\+?[0-9\s-]{7,}$/.test(phone || '');
  const passwordValid = (password || '').length >= 12;
  const confirmValid = confirm.length > 0 && confirm === password;
  const valid = usernameValid && phoneValid && passwordValid && confirmValid;

  const handleSubmit = (e) => {
    if (!valid) { e.preventDefault(); return; }
    onSubmit(e);
  };

  const headerRight = onSignIn ? (
    <span>Already have an account? <a href="#" onClick={onSignIn}>Sign in</a></span>
  ) : null;

  return (
    <AuthShell headerRight={headerRight} cardSize="wide">
      <p className="auth__eyebrow">Sign up</p>
      <h1 className="auth__title">Create your account.</h1>
      <p className="auth__subtitle">
        Pick a username and password. Your phone number is used only for recovery.
      </p>
      <form className="auth__form" onSubmit={handleSubmit} noValidate>
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
            placeholder="choose-a-username"
            onChange={onUsernameChange}
            value={username || ''}
            required
          />
          <p className="auth__field-help">
            3&ndash;32 characters. Lowercase letters, numbers, hyphens.
          </p>
        </div>
        <div className="auth__field">
          <div className="auth__field-header">
            <label className="auth__field-label" htmlFor="phone">Phone number</label>
            <span className="auth__field-hint">For recovery only</span>
          </div>
          <input
            id="phone"
            name="phone"
            type="tel"
            className="mono"
            autoComplete="tel"
            placeholder="+1 555 123 4567"
            onChange={onPhoneChange}
            value={phone || ''}
            required
          />
        </div>
        <div className="auth__field">
          <div className="auth__field-header">
            <label className="auth__field-label" htmlFor="password">Password</label>
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
          <div
            className="auth__strength"
            aria-label={`Password strength: ${score} of 4`}
            role="progressbar"
            aria-valuemin="0"
            aria-valuemax="4"
            aria-valuenow={score}
          >
            {[0, 1, 2, 3].map(i => (
              <span
                key={i}
                className={`auth__strength-seg${i < score ? ' on' : ''}`}
              />
            ))}
          </div>
          <p className="auth__field-help">
            At least 12 characters. A passphrase is better than a clever one.
          </p>
        </div>
        <div className="auth__field">
          <div className="auth__field-header">
            <label className="auth__field-label" htmlFor="passwordConfirm">Confirm password</label>
          </div>
          <input
            id="passwordConfirm"
            name="passwordConfirm"
            type={showPassword ? 'text' : 'password'}
            autoComplete="new-password"
            placeholder="••••••••"
            onChange={(e) => setConfirm(e.target.value)}
            value={confirm}
            required
          />
        </div>
        <p className="auth__terms">
          By creating an account you agree to the{' '}
          <a href={termsHref} target="_blank" rel="noopener noreferrer">Terms</a>
          {' '}and{' '}
          <a href={privacyHref} target="_blank" rel="noopener noreferrer">Privacy Policy</a>,
          and to receive transactional SMS (signup verification, password reset,
          sign-in codes) at the phone number you provide. Reply{' '}
          <code>STOP</code> to opt out at any time; message and data rates may apply.
        </p>
        <button
          type="submit"
          className="auth__btn-primary"
          disabled={!valid}
        >
          Create account
        </button>
      </form>
      {onSignIn ? (
        <p className="auth__alt">
          Already have an account? <a href="#" onClick={onSignIn}>Sign in</a>
        </p>
      ) : null}
    </AuthShell>
  );
}

export default SignUp;
