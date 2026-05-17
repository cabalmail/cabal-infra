# Marketing Site

The Cabalmail marketing site lives at `www.<control_domain>`. It is a small static site separate from the React admin app at `admin.<control_domain>`.

## Why it exists

Two reasons:

1. **A public surface that isn't the admin login.** AWS End User Messaging toll-free verification (TFV), Twilio A2P 10DLC, and similar carrier registrations require a publicly-reachable URL describing the service. The admin app is a login screen; pointing carriers at it produces an awkward user experience and confuses reviewers.
2. **A home for the legal pages** (privacy policy, terms of service) that the signup screen and carrier registrations link to.

Design and copy beyond the placeholder home page are out of scope for the initial drop; the site currently exists as scaffolding the operator can grow into.

## Where the content lives

- `marketing-site/index.html` - placeholder home page.
- `marketing-site/privacy.html` - privacy policy. Required text: SMS use, message frequency, STOP/HELP keywords, data retention, third parties. The default copy already satisfies AWS TFV and Twilio A2P requirements.
- `marketing-site/terms.html` - terms of service. Three yellow-highlighted spans (entity name, contact email, jurisdiction) must be replaced by the operator before going live.

## How it deploys

The `marketing_site` Terraform module (`terraform/infra/modules/marketing_site/`) provisions:

- An S3 bucket named `www.<control_domain>`.
- A CloudFront Origin Access Identity restricting bucket access to the distribution.
- A CloudFront distribution with the bucket as origin, alias `www.<control_domain>`, and the wildcard cert from the `cert` module.
- Route 53 records (public + private zone) pointing `www.<control_domain>` at the distribution.
- `aws_s3_object` resources uploading every file under `marketing-site/` with appropriate content types.

Because Terraform owns the S3 objects, changes to `marketing-site/*.html` ship via `infra.yml` (terraform apply), not via a separate `s3 sync` step. This is fine for placeholder content that changes infrequently; when real marketing copy lands and updates become frequent, the simplest migration is to:

1. Drop the `aws_s3_object` resources from `terraform/infra/modules/marketing_site/main.tf`.
2. Add a job to `.github/workflows/app.yml` (path-filtered on `marketing-site/**`) that runs `aws s3 sync marketing-site/ s3://www.<control_domain>/ --delete` and invalidates the CloudFront distribution.

## Updating the legal pages

The placeholder operator markers are easy to find:

```
grep -n operator-replace marketing-site/terms.html
```

Replace each highlighted span with the operator's actual values. The privacy policy does not currently have operator-specific placeholders, but if your jurisdiction requires a specific entity disclosure, mirror the pattern from `terms.html`.

When you edit a page, `infra.yml` will detect the file change (via `aws_s3_object`'s `etag = filemd5(...)`) and re-upload it on the next apply. CloudFront cache TTL is 600 seconds by default; for an urgent legal correction, invalidate manually:

```
aws cloudfront create-invalidation \
  --distribution-id $(terraform output -raw marketing_site_cf_id) \
  --paths "/privacy.html" "/terms.html"
```
