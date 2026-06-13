- Every CI S3 upload target is now ownership-verified before the upload.
  A `verify-bucket-owner.sh` preflight runs `aws s3api head-bucket
  --expected-bucket-owner` (the high-level `aws s3 cp` / `aws s3 sync`
  commands the deploy path uses do not accept that flag) ahead of the
  React and front-door syncs, the Lambda zip/sidecar/manifest uploads in
  `build-api-one.sh` and `build-counter.sh`, and the bootstrap stub
  uploads in `upload-stub-lambdas.sh`. A leaked deploy credential can no
  longer silently write to a same-named bucket in another account; the
  run fails closed instead.
