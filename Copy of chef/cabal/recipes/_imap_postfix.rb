package 'postfix'

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

template '/etc/postfix/local-host-names' do
  source 'relay-domains.erb'
  variables('domains' => domains)
  notifies :restart, 'service[postfix]', :delayed
end

execute 'newaliases' do
  command '/usr/bin/newaliases'
  action :nothing
end

template '/etc/aliases' do
  helpers(DomainHelper)
  source 'aliases.erb'
  variables('domains' => domains)
  notifies :run, 'execute[newaliases]', :immediately
end

template '/etc/postfix/relay_recipients' do
  source 'virtusertable.erb'
  variables('domains' => domains)
  notifies :restart, 'service[postfix]', :delayed
end

service 'postfix' do
  action [ :start, :enable ]
end