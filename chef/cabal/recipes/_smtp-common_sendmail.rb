package 'postfix' do
  action :remove
end
package 'sendmail'
package 'sendmail-cf'

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

service 'sendmail' do
  action [ :start, :enable ]
end

template '/etc/mail/mailertable' do
  source 'mailertable.erb'
  variables(domains: domains,
            imap: "imap.#{node['sendmail']['cert']}")
  notifies :restart, 'service[sendmail]', :delayed
end