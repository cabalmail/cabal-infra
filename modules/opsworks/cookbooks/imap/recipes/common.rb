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

include_recipe 'acme'

#acme_certificate node['sendmail']['imap'] do
#  crt "#{node['imap']['cert_path']}/certs/#{node['sendmail']['cert']}.crt"
#  chain "#{node['imap']['cert_path']}/certs/#{node['sendmail']['cert']}.ca-bundle"
#  key "#{node['imap']['cert_path']}/private/#{node['sendmail']['cert']}.key"
#  wwwroot '/usr/share/nginx/html'
#  notifies :restart, 'service[dovecot]', :delayed
#end
#
#file "#{node['imap']['cert_path']}/certs/#{node['sendmail']['cert']}.chain.crt" do
#  content lazy {
#    IO.read("#{node['imap']['cert_path']}/certs/#{node['sendmail']['cert']}.crt") + "\n" +
#    IO.read("#{node['imap']['cert_path']}/certs/#{node['sendmail']['cert']}.ca-bundle")
#  }
#end
