resource "aws_vpc" "cabal_vpc" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  tags                 = {
    Name = "cabal-vpc"
  }
}