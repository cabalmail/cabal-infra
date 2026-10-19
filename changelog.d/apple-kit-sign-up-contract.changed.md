- **Apple kit sign-up follows the auth contract.** `signUp` now sends
  `preferred_username` and the invitation code (as Cognito validation
  data, empty when there is none). It returns whether Cognito sent a
  confirmation code, and to which masked email or phone, or confirmed
  the account itself. A refused invitation code throws its own error,
  `CabalmailError.invalidInvitationCode`, and a refused username keeps
  the trigger's sentence. `resendConfirmationCode` reports where the new
  code went, and the configuration reads `invitation_required` and
  `sms_enabled`, so the coming sign-up screens can hide the fields a
  deployment doesn't use. Nothing calls sign-up yet.
