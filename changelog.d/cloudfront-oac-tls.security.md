- Both CloudFront distributions (admin app and front door) now use
  origin access control (OAC) instead of the legacy origin access
  identity, and the viewer TLS floor rises from `TLSv1.2_2021` to
  `TLSv1.2_2025`. The bucket policies temporarily carry both the OAI
  and OAC grants so the cutover is zero-downtime; the OAI resources
  and grants are removed in a follow-on apply once verified.
