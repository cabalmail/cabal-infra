- Every CI upload to S3 now passes `--expected-bucket-owner`: the React
  and front-door `aws s3 sync` steps, the Lambda zip/sidecar uploads in
  `build-api-one.sh` and `build-counter.sh`, and the bootstrap stub
  uploads/head checks in `upload-stub-lambdas.sh`. A leaked deploy
  credential can no longer silently write to a same-named bucket in
  another account; the transfer fails closed instead.
