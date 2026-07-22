- **Cognito user pool honors the SMS feature flag.** With no
  `ten_dlc_campaign_registration_id` set, the pool is provisioned
  without `auto_verified_attributes = ["phone_number"]`, the
  `sms_configuration` block, or the `verified_phone_number` recovery
  mechanism; the pre-signup Lambda auto-confirms new accounts, the
  signup form drops the phone-number field and SMS consent checkbox,
  and account recovery falls to `admin_only`. Previously the pool
  required SMS unconditionally, so a fresh deploy with no approved
  10DLC campaign left signup impossible (Cognito fell through to the
  sandboxed shared SNS pool).
