- **zizmor audit of the GitHub Actions workflows on every pull request.**
  `lint.yml` gains a `zizmor` job (zizmor 1.33.0, offline audits) that runs
  when a workflow, a composite action, `dependabot.yml` or the new
  `.github/zizmor.yml` changes and fails on any finding of medium severity
  or above, which covers the `dangerous-triggers` audit
  (`pull_request_target`, `workflow_run`, `issue_comment`; no workflow uses
  one, and a canary step proves the audit still fires under the checked-in
  config). The workflows were brought to zero findings at that floor
  first. Dispatch inputs and `github.ref_name` are no longer expanded into
  `run:` scripts in `destroy_terraform.yml`, `nat_ami_build.yml`,
  `quiesce.yml`, `release.yml` and `infra.yml`'s image-tag pin, nor are the
  computed matrix values in `app.yml`'s docker job and `apple.yml`'s Kit
  tests: each is read from the environment. `id-token: write` and
  `security-events: write` moved from the workflow level to the jobs that
  assume the AWS role or upload SARIF (`app.yml`, `infra.yml`,
  `nat_ami_build.yml`, `quiesce.yml`, `codeql.yml`), and
  `destroy_terraform.yml` gets an explicit read-only default. Every
  `actions/checkout` now states `persist-credentials`: `false` everywhere
  except the five whose job pushes or fetches with the token afterwards,
  which say `true` with the reason. None of the findings was reachable
  without write access to the repository. Two are ignored rather than
  fixed, each with its reason beside it: Dependabot's missing cooldown,
  and a low-confidence `github-env` report on the provisioning-profile
  action, whose inputs are a literal and a secret.
