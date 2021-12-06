/**
* Creates security group and autoscaling group for a tier (IMAP, SMTP submission, or SMTP relay depending on how called). Installs userdata that kicks off Chef Zero for OS-level configuration.
*/

resource "aws_launch_configuration" "asg" {
  name_prefix           = "${var.type}-"
  image_id              = data.aws_ami.amazon_linux_2.id
  instance_type         = "t2.micro"
  security_groups       = [aws_security_group.sg.id]
  iam_instance_profile  = aws_iam_instance_profile.asg.name
  lifecycle {
    create_before_destroy = true
  }
  user_data             = templatefile("${path.module}/templates/userdata", {
    control_domain  = var.control_domain,
    artifact_bucket = var.artifact_bucket,
    efs_dns         = var.efs_dns,
    region          = var.region,
    client_id       = var.client_id,
    pool_id         = var.user_pool_id,
    chef_license    = var.chef_license,
    type            = var.type,
    private_zone_id = var.private_zone_id,
    cidr            = var.cidr_block
  })
}

resource "aws_autoscaling_group" "asg" {
  vpc_zone_identifier  = var.private_subnets[*].id
  desired_capacity     = var.scale.des
  max_size             = var.scale.max
  min_size             = var.scale.min
  launch_configuration = aws_launch_configuration.asg.id
  target_group_arns    = var.target_groups
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