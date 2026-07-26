- **Security-group rule descriptions, and an audit of the scanner decay
  backlog.** The three rules that lacked one now describe what they carry:
  the NAT instance's masquerade egress and VPC ingress, and the NAT AMI
  Image Builder's egress. Re-checked the rest of the decay list against
  what the scanners actually report and reclassified three entries that no
  longer described real gaps - EBS optimization on the NAT instance (t3 is
  Nitro-based, so it is already on and cannot be disabled), ALB access
  logging (only instance is the monitoring tier, disabled in every
  environment), and API Gateway create-before-destroy (does not mitigate
  the `execute-api` id change that makes a replacement disruptive).
  CloudFront access logging remains open and now records the bucket-ACL
  constraint that blocks the obvious fix. Clears `CKV_AWS_23`,
  `AWS-0124`, and `CKV_AWS_135` from the gate.
