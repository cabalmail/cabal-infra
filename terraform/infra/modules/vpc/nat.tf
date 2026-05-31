resource "aws_internet_gateway" "ig" {
  vpc_id = aws_vpc.network.id
  tags = {
    Name = "cabal-igw"
  }
}

# EIP - always created, associated differently based on flag
resource "aws_eip" "nat_eip" {
  count      = length(var.az_list)
  domain     = "vpc"
  depends_on = [aws_internet_gateway.ig]
  tags = {
    Name = "cabal-nat-eip-${count.index}"
  }
}

resource "aws_route53_record" "smtp" {
  zone_id = var.zone_id
  name    = "smtp.${var.control_domain}"
  type    = "A"
  ttl     = 360
  records = aws_eip.nat_eip[*].public_ip
}

resource "aws_eip_domain_name" "smtp" {
  count         = length(var.az_list)
  allocation_id = aws_eip.nat_eip[count.index].allocation_id
  domain_name   = aws_route53_record.smtp.fqdn
}

# =============================================================================
# NAT Gateway (when use_nat_instance = false)
# =============================================================================

resource "aws_nat_gateway" "nat" {
  count         = var.use_nat_instance || var.quiesced ? 0 : length(var.az_list)
  allocation_id = aws_eip.nat_eip[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags = {
    Name = "cabal-nat-${count.index}"
  }
}

# =============================================================================
# NAT Instance (when use_nat_instance = true)
# =============================================================================

data "aws_ami" "al2023" {
  count       = var.use_nat_instance ? 1 : 0
  most_recent = true
  owners      = ["amazon"]
  filter {
    name = "name"
    # Standard AL2023 x86_64 AMI. The "-2023." infix excludes the "-minimal-"
    # variant, which does not ship the nftables stack the bootstrap relies on.
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "nat" {
  count       = var.use_nat_instance ? 1 : 0
  name        = "cabal-nat-instance-sg"
  description = "Security group for NAT instances"
  vpc_id      = aws_vpc.network.id
  tags = {
    Name = "cabal-nat-instance-sg"
  }
}

resource "aws_security_group_rule" "nat_egress" {
  count             = var.use_nat_instance ? 1 : 0
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.nat[0].id
}

resource "aws_security_group_rule" "nat_ingress_vpc" {
  count             = var.use_nat_instance ? 1 : 0
  type              = "ingress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = [var.cidr_block]
  security_group_id = aws_security_group.nat[0].id
}

resource "aws_iam_role" "nat" {
  count = var.use_nat_instance ? 1 : 0
  name  = "cabal-nat-instance-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  count      = var.use_nat_instance ? 1 : 0
  role       = aws_iam_role.nat[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  count = var.use_nat_instance ? 1 : 0
  name  = "cabal-nat-instance-profile"
  role  = aws_iam_role.nat[0].name
}

resource "aws_instance" "nat" {
  count                  = var.use_nat_instance && !var.quiesced ? length(var.az_list) : 0
  ami                    = data.aws_ami.al2023[0].id
  instance_type          = var.nat_instance_type
  subnet_id              = aws_subnet.public[count.index].id
  vpc_security_group_ids = [aws_security_group.nat[0].id]
  source_dest_check      = false
  iam_instance_profile   = aws_iam_instance_profile.nat[0].name

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    # Enable IPv4 forwarding (persists across reboots via sysctl.d).
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/nat.conf
    sysctl -p /etc/sysctl.d/nat.conf

    # AL2023 ships nftables (not iptables) in the base AMI, and this instance
    # has NO egress at first boot - the EIP is associated only after launch, the
    # public subnet does not auto-assign a public IP, and there is no other NAT
    # path or S3 VPC endpoint - so we cannot dnf-install anything here. Use the
    # preinstalled nftables stack instead. The masquerade rule is not pinned to a
    # named interface (the primary NIC is eth0 on some AMIs, ens5 on others), so
    # it works regardless of how the kernel names it. "flush ruleset" keeps a
    # re-run idempotent (no duplicate rules) on this single-purpose NAT box.
    #
    # Generated with printf, not a nested heredoc: a nested heredoc inside
    # Terraform's <<-EOF mis-strips indentation and yields an empty file (it
    # silently broke the old iptables bootstrap - see CHANGELOG 0.4.1).
    mkdir -p /etc/nftables
    printf '%s\n' \
      'flush ruleset' \
      '' \
      'table ip nat {' \
      '  chain postrouting {' \
      '    type nat hook postrouting priority 100; policy accept;' \
      '    masquerade' \
      '  }' \
      '}' \
      > /etc/nftables/cabal-nat.nft

    # The stock nftables.service runs "nft -f /etc/sysconfig/nftables.conf" on
    # every boot. Add our ruleset as an include once, then enable + start it so
    # the rules apply now and survive reboots.
    if ! grep -q 'cabal-nat.nft' /etc/sysconfig/nftables.conf 2>/dev/null; then
      printf '\ninclude "/etc/nftables/cabal-nat.nft"\n' >> /etc/sysconfig/nftables.conf
    fi
    systemctl enable --now nftables
  EOF

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = {
    Name = "cabal-nat-${count.index}"
  }
}

resource "aws_eip_association" "nat" {
  count         = var.use_nat_instance && !var.quiesced ? length(var.az_list) : 0
  instance_id   = aws_instance.nat[count.index].id
  allocation_id = aws_eip.nat_eip[count.index].id
}
