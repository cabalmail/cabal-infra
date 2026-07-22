- **Terraform `fmt` drift in `modules/ecs/target_groups.tf`.** The
  `preserve_client_ip` assignment on the `aws_lb_target_group.tier`
  resource kept the extra spaces that had aligned it with the block
  above the intervening comment, which `terraform fmt` collapses to a
  single space now that the comment breaks the alignment group.
