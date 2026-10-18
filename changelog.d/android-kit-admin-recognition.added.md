- **Admin recognition in the Android kit.** `IdTokenClaims` reads the
  ID token's `cognito:groups` claim, and `AuthService.isAdmin()` (an
  extension function) reports whether the signed-in user is in the
  `admin` group. It matches the group as a whole name, as the Apple kit
  and the server do, and computes the answer from the stored tokens on
  every call, so it follows a refresh, a sign-out and an account switch.
  Nothing in the app reads it yet.
