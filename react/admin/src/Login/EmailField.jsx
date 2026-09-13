/**
 * The mono recovery-email field shared by the two screens that collect one:
 * SignUp, and VerifyEmail's "add" mode for accounts created before email
 * collection existed. The id, name, autofill hint and input shaping are the
 * same on both so the browser offers the same saved addresses on either
 * screen.
 *
 * SignUp adds a short hint beside the label, so `hint` renders only when
 * given. `children` render inside the field below the input (each caller's
 * own help line), mirroring UsernameField and PasswordField.
 */
export default function EmailField({
  value,
  onChange,
  hint = null,
  children = null,
}) {
  return (
    <div className="auth__field">
      <div className="auth__field-header">
        <label className="auth__field-label" htmlFor="email">Email address</label>
        {hint ? <span className="auth__field-hint">{hint}</span> : null}
      </div>
      <input
        id="email"
        name="email"
        type="email"
        className="mono"
        autoComplete="email"
        autoCapitalize="off"
        autoCorrect="off"
        spellCheck="false"
        placeholder="you@example.com"
        onChange={onChange}
        value={value || ''}
        required
      />
      {children}
    </div>
  );
}
