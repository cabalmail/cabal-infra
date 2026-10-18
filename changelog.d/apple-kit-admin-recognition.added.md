- **Admin recognition in the Apple kit.** `IdTokenClaims` reads the ID
  token's `cognito:groups` claim, and `AuthService.isAdmin()` reports
  whether the signed-in user is in the `admin` group. The group is
  matched as a whole name, the way the server does, in the array form
  Cognito issues and the string forms API Gateway renders. It is
  computed from the stored tokens on every call, so it follows a
  refresh, a sign-out and an account switch. Settings reads it to list
  Users for administrators.
