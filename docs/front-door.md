# Front Door Site

The Cabalmail front door site lives at `www.<control_domain>`. It is a small static site separate from the React admin app at `admin.<control_domain>`.

## Why it exists

Two reasons:

1. **A public surface that isn't the admin login.** AWS End User Messaging toll-free verification (TFV) and similar carrier registrations require a publicly-reachable URL describing the service. The admin app is a login screen; pointing carriers at it produces an awkward user experience and confuses reviewers.
2. **A home for the legal pages** (privacy policy, terms of service) that the signup screen and carrier registrations link to.

## Where the content lives

- `front-door/index.html` - home page.
- `front-door/privacy.html` - privacy policy. Required text: SMS use, message frequency, STOP/HELP keywords, data retention, third parties. The default copy already satisfies AWS TFV requirements.
- `front-door/terms.html` - terms of service. Three yellow-highlighted spans (entity name, contact email, jurisdiction) must be replaced by the operator before going live.
- `front-door/assets/`, `front-door/css/`, `front-door/js/` - static assets.

## How it deploys

Infrastructure (S3 bucket, CloudFront, Route 53, ACM wiring) is provisioned by the `front_door` Terraform module (`terraform/infra/modules/front_door/`). Terraform does not manage the site *content* - that ships through `.github/workflows/app.yml`, in a job mirroring the React deploy:

1. **Trigger.** A push to `main`, `stage`, or `development` that touches `front-door/**` (or `.github/scripts/render-front-door.py`) selects the `front_door` area in the workflow's path-filter step. `workflow_dispatch` with `areas: front_door` (or `all`) does the same on demand.
2. **Render.** `.github/scripts/render-front-door.py` walks `front-door/`, copies binary files verbatim, and rewrites every `{{NAME}}` token in text files (html, css, js, svg, txt, xml, json) with the value of the environment variable `NAME`. `NAME` must match `[A-Z][A-Z0-9_]*`. Unknown placeholders are left literal and emitted as `::warning::` annotations so a missing env var shows up in the run summary without failing the deploy. Output goes to `front-door-rendered/`.
3. **Upload.** `aws s3 sync front-door-rendered s3://www.<control_domain> --delete` pushes the rendered tree into the bucket.
4. **Invalidate.** The workflow looks up the CloudFront distribution ID from SSM (`/cabal/front-door/cf-distribution`, published by the Terraform module) and issues a `/*` invalidation.

### Adding a placeholder

The job currently substitutes two placeholders, set in the `render` step of the `front-door` job:

| Placeholder       | Value                  |
| ----------------- | ---------------------- |
| `{{SITE_VERSION}}` | `${{ github.ref_name }}` (branch name) |
| `{{BUILD_SHA}}`    | `${{ github.sha }}`    |

To add a new one:

1. Use `{{NAME}}` in the HTML/CSS/JS where you want the value to land.
2. In the `render` step's `env:` block in `.github/workflows/app.yml`, define a matching `NAME`. The value can come from `${{ github.* }}` context, a `${{ vars.* }}` repository or environment variable, a `${{ secrets.* }}` secret, or a computed expression.

Per-environment values (e.g. an env-specific contact address) belong in the GitHub Environment as a `var` and reach the step via `${{ vars.WHATEVER }}`. The job already binds to the per-branch environment, so `vars` and `secrets` are scoped correctly without extra plumbing.

## Updating the legal pages

The placeholder operator markers in `terms.html` are easy to find:

```
grep -n operator-replace front-door/terms.html
```

Replace each highlighted span with the operator's actual values, commit, push. The workflow path filter picks up the change, renders, syncs, and invalidates.

For an urgent legal correction without a code push, the same pipeline can be triggered manually:

```
gh workflow run app.yml -f areas=front_door
```
