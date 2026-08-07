/**
 * The one-time-code field every code-entry screen shows: sign-up Verify,
 * MfaChallenge, MfaSetup, ResetPassword and VerifyEmail. Only the label
 * and whether the field takes focus on mount differ between them; the id,
 * name and autofill hints are deliberately the same everywhere so password
 * managers recognise the field regardless of which screen it appears on.
 */
export default function VerificationCodeField({
  label,
  value,
  onChange,
  autoFocus = false,
}) {
  return (
    <div className="auth__field">
      <div className="auth__field-header">
        <label className="auth__field-label" htmlFor="verificationCode">{label}</label>
      </div>
      <input
        id="verificationCode"
        name="verificationCode"
        type="text"
        className="mono"
        autoComplete="one-time-code"
        inputMode="numeric"
        placeholder="123456"
        onChange={onChange}
        value={value || ''}
        required
        autoFocus={autoFocus}
      />
    </div>
  );
}
