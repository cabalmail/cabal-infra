data "aws_ami" "amazon-linux-2" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm*"]
  }
}

# TODO
# Create EC2 autoscale-groups with userdata:
# - mount efs
# - git clone https://... cookbook
# - install chef in local mode
# - run chef

resource "aws_launch_configuration" "cabal_imap_cfg" {
  name_prefix   = "imap-"
  image_id      = data.aws_ami.amazon-linux-2.id
  instance_type = "t2.micro"
  user_data     = <<EOD
#!/bin/bash
sudo yum install -y git
cd /tmp
sudo yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
sudo systemctl enable amazon-ssm-agent
sudo systemctl start amazon-ssm-agent
EOD
}

resource "aws_autoscaling_group" "cabal_imap_asg" {
  availability_zones   = var.private_subnets[*].availability_zone
  desired_capacity     = 1
  max_size             = 1
  min_size             = 1
  launch_configuration = aws_launch_configuration.cabal_imap_cfg.id
}