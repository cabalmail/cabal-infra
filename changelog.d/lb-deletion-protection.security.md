- Enabled deletion protection (`enable_deletion_protection = true`) on both
  public load balancers - the production mail NLB and the monitoring ALB - so
  an accidental console or `terraform destroy` deletion can no longer take the
  mail path offline. The `destroy_terraform.yml` teardown strips the attribute
  in its throwaway working copy (the same way it already strips
  `lifecycle.prevent_destroy`), so a deliberate non-prod teardown still
  proceeds. Clears the `CKV_AWS_150` scanner findings from the baseline.
