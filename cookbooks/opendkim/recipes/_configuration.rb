# Cookbook Name:: opendkim
# Recipe:: _configuration
# Author:: Xabier de Zuazo (<xabier@zuazo.org>)
# Copyright:: Copyright (c) 2015 Onddo Labs, SL.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

template node['opendkim']['conf_file'] do
  source 'opendkim.conf.erb'
  cookbook 'opendkim'
  mode '00644'
  variables conf: node['opendkim']['conf']
  notifies :restart, "service[#{node['opendkim']['service']['name']}]"
end
