- The NAT instance root volume is now encrypted. With the stock AL2023 AMI
  this replaces the NAT instance on first apply - a brief outbound blip for the
  private subnets (and outbound SMTP delivery) while the new instance comes up.
