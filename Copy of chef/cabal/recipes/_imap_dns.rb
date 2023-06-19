Route53Record.create(
  "imap.#{node['sendmail']['cert']}",
  node['ipaddress'],
  'A',
  3600,
  node['route53']['zone_id'],
  {
    region: node['ec2']['region']
  }
)