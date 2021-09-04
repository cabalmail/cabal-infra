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
  create_before_destroy = true
  user_data             = <<EOD
#!/bin/bash -xev
sudo yum install -y git
cd /tmp
sudo yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
sudo systemctl enable amazon-ssm-agent
sudo systemctl start amazon-ssm-agent

# Do some chef pre-work
/bin/mkdir -p /etc/chef
/bin/mkdir -p /var/lib/chef
/bin/mkdir -p /var/log/chef

cd /etc/chef/

# Install chef
curl -L https://omnitruck.chef.io/install.sh | bash || error_exit 'could not install chef'

# Create first-boot.json
cat > "/etc/chef/first-boot.json" << EOF
{
   "run_list" :[
   "role[base]"
   ]
}
EOF

NODE_NAME=node-$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 4 | head -n 1)

# Create client.rb
cat > '/etc/chef/client.rb' << EOF
log_location            STDOUT
node_name               "$${NODE_NAME}"
EOF

chef-client -j /etc/chef/first-boot.json
EOD
}

resource "aws_autoscaling_group" "cabal_imap_asg" {
  availability_zones    = var.private_subnets[*].availability_zone
  desired_capacity      = 1
  max_size              = 1
  min_size              = 1
  launch_configuration  = aws_launch_configuration.cabal_imap_cfg.id
  create_before_destroy = true
}