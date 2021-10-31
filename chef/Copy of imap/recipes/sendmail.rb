package 'sendmail'
package 'sendmail-cf'

execute 'make_sendmail' do
  cwd ::File.dirname('/etc/mail')
  command 'make -C /etc/mail'
  notifies :restart, 'service[sendmail]', :delayed
  action :nothing
end

template '/etc/mail/sendmail.mc' do
  source 'sendmail.mc.erb'
  notifies :run, 'execute[make_sendmail]', :immediately
end

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

template '/etc/mail/local-host-names' do
  source 'relay-domains.erb'
  variables('domains' => domains)
  notifies :restart, 'service[sendmail]', :delayed
end

template '/etc/mail/relay-domains' do
  source 'relay-domains.erb'
  variables('domains' => domains)
  notifies :restart, 'service[sendmail]', :delayed
end

template '/etc/mail/access' do
  source 'access.erb'
  variables('domains' => domains)
  notifies :restart, 'service[sendmail]', :delayed
end

template '/etc/mail/virtusertable' do
  source 'virtusertable.erb'
  variables('domains' => domains)
  notifies :restart, 'service[sendmail]', :delayed
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

service 'sendmail' do
  action [ :start, :enable ]
end
