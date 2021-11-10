property :domain, String, name_property: true, required: true
property :realm, String, default: 'default'
property :key_directory, String, default: '/etc/opendkim/keys'
property :private_key, String, required: true

action :create do
  directory "#{new_resource.key_directory}/#{new_resource.domain}" do
    action :create
    owner 'opendkim'
    group 'opendkim'
    recursive true
  end
  file "#{new_resource.key_directory}/#{new_resource.domain}/#{realm}" do
    user 'root'
    content new_resource.private_key
    not_if { ::File.exist?("#{new_resource.key_directory}/#{new_resource.domain}/#{realm}") }
  end
end

action :delete do
  directory "#{new_resource.key_directory}/#{new_resource.domain}" do
    action :delete
    recursive true
  end
end