locals {
  bit_offsets = [0, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4]
  bit_offset  = local.bit_offsets[length(var.az_list) * 2]
}

variable "cidr_block" {
  type        = string
  description = "CIDR for the VPC."
}

variable "az_list" {
  type        = list(string)
  description = "List of availability zones to use."
}

variable "control_domain" {
  type        = string
  description = "Control domain."
}

variable "zone_id" {
  type        = string
  description = "Public zone for control domain."
}

variable "use_nat_instance" {
  type        = bool
  description = "Egress mode: true runs EC2 NAT instances from the custom AL2023 AMI (cheapest; requires the Image Builder pipeline to have produced at least one AMI - data.aws_ami.custom_nat hard-errors on an empty result, which is the guard against flipping to instances too early). False runs AWS-managed NAT Gateways, which need no AMI and are therefore also the bootstrap path for a brand-new instance-mode environment. Both modes are first-class and reuse the same EIPs."
  default     = true
}

variable "nat_instance_type" {
  type        = string
  description = "Instance type for NAT instances (when use_nat_instance = true)."
  default     = "t3.micro"
}

variable "quiesced" {
  type        = bool
  description = "When true, do not provision NAT instances. Private-subnet egress goes away while the environment is quiesced; ECS tasks needing egress are also at zero, so this is safe. NAT EIPs and the public Route 53 record for them are kept so SMTP relay IP allow-lists do not need to be re-issued on resume."
  default     = false
}

variable "region" {
  type        = string
  description = "AWS region. Used to build the EC2 Image Builder managed-image ARN for the custom NAT AMI."
}

variable "build_nat_ami" {
  type        = bool
  description = "Whether to provision the EC2 Image Builder pipeline that bakes the custom AL2023 NAT AMI (nat_ami.tf). Independent of use_nat_instance so a gateway-mode environment can still build the AMI ahead of a switch to instances; pure-gateway environments that will never run instances can set this false to skip the pipeline entirely."
  default     = true
}