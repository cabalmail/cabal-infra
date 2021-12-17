template '/usr/bin/cognito.bash' do
  mode '0100'
  owner 'root'
  group 'root'
  source 'cognito.bash.erb'
  variables(
    :region => node['cognito']['region'],
    :client_id => node['cognito']['client_id']
  )
end

package 'fail2ban'

service 'fail2ban' do
  action [ :start, :enable ]
end

firewall-cmd --permanent --add-port=31337/tcp; firewall-cmd --reload
<?xml version="1.0" encoding="utf-8"?>
<zone>
  <short>Public</short>
  <description>For use in public areas. You do not trust the other computers on networks to not harm your computer. Only selected incoming connections are accepted.</description>
  <service name="ssh"/>
  <service name="dhcpv6-client"/>
  <port protocol="tcp" port="993"/>
  <port protocol="tcp" port="imap"/>
</zone>