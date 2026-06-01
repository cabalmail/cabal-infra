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
  description = "Use EC2 NAT instances instead of NAT Gateway."
  default     = false
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

variable "use_custom_nat_ami" {
  type        = bool
  description = "When true, NAT instances launch from the Image Builder-baked AL2023 AMI (nftables pre-installed) instead of the stock Amazon Linux 2 AMI. Leave false until the pipeline has produced at least one AMI (data.aws_ami.custom_nat hard-errors on an empty result)."
  default     = false
}