/**
 * The password field with the Show/Hide adornment that Login, SignUp and
 * ResetPassword all render. Only the label and the autofill hint differ
 * between them; the id, name and placeholder are deliberately the same
 * everywhere so password managers recognise the field regardless of which
 * screen it appears on.
 *
 * Visibility is controlled by the caller rather than held here because SignUp
 * mirrors the same toggle onto its separate confirm-password input, which is
 * not adorned and so is not part of this component.
 *
 * `headerHint` renders beside the label (Login's "Forgot password?" link);
 * `children` render inside the field below the input (SignUp's strength meter
 * and help text).
 */
export default function PasswordField({
  label,
  autoComplete,
  value,
  onChange,
  visible,
  onToggleVisible,
  headerHint = null,
  children = null,
}) {
  return (
    <div className="auth__field">
      <div className="auth__field-header">
        <label className="auth__field-label" htmlFor="password">{label}</label>
        {headerHint}
      </div>
      <div className="auth__field-adorn">
        <input
          id="password"
          name="password"
          type={visible ? 'text' : 'password'}
          autoComplete={autoComplete}
          placeholder="••••••••"
          onChange={onChange}
          value={value || ''}
          required
        />
        <button
          type="button"
          className="auth__field-adorn-btn"
          onClick={onToggleVisible}
          aria-label={visible ? 'Hide password' : 'Show password'}
        >
          {visible ? 'Hide' : 'Show'}
        </button>
      </div>
      {children}
    </div>
  );
}
