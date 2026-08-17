import AuthShell from '../Login/AuthShell';
import ResendPrompt from '../Login/ResendPrompt';
import VerificationCodeField from '../Login/VerificationCodeField';

function Verify({
  onSubmit,
  onCodeChange,
  code,
  onBackToSignIn,
  onResend,
  resendInFlight = false,
  resendLocked = false,
  resendLockoutRemaining = 0,
  // Where Cognito sent the confirmation code. Comes from the signUp
  // result's codeDeliveryDetails: "phone" when SMS is wired, "email"
  // otherwise (issue #712 / identity plan Phase 1). destination is the
  // masked address/number Cognito reports, when available.
  medium = 'phone',
  destination = null,
}) {
  const headerRight = onBackToSignIn ? (
    <span><a href="#" onClick={onBackToSignIn}>Back to sign in</a></span>
  ) : null;
  return (
    <AuthShell headerRight={headerRight} cardSize="narrow">
      <p className="auth__eyebrow">Verify</p>
      <h1 className="auth__title">Enter your code.</h1>
      <p className="auth__subtitle">
        A verification code has been sent to{' '}
        {destination || `your ${medium}`}. Enter it below to complete
        registration.
      </p>
      <form className="auth__form" onSubmit={onSubmit} noValidate>
        <VerificationCodeField
          label="Verification code"
          value={code}
          onChange={onCodeChange}
        />
        <button type="submit" className="auth__btn-primary">Verify</button>
      </form>
      <ResendPrompt
        onResend={onResend}
        inFlight={resendInFlight}
        locked={resendLocked}
        lockoutRemaining={resendLockoutRemaining}
      />
    </AuthShell>
  );
}

export default Verify;
