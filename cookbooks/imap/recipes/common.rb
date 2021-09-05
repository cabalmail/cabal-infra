yum_package 'nginx'

service 'nginx' do
  action [:enable,:start]
end

template '/etc/nginx/conf.d/ssl.conf' do
  source 'nginx-ssl.conf.erb'
  variables(
    key: "#{node['imap']['cert_path']}/private/#{node['sendmail']['cert']}.key",
    cert: "#{node['imap']['cert_path']}/certs/#{node['sendmail']['cert']}.chain.crt"
  )
  notifies :restart, 'service[nginx]', :delayed
end

# TODO import cert from secrets manager