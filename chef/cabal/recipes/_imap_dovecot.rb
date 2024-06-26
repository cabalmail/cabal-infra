package 'dovecot'

cookbook_file '/etc/dovecot/conf.d/10-auth.conf' do
  source 'dovecot-10-auth.conf'
  notifies :restart, 'service[dovecot]', :delayed
end

cookbook_file '/etc/dovecot/conf.d/10-mail.conf' do
  source 'dovecot-10-mail.conf'
  notifies :restart, 'service[dovecot]', :delayed
end

cookbook_file '/etc/dovecot/conf.d/15-mailboxes.conf' do
  source 'dovecot-10-mail.conf'
  notifies :restart, 'service[dovecot]', :delayed
end

template '/etc/dovecot/conf.d/10-ssl.conf' do
  source 'dovecot-10-ssl.conf.erb'
  notifies :restart, 'service[dovecot]', :delayed
end

cookbook_file '/etc/dovecot/conf.d/20-imap.conf' do
  source 'dovecot-20-imap.conf'
  notifies :restart, 'service[dovecot]', :delayed
end

cookbook_file '/etc/dovecot/conf.d/auth-master.conf.ext' do
  source 'dovecot-auth-master.conf'
  notifies :restart, 'service[dovecot]', :delayed
end

cookbook_file '/etc/pam.d/dovecot' do
  source 'pam-dovecot'
  notifies :restart, 'service[dovecot]', :delayed
end

service 'dovecot' do
  action [:start, :enable]
end