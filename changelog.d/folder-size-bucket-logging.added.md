- `/list_messages` and `/list_envelopes` now emit a structured
  `[folder-size]` log line at the end of each request, tagging it with a
  coarse `folder_size_bucket` (`<1k` / `1k-10k` / `10k-100k` / `>100k`),
  the folder's message count, and the request `duration_ms`, so
  CloudWatch Logs Insights can correlate request latency with mailbox
  size without any Terraform or custom-metric plumbing (Layer 4.1 of the
  large-mailbox hardening plan). Only the folder name and bucket are
  logged, never message contents.
