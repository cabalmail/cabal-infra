- **Webmail sign-up refuses what the user pool refuses.** The phone field
  accepted `+1 555 123 4567` and the sign-up sent it as typed, which Cognito
  takes only in E.164, so the attempt came back as a bare "Registration
  failed." with nothing said about the phone number. Numbers are normalized
  to E.164 on the way out, the field is validated as E.164 and asks for a
  country code, and the password hint names the character classes the pool
  actually requires instead of recommending a passphrase it would refuse.
  Cognito's own refusals — the phone format, which part of the password
  policy failed, a username already taken, a rate limit — now each get their
  own sentence, matching what the native clients say.
