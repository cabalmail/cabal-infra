- A CloudWatch alarm (`cabal-cognito-high-risk-signin`) now watches Cognito
  threat protection's `AccountTakeoverRisk` metric and enters ALARM when a
  sign-in is scored high-risk (adaptive auth: impossible travel, anomalous
  device or IP). In audit mode the sign-in is not blocked, so the alarm flags
  the account for investigation. It has no notification action yet; delivery
  wiring is a follow-up.
