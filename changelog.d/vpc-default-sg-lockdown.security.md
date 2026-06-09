- The VPC default security group is now locked down to deny-all. AWS ships
  it with an allow-all-intra-group rule; an `aws_default_security_group` with
  no rules strips them, so a resource accidentally left on the default group
  is isolated rather than openly reachable.
