#
# Cookbook:: dynamodb-query
# Recipe:: default
#
# Copyright:: 2019, Chris Carr, All Rights Reserved.

chef_gem 'aws-sdk-dynamodb' do
  action :nothing
end.run_action(:install)
