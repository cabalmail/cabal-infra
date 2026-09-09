- **RSS reader data layer (phase 1 of the RSS plan).** Five DynamoDB
  tables for canonical feeds, items (with a stream for the notification
  fan-out), per-user subscriptions and folders, and per-user per-item
  state; the `cabal-rss-fetch-queue` SQS queue and its dead-letter queue;
  and an `rss-cache` S3 bucket for proxied images (seven-day expiry) and
  oversized item bodies. The tables join the AWS Backup selection where
  backups are enabled. No application traffic yet; the fetcher and API
  follow in later phases. See `docs/1.x/rss-implementation-plan.md`.
