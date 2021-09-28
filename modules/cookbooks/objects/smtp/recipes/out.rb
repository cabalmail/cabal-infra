package 'sendmail-milter'

mx = []
search(:node, "(role:smtp-in OR role:imap) AND chef_environment:#{node.chef_environment}",
       filter_result: { fqdn: %w(sendmail mxname),
                        priority: %w(sendmail mxpriority),
                      }
      ).each do |mxnode|
  mx << "#{mxnode['priority']} #{mxnode['fqdn']}"
end

template '/etc/mail/sendmail.mc' do
  source 'out-sendmail.mc.erb'
  notifies :run, 'bash[make_sendmail.cf]', :immediate
end

cookbook_file '/etc/mail/access' do
  source 'out-access'
end

bash 'make_sendmail.cf' do
  cwd ::File.dirname('/etc/mail')
  code 'make -C /etc/mail'
  action :nothing
  notifies :restart, 'service[sendmail]', :delayed
end

node.default['smtp']['cert_domain'] = "smtp-out.#{node['sendmail']['main']['mydomain']}"
include_recipe 'smtp::_ssl'

include_recipe 'smtp::_dkim'
include_recipe 'smtp::users'
