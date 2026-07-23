- **Nightly code-scanning alert monitor.** A scheduled workflow
  (`code-scanning-alerts.yml`) draws down open high and critical
  Security-tab code scanning alerts in bounded batches (five per night
  by default, overridable via `workflow_dispatch`): source findings
  from CodeQL get code fixes, Trivy image CVEs get a base-image digest
  bump to force a rebuild, and each batch ships as a single PR. An
  in-flight guard skips runs while a previous batch is open or freshly
  merged, so the backlog drains without duplicate PRs.
