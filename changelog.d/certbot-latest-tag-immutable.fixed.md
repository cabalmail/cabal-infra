- The `lambda-certbot` job in `app.yml` no longer pushes a `latest` tag
  alongside the `sha-*` tag. The `cabal/certbot-renewal` ECR repository
  was made immutable in the Phase 2.5 IaC hardening, so the first
  content-changing build after that failed with "tag is immutable" and
  aborted before the deploy step, leaving the certbot-renewal Lambda on
  a stale image. Nothing consumed `latest`: the deploy script and the
  Terraform `resolved_image_uri` both use the `sha-*` tag.
