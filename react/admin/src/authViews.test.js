import { describe, it, expect } from 'vitest';
import { viewWhenLoggedOut } from './authViews';

describe('viewWhenLoggedOut', () => {
  it('keeps the pre-login views', () => {
    ["Login", "SignUp", "Verify", "MfaChallenge", "ForgotPassword",
      "ResetPassword", "About"].forEach((view) => {
      expect(viewWhenLoggedOut(view, false)).toBe(view);
    });
  });

  it('bounces post-login views to Login', () => {
    ["Email", "Addresses", "Folders", "Security", "EnrollMfa"].forEach((view) => {
      expect(viewWhenLoggedOut(view, true)).toBe("Login");
    });
  });

  it('keeps MfaSetup while the password is still in memory', () => {
    expect(viewWhenLoggedOut("MfaSetup", true)).toBe("MfaSetup");
  });

  it('bounces MfaSetup once the password is gone (a reload)', () => {
    expect(viewWhenLoggedOut("MfaSetup", false)).toBe("Login");
  });
});
