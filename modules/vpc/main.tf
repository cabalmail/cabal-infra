locals {
  bit_offsets = [ 0,1,2,2,3,3,3,3,4,4,4,4,4,4,4,4 ]
  bit_offset  = local.bit_offsets[length(var.az_list)*2]
}

resource "aws_vpc" "cabal_vpc" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  tags                 = {
    Name = "cabal-vpc"
  }
}