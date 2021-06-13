domains = {}
DynamoDBQuery.scan('cabal-addresses', { region: node['ec2']['region'] }).each do |item|
  if ! domains.has_key? item['tld']
    domains[item['tld']] = {
      'zone-id' => item['zone-id'],
      'addresses' => {},
      'subdomains' => {}
    }
  end
  if item.has_key? 'subdomain'
    if ! domains[item['tld']]['subdomains'].has_key? item['subdomain']
      domains[item['tld']]['subdomains'][item['subdomain']] = {
        'addresses' => {},
        'action' => 'nothing'
      }
    end
    domains[item['tld']]['subdomains'][item['subdomain']]['addresses'][item['username']] = item['user'].split('/')
  else
    domains[item['tld']]['addresses'][item['username']] = item['user']
  end
end

template '/etc/mail/masq-domains' do
  source 'masq-domains.erb'
  variables('domains' => domains)
  notifies :restart, 'service[sendmail]', :delayed
end

template '/etc/mail/sendmail.mc' do
  source 'in-sendmail.mc.erb'
  notifies :run, 'bash[make_sendmail.cf]', :immediate
end

template '/etc/mail/access' do
  source 'access.erb'
  variables('domains' => domains)
  notifies :restart, 'service[sendmail]', :delayed
end

template '/etc/mail/relay-domains' do
  source 'relay-domains.erb'
  variables('domains' => domains)
  notifies :restart, 'service[sendmail]', :delayed
end

bash 'make_sendmail.cf' do
  cwd ::File.dirname('/etc/mail')
  code <<-EOH
    make -C /etc/mail
  EOH
  action :nothing
  notifies :restart, 'service[sendmail]', :delayed
end

node.default['smtp']['cert_domain'] = node['sendmail']['mxname']
include_recipe 'smtp::_ssl'
