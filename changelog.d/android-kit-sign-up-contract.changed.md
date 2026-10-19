- **Android kit sign-up follows the auth contract.** `signUp` now sends
  `preferred_username` and the invitation code (as Cognito validation
  data, empty when there is none), and returns a `SignUpResult`: a
  confirmation code sent to a masked email or phone, or the account
  already confirmed. A refused invitation code throws its own
  `CabalmailException.InvalidInvitationCode`, and a refused username
  keeps the trigger's sentence. `resendConfirmationCode` reports where
  the new code went, and `Config` reads `invitation_required` and
  `sms_enabled` as the webmail and the Apple kit do, so the coming
  sign-up screens can hide the fields a deployment doesn't use. Nothing
  calls sign-up yet.
