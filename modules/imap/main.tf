data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]
  name_regex  = "^amzn2-"
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_iam_policy" "ssm_policy" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_default_tags" "current" {}

resource "aws_iam_role" "cabal_imap_role" {
  name = "cabal-imap-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "cabal_imap_role_attachment" {
  role       = aws_iam_role.cabal_imap_role.name
  policy_arn = data.aws_iam_policy.ssm_policy.arn
}

resource "aws_iam_instance_profile" "cabal_imap_instance_profile" {
  name = "cabal-imap-profile"
  role = aws_iam_role.cabal_imap_role.name
}

# TODO
# Place in correct subnets
# Squelch public IP
# Register with LB
# Create EC2 autoscale-groups with userdata:
# - mount efs
# - git clone https://... cookbook
# - install chef in local mode
# - run chef

resource "aws_launch_configuration" "cabal_imap_cfg" {
  name_prefix           = "imap-"
  image_id              = data.aws_ami.amazon_linux_2.id
  instance_type         = "t2.micro"
  iam_instance_profile  = aws_iam_instance_profile.cabal_imap_instance_profile.name
  lifecycle {
    create_before_destroy = true
  }
  user_data             = <<EOD
#!/bin/bash -xev
sudo yum install -y git
cd /tmp
sudo yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
sudo systemctl enable amazon-ssm-agent
sudo systemctl start amazon-ssm-agent

# Do some chef pre-work
/bin/mkdir -p /etc/chef
/bin/mkdir -p /var/lib/chef/cookbooks
/bin/mkdir -p /var/log/chef
cd /etc/chef/
curl -L https://omnitruck.chef.io/install.sh | bash
cat > '/etc/chef/solo.rb' << EOF
chef_license            'accept'
log_location            STDOUT
node_name               'imap'
cookbook_path [ '/var/lib/chef/cookbooks' ]
EOF

chef-solo -c /etc/chef/solo.rb
EOD
}

resource "aws_autoscaling_group" "cabal_imap_asg" {
  vpc_zone_identifier   = var.private_subnets[*].id
  desired_capacity      = 1
  max_size              = 1
  min_size              = 1
  launch_configuration  = aws_launch_configuration.cabal_imap_cfg.id
  lifecycle {
    create_before_destroy = true
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