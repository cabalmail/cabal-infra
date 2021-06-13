chef_gem 'ruby-shadow'
include_recipe 'yum-epel'
package 'squirrelmail'
chef_gem 'chef-vault'
require 'chef-vault'

data_bag('users').each do |u|
  item = ChefVault::Item.load('secret', u)
  password = item['password']
  user u do
    password password
  end
  execute 'saslpasswd' do
    command "echo '#{password}' | /usr/sbin/saslpasswd2 -c #{u}"
    not_if "/usr/sbin/sasldblistusers2 | grep '#{u}'"
  end
end

service 'saslauthd' do
  action [ :enable, :start ]
end
