chef_gem 'ruby-shadow'
include_recipe 'yum-epel'
chef_gem 'chef-vault'
require 'chef-vault'

data_bag('users').each do |u|
  item = ChefVault::Item.load('secret', u)
  password = item['password']
  user u do
    password password
  end
  directory "/home/#{u}/Maildir" do
    owner u
    group u
    mode 0700
  end
  directory "/home/#{u}/.procmail" do
    owner u
    group u
    mode 0755
  end
  cookbook_file "/home/#{u}/.procmailrc" do
    source 'procmailrc'
    owner u
    group u
    mode 0744
  end
end
