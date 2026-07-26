/**
 * Which views survive a logged-out session check.
 *
 * App's session check runs on every render, so any view App routes to
 * *before* a token exists has to be listed here or it is bounced back to
 * Login before it ever paints. About is reachable when logged out via the
 * auth-shell footer link; MfaChallenge and MfaSetup both sit mid-login,
 * after the password but before (or instead of) token issuance.
 */
export const LOGGED_OUT_VIEWS = [
  "Login", "SignUp", "Verify", "MfaChallenge", "MfaSetup", "ForgotPassword",
  "ResetPassword", "About"
];

/**
 * Resolve the view a logged-out app should show.
 *
 * @param {string} view - the view the app currently wants to render.
 * @param {boolean} hasPassword - whether the in-memory password is still
 *   available. Only MfaSetup needs it: that flow re-authenticates against
 *   the enrollment app client, and persistState deliberately strips the
 *   password, so a reload lands on the setup screen with nothing to
 *   re-authenticate with. Restart from Login instead.
 * @returns {string} the view to render.
 */
export function viewWhenLoggedOut(view, hasPassword) {
  if (!LOGGED_OUT_VIEWS.includes(view)) return "Login";
  if (view === "MfaSetup" && !hasPassword) return "Login";
  return view;
}
