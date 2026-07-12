- **CloudWatch log retention raised to one year.** Every log group
  (API Gateway, Lambda, the mail tiers, Cognito triggers, certbot, and the
  dormant monitoring stack) now sets `retention_in_days = 365` instead of the
  previous 14 or 30 days, clearing the `CKV_AWS_338` scanner findings. Storage
  cost on this low-volume system is negligible and a year of logs is a real
  operational win.
