/**
* Creates a VPC, subnets, NAT Gateways, and private Route 53 zone for the control domain.
*/

resource "aws_vpc" "network" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  tags = {
    Name = "cabal-vpc"
  }
}

# Lock down the VPC default security group. Nothing references it, and an
# unmanaged default SG ships with an allow-all-intra-SG ingress rule.
# Declaring it with no ingress/egress blocks strips every rule (deny-all),
# so a resource accidentally left on the default SG is isolated (CKV2_AWS_12).
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.network.id
  tags = {
    Name = "cabal-vpc-default-locked"
  }
}