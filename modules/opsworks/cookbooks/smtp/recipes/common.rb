package 'sendmail'
package 'sendmail-cf'
include_recipe 'route53'
chef_gem 'chef-vault'
require 'chef-vault'

access_key = node['sendmail']['aws_access_key_id']
secret_key = node['sendmail']['aws_secret_access_key']
quot = '"'
mx = []
search(:node, "(role:smtp-in) AND chef_environment:#{node.chef_environment}",
       filter_result: { 'fqdn' => %w(sendmail mxname),
                        'priority' => %w(sendmail mxpriority),
                          }
      ).each do |mxnode|
  mx << "#{mxnode['priority']} #{mxnode['fqdn']}"
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

domains.keys.sort.each do |tld|
  tldobj = domains[tld]
  spf = (defined? tldobj['spf']) ? tldobj['spf'] : nil
  spf ||= node['sendmail']['spf']
  route53_record "Create SPF for #{tld}" do
    name tld
    retries 2
    retry_delay 10
    value "#{quot}#{spf}#{quot}"
    type 'TXT'
    zone_id tldobj['zone-id']
    aws_access_key_id access_key
    aws_secret_access_key secret_key
    overwrite true
    action :create
    not_if "nslookup -type=txt #{tld}"
    not_if { tldobj['action'] == 'delete' }
  end
  route53_record "Create MX for #{tld}" do
    name tld
    retries 2
    retry_delay 10
    value mx
    type 'MX'
    zone_id tldobj['zone-id']
    aws_access_key_id access_key
    aws_secret_access_key secret_key
    overwrite true
    action :create
    not_if "nslookup -type=mx #{tld}"
    not_if { tldobj['action'] == 'delete' }
  end
  tldobj['subdomains'].keys.sort.each do |subd|
    subdobj = tldobj['subdomains'][subd]
    spf = (defined? subdobj['spf']) ? subdobj['spf'] : nil
    spf ||= (defined? tldobj['spf']) ? tldobj['spf'] : nil
    spf ||= node['sendmail']['spf']
    route53_record "Create SPF for #{subd}.#{tld}" do
      name "#{subd}.#{tld}"
      retries 2
      retry_delay 10
      value "#{quot}#{spf}#{quot}"
      type 'TXT'
      zone_id tldobj['zone-id']
      aws_access_key_id access_key
      aws_secret_access_key secret_key
      overwrite true
      action :create
      not_if "nslookup -type=txt #{subd}.#{tld}"
      not_if { subdobj['action'] == 'delete' }
    end
    route53_record "Create MX for #{subd}.#{tld}" do
      name "#{subd}.#{tld}"
      retries 2
      retry_delay 10
      value mx
      type 'MX'
      zone_id tldobj['zone-id']
      aws_access_key_id access_key
      aws_secret_access_key secret_key
      overwrite true
      action :create
      not_if "nslookup -type=mx #{subd}.#{tld}"
      not_if { subdobj['action'] == 'delete' }
    end
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
            imap: node['sendmail']['imap'])
  notifies :restart, 'service[sendmail]', :delayed
end

