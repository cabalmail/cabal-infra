- **CodeQL runs only the analyses a pull request can affect.** Code
  scanning moved from GitHub's default setup, which analysed every
  language on every pull request, to a checked-in `codeql.yml` that
  gates each language on its own path filter, the way `lint.yml` gates
  its linters. A Lambda-only PR no longer waits four to six minutes for
  the Linux client's Rust analysis. Pushes to `stage` and `main`, and a
  weekly scheduled run, still analyse everything so the per-branch alert
  lists stay current, and a `codeql-gate` job gives branch protection one
  stable check name to require.
