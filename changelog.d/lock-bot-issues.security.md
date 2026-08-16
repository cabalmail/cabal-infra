- **Comment lockdown on pipeline-created issues.** A new workflow locks every
  issue opened by the automation account at creation, so only repository
  collaborators can comment on it. Issues the agent pipelines file and later
  read back are no longer writable by arbitrary accounts on the public repo
  (prompt-injection hardening); human-opened issues are unaffected.
