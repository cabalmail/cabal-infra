- A new CI gate (`check-iam-resource-scope.py`, run in the Terraform scanner
  jobs and by `make scan`) fails the build when an IAM policy grants a
  wildcard resource - a literal `"*"` or the scanner-evading `local.wildcard`
  indirection - without a written justification. Every legitimate wildcard in
  the tree (ssmmessages session channels, route53 List*, cloudwatch metric
  reads, runtime-generated log-stream and S3 object-key segments) now carries
  an `# iam-wildcard-ok:` rationale comment.
