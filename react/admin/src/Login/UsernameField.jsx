/**
 * The mono username field that opens each of the three screens asking for a
 * username: Login, ForgotPassword and SignUp. The id, name, autofill hint and
 * input shaping are deliberately the same on all three so password managers
 * recognise the field regardless of which screen it appears on — the same
 * reasoning PasswordField records for its own id/name/placeholder.
 *
 * Only the placeholder differs between the callers, so it is a prop defaulting
 * to the wording Login and ForgotPassword share; SignUp asks the user to pick
 * one rather than recall it. `children` render inside the field below the
 * input (SignUp's length/charset help line), mirroring PasswordField.
 */
export default function UsernameField({
  value,
  onChange,
  placeholder = 'your-username',
  children = null,
}) {
  return (
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
        placeholder={placeholder}
        onChange={onChange}
        value={value || ''}
        required
      />
      {children}
    </div>
  );
}
