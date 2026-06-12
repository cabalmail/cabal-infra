- DNSSEC signing is now available for the control-domain zone and every
  mail-apex zone, opt-in per environment via `TF_VAR_DNSSEC_ENABLED`
  (default off). Flipping the flag creates a us-east-1 ECC_NIST_P256
  KMS key per stack, a per-zone KSK, and enables signing; the DS record
  each registrar needs is surfaced as a Terraform output. The runbooks
  (enable, disable, KSK rotation, apex retirement) are in
  docs/dnssec.md - sign first, DS second. Mail zones also drop
  `force_destroy`, so a destroy plan can no longer silently delete a
  zone that still holds live address records.
