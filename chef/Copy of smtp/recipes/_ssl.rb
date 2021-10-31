yum_package 'nginx'
  
service 'nginx' do
  action [:enable,:start]
end

template '/etc/nginx/conf.d/ssl.conf' do
  source 'nginx-ssl.conf.erb'
  variables(
    key: "#{node['smtp']['cert_path']}/private/smtp-out.#{node['sendmail']['cert']}.key",
    cert: "#{node['smtp']['cert_path']}/certs/smtp-out.#{node['sendmail']['cert']}.crt"
  )
  notifies :restart, 'service[nginx]', :delayed
end

include_recipe 'acme'

acme_certificate node['smtp']['cert_domain'] do
  crt "#{node['smtp']['cert_path']}/certs/smtp-out.#{node['sendmail']['cert']}.crt"
  chain "#{node['smtp']['cert_path']}/certs/smtp-out.#{node['sendmail']['cert']}.ca-bundle"
  key "#{node['smtp']['cert_path']}/private/smtp-out.#{node['sendmail']['cert']}.key"
  wwwroot '/usr/share/nginx/html'
  notifies :restart, 'service[sendmail]', :delayed
end
