- **Cache bucket objects expire two days after they are written.** The
  lifecycle rule on `cache.<control_domain>` applies to the whole bucket:
  cached message bodies and attachment parts, staged outbound
  attachments, queued Sent copies, BIMI renders, and archived DMARC and
  CAA report files. The DMARC and CAA views keep every report's rows, with
  the raw file viewable for two days; `docs/caa.md` describes how to keep
  a readable copy of CAA reports.
