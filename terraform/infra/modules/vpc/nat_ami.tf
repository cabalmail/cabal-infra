# =============================================================================
# Custom AL2023 NAT AMI (EC2 Image Builder)
#
# AL2023's base AMI ships no firewall tool (neither nftables nor iptables), so
# a boot-time install is fragile - it broke all private-subnet egress in 0.10.1.
# Instead, bake nftables + the masquerade ruleset + ip_forward + an enabled
# nftables.service into a custom AMI here, and launch the NAT instances from it
# (see var.use_custom_nat_ami and nat.tf).
#
# The pipeline rebuilds only when the AL2023 base image actually has updates
# (EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE), so it tracks AL2023
# security patches without churning no-op images. A new build does NOT roll the
# NAT instances on its own: nat.tf reads the latest AMI via data.aws_ami.custom_nat,
# so a rebuild surfaces as a replacement in the next plan and is adopted only on
# a deliberate, plan-reviewed apply.
#
# The build and test instances run in a private subnet and reach the internet
# through the existing NAT instances. A build therefore needs a healthy NAT; if
# egress is down the build simply fails and the last-good AMI stays in place (a
# safe no-op). This is also why the NAT is never launched from a not-yet-built
# image: bootstrap by leaving use_custom_nat_ami = false until the first AMI
# exists (see the toggle in variables.tf and the swap in nat.tf).
#
# Arch note: parent_image and instance_types are x86_64, matching the NAT's
# var.nat_instance_type default (t3.micro). Keep both on the same architecture.
# =============================================================================

resource "aws_iam_role" "imagebuilder" {
  count = var.use_nat_instance ? 1 : 0
  name  = "cabal-nat-imagebuilder-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "imagebuilder_core" {
  count      = var.use_nat_instance ? 1 : 0
  role       = aws_iam_role.imagebuilder[0].name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

resource "aws_iam_role_policy_attachment" "imagebuilder_ssm" {
  count      = var.use_nat_instance ? 1 : 0
  role       = aws_iam_role.imagebuilder[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "imagebuilder" {
  count = var.use_nat_instance ? 1 : 0
  name  = "cabal-nat-imagebuilder-profile"
  role  = aws_iam_role.imagebuilder[0].name
}

resource "aws_security_group" "imagebuilder" {
  count       = var.use_nat_instance ? 1 : 0
  name        = "cabal-nat-imagebuilder-sg"
  description = "Egress-only SG for the NAT AMI Image Builder build/test instances"
  vpc_id      = aws_vpc.network.id
  tags = {
    Name = "cabal-nat-imagebuilder-sg"
  }
}

resource "aws_security_group_rule" "imagebuilder_egress" {
  count             = var.use_nat_instance ? 1 : 0
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.imagebuilder[0].id
}

resource "aws_imagebuilder_component" "nat_nftables" {
  count       = var.use_nat_instance ? 1 : 0
  name        = "cabal-nat-nftables"
  platform    = "Linux"
  version     = "1.0.0"
  description = "Install + enable nftables masquerade for Cabalmail NAT instances"
  # Bump the version above whenever the component data changes; Image Builder
  # component versions are immutable.
  data = file("${path.module}/nat-nftables-component.yaml")
}

resource "aws_imagebuilder_image_recipe" "nat" {
  count   = var.use_nat_instance ? 1 : 0
  name    = "cabal-nat-al2023"
  version = "1.0.0"
  # "x.x.x" resolves to the latest AL2023 x86_64 managed image. Using the
  # managed-image ARN (not a static AMI id) is what lets the pipeline's
  # DEPENDENCY_UPDATES_AVAILABLE condition detect new AL2023 releases. The
  # managed image is named "amazon-linux-2023-x86" (the x86_64 base); there is
  # no "-x86-64" variant - that name 404s at CreateImageRecipe.
  parent_image = "arn:aws:imagebuilder:${var.region}:aws:image/amazon-linux-2023-x86/x.x.x"

  component {
    component_arn = aws_imagebuilder_component.nat_nftables[0].arn
  }

  block_device_mapping {
    device_name = "/dev/xvda"
    ebs {
      encrypted   = true
      volume_type = "gp3"
    }
  }
}

resource "aws_imagebuilder_infrastructure_configuration" "nat" {
  count                         = var.use_nat_instance ? 1 : 0
  name                          = "cabal-nat-al2023"
  instance_profile_name         = aws_iam_instance_profile.imagebuilder[0].name
  instance_types                = [var.nat_instance_type]
  subnet_id                     = aws_subnet.private[0].id
  security_group_ids            = [aws_security_group.imagebuilder[0].id]
  terminate_instance_on_failure = true

  instance_metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
}

resource "aws_imagebuilder_distribution_configuration" "nat" {
  count = var.use_nat_instance ? 1 : 0
  name  = "cabal-nat-al2023"

  distribution {
    region = var.region
    ami_distribution_configuration {
      # The buildDate suffix keeps each AMI name unique; data.aws_ami.custom_nat
      # filters on the "cabal-nat-al2023-*" prefix and most_recent = true.
      name = "cabal-nat-al2023-{{ imagebuilder:buildDate }}"
      ami_tags = {
        Name = "cabal-nat-al2023"
        Role = "cabal-nat"
      }
    }
  }
}

resource "aws_imagebuilder_image_pipeline" "nat" {
  count                            = var.use_nat_instance ? 1 : 0
  name                             = "cabal-nat-al2023"
  image_recipe_arn                 = aws_imagebuilder_image_recipe.nat[0].arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.nat[0].arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.nat[0].arn

  schedule {
    # Check daily; build only when the AL2023 base image has an update.
    schedule_expression                = "cron(0 9 * * ? *)"
    pipeline_execution_start_condition = "EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE"
  }

  image_tests_configuration {
    image_tests_enabled = true
    timeout_minutes     = 60
  }
}

# Latest baked AMI, consumed by aws_instance.nat when use_custom_nat_ami = true.
# Gated on the toggle so the stack does not hard-fail before the first build
# exists: a data.aws_ami with no match is an error, not an empty result.
data "aws_ami" "custom_nat" {
  count       = var.use_custom_nat_ami ? 1 : 0
  owners      = ["self"]
  most_recent = true
  filter {
    name   = "name"
    values = ["cabal-nat-al2023-*"]
  }
}
