- Apple: **Sign-in recovers after a rejected token.** When the server answers
  401, the app now asks Cognito for a fresh token instead of replaying the one
  it just had refused, which it did whenever that token still looked unexpired
  by the device clock (a skewed clock, or a token revoked server-side). Several
  requests rejected at once now share a single refresh.
