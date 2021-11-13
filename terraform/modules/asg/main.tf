resource "aws_launch_configuration" "cabal_cfg" {
  name_prefix           = "${var.type}-"
  image_id              = data.aws_ami.amazon_linux_2.id
  instance_type         = "t2.micro"
  security_groups       = [aws_security_group.cabal_sg.id]
  iam_instance_profile  = aws_iam_instance_profile.cabal_instance_profile.name
  lifecycle {
    create_before_destroy = true
  }
  user_data             = templatefile("${path.module}/${var.type}_userdata", {
    control_domain  = var.control_domain,
    artifact_bucket = var.artifact_bucket,
    efs_dns         = var.efs_dns,
    region          = var.region,
    client_id       = var.client_id,
    pool_id         = var.user_pool_id,
    chef_license    = var.chef_license,
    type            = var.type,
    private_zone_id = var.private_zone.zone_id
  })
}

# TODO
# - auth sufficient pam_exec.so expose_authtok /usr/bin/cognito.bash

resource "aws_autoscaling_group" "cabal_asg" {
  vpc_zone_identifier   = var.private_subnets[*].id
  desired_capacity      = var.scale.des
  max_size              = var.scale.max
  min_size              = var.scale.min
  launch_configuration  = aws_launch_configuration.cabal_cfg.id
  target_group_arns     = var.target_groups
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["tag"]
  }
  lifecycle {
    create_before_destroy = true
  }
  tag {
    key                 = "Name"
    value               = "asg-${var.type}-${data.aws_ami.amazon_linux_2.id}"
    propagate_at_launch = true
  }
  dynamic "tag" {
    for_each = data.aws_default_tags.current.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}