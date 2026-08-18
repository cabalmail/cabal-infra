/**
 * The "Didn't get it? Resend code" prompt under the code form on the two
 * screens that share App.jsx's resend cooldown state (see its "Resend code"
 * comment): sign-up Verify and ResetPassword. Renders nothing when the
 * screen was given no onResend handler, which is how both callers hide it.
 *
 * VerifyEmail's resend deliberately does not use this: its copy differs
 * ("Need a code?" / "Send a new code"), it has no lockout state, and it is
 * shown unconditionally, so folding it in here would change what the user
 * reads.
 */
function formatLockout(seconds) {
  if (seconds >= 60) {
    const mins = Math.ceil(seconds / 60);
    return `${mins} minute${mins === 1 ? '' : 's'}`;
  }
  return `${seconds} second${seconds === 1 ? '' : 's'}`;
}

export default function ResendPrompt({
  onResend,
  inFlight = false,
  locked = false,
  lockoutRemaining = 0,
}) {
  if (!onResend) {
    return null;
  }
  let body;
  if (locked) {
    body = (
      <span className="auth__resend-locked">
        Too many resend attempts. Try again in about {formatLockout(lockoutRemaining)}.
      </span>
    );
  } else if (inFlight) {
    body = (
      <button type="button" disabled>
        Sending...
      </button>
    );
  } else {
    body = (
      <>
        Didn&rsquo;t get it?{' '}
        <button type="button" onClick={onResend}>
          Resend code
        </button>
      </>
    );
  }
  return (
    <p className="auth__alt auth__resend" aria-live="polite">
      {body}
    </p>
  );
}
