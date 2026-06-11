- The checkov half of the baseline drift check (`make drift` and the
  baseline-drift step in `infra.yml`) now actually detects stale
  `.checkov.baseline` entries. The parser read `resource`/`check_ids`
  directly off each `failed_checks` entry, but the baseline nests them
  under per-file `findings`, so the check always compared an empty set
  and passed trivially. Entries are keyed on (resource, check_id)
  exactly as checkov's own baseline matcher does. The trivy half was
  unaffected.
