- **Branch-routed TestFlight groups for the Safari extension host.** Uploads
  now attach to the internal test group matching the branch they were built
  from — `stage` pushes to `stage`, `main` to `prod` — the same routing the
  mail apps use. The control domain is baked into an extension build, so a
  stage build and a prod build are different products and must not reach the
  same testers.
