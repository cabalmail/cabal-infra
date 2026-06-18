- CloudWatch alarms on the `list_messages` and `list_envelopes` Lambdas:
  one on p99 `Duration` creeping toward the 29s timeout and one on the
  `Errors` metric (which a timeout trips). They make a large-folder request
  outrunning the integration timeout an observable signal. Like the existing
  Cognito risk alarm they carry no `alarm_actions` (monitoring is disabled
  project-wide, so there is no notification channel yet) - they are visible
  via the console and `describe-alarms` and still enter ALARM state.
