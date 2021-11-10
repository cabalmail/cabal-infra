package 'opendkim'

domains = {}
DynamoDBQuery.scan('cabal-addresses', { region: node['ec2']['region'] }).each do |item|
  if ! domains.has_key? item['tld']
    domains[item['tld']] = {
      'private_key' => item['private_key'],
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
    cabal_dkimkey "#{subd}.#{tld} create" do
      domain "#{subd}.#{tld}"
      realm 'cabal'
      private_key tldobj['private_key']
      action :create
      notifies :restart, 'service[opendkim]', :delayed
      notifies :restart, 'service[sendmail]', :delayed
    end
  end
end

template '/etc/opendkim/KeyTable' do
  source 'dkim-keytable.erb'
  variables ({'domains' => domains})
  notifies :restart, 'service[opendkim]', :delayed
  notifies :restart, 'service[sendmail]', :delayed
end

template '/etc/opendkim/SigningTable' do
  source 'dkim-signingtable.erb'
  variables ({'domains' => domains})
  notifies :restart, 'service[opendkim]', :delayed
  notifies :restart, 'service[sendmail]', :delayed
end

file '/etc/opendkim/TrustedHosts' do
  content '0.0.0.0/0'
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