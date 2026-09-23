- **S3-native Terraform state locking.** The generated backend now sets
  `use_lockfile = true`, so every plan, apply, quiesce, and destroy takes
  the state lock as a conditional write of `<key>.tflock` beside the
  state object. Previously nothing held a lock: the `-lock-timeout` on
  apply was inert and only the `infra.yml` concurrency group stood
  between overlapping runs, which could not see `quiesce.yml` or
  `destroy_terraform.yml`. Both stacks' Terraform floor rises to 1.10,
  the first release with `use_lockfile`.
