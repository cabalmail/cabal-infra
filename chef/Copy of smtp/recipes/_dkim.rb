include_recipe 'route53'

package 'opendkim'

access_key = node['sendmail']['aws_access_key_id']
secret_key = node['sendmail']['aws_secret_access_key']

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

for tld in domains.keys.sort do
  tldobj = domains[tld]
  for subd in tldobj['subdomains'].keys.sort do
    subdobj = tldobj['subdomains'][subd]
    smtp_dkimkey "#{subd}.#{tld} create" do
      domain "#{subd}.#{tld}"
      realm node.chef_environment
      dns_zone tldobj['zone-id']
      action :create
      notifies :restart, 'service[opendkim]', :delayed
      notifies :restart, 'service[sendmail]', :delayed
    end
  end
end

template '/etc/opendkim/KeyTable' do
  source 'KeyTable.erb'
  variables ({'domains' => domains})
  notifies :restart, 'service[opendkim]', :delayed
  notifies :restart, 'service[sendmail]', :delayed
end

template '/etc/opendkim/SigningTable' do
  source 'SigningTable.erb'
  variables ({'domains' => domains})
  notifies :restart, 'service[opendkim]', :delayed
  notifies :restart, 'service[sendmail]', :delayed
end

cookbook_file '/etc/opendkim/TrustedHosts' do
  source 'TrustedHosts'
  notifies :restart, 'service[opendkim]', :delayed
  notifies :restart, 'service[sendmail]', :delayed
end

cookbook_file '/etc/opendkim.conf' do
  source 'opendkim.conf'
  notifies :restart, 'service[opendkim]', :delayed
  notifies :restart, 'service[sendmail]', :delayed
end

service 'opendkim' do
  action [ :start, :enable ]
end

