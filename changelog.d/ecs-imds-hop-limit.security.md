- The ECS launch template's IMDS hop limit is reduced from 2 to 1, so a
  compromised mail-tier container can no longer reach the host instance role
  via IMDS. The tasks run in `awsvpc` mode and read credentials from the
  task-role endpoint rather than the host IMDS, so they are unaffected. Takes
  effect as instances cycle onto the new template.
