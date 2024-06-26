/**
* Creates security group and autoscaling group for a tier (IMAP, SMTP submission, or SMTP relay depending on how called). Installs userdata that kicks off Chef Zero for OS-level configuration.
*/

resource "aws_launch_template" "asg" {
  name_prefix            = "${var.type}-"
  image_id               = data.aws_ami.amazon_linux_2.id
  instance_type          = var.scale.size
  vpc_security_group_ids = [aws_security_group.sg.id]
  update_default_version = true
  block_device_mappings {
    device_name = tolist(data.aws_ami.amazon_linux_2.block_device_mappings)[0].device_name
    ebs {
      volume_size = 8
      volume_type = "gp3"
      iops        = 3000
      throughput  = 125
    }
  }
  user_data             = base64encode(templatefile("${path.module}/templates/userdata", {
    control_domain  = var.control_domain,
    artifact_bucket = var.bucket,
    efs_dns         = var.efs_dns,
    region          = var.region,
    client_id       = var.client_id,
    pool_id         = var.user_pool_id,
    chef_license    = var.chef_license,
    master_password = var.master_password,
    type            = var.type,
    private_zone_id = var.private_zone_id,
    cidr            = var.cidr_block
  }))
  iam_instance_profile {
    name = aws_iam_instance_profile.asg.name
  }
  lifecycle {
    create_before_destroy = true
  }
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  } 
}

resource "aws_autoscaling_group" "asg" {
  vpc_zone_identifier  = var.private_subnets[*].id
  desired_capacity     = var.scale.des
  max_size             = var.scale.max
  min_size             = var.scale.min
  target_group_arns    = var.target_groups
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["tag"]
  }
  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 1
      on_demand_percentage_above_base_capacity = 100
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.asg.id
        version            = "$Latest"
      }
    }
  }
  lifecycle {
    create_before_destroy = true
  }
  tag {
    key                 = "Name"
    value               = "asg-${var.type}-${data.aws_ami.amazon_linux_2.id}"
    propagate_at_launch = true
  }
  tag {
    key                 = "type"
    value               = var.type
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