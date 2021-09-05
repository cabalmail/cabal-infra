property :domain, String, name_property: true, required: true
property :realm, String, default: 'default'
property :key_directory, String, default: '/etc/opendkim/keys'
property :access_key_id, String, required: true
property :secret_access_key, String, required: true
property :dns_zone, String, required: true

action :create do
  begin
    directory "#{new_resource.key_directory}/#{new_resource.domain}" do
      action :create
      owner 'opendkim'
      group 'opendkim'
      recursive true
    end
    bash 'gen_key' do
      user 'root'
      cwd "#{new_resource.key_directory}/#{new_resource.domain}"
      code <<-EOH
        /usr/sbin/opendkim-genkey -D ./ -d #{new_resource.domain} -s #{new_resource.realm}
        mv #{new_resource.realm}.private #{new_resource.realm}
        chown opendkim #{new_resource.realm}
      EOH
      not_if { ::File.exist?("#{new_resource.key_directory}/#{new_resource.domain}/services") }
    end
    route53_record "#{new_resource.realm}._domainkey.#{new_resource.domain}" do
      retries 2
      retry_delay 10
      value get_txt(::File.read("#{new_resource.key_directory}/#{new_resource.domain}/#{new_resource.realm}.txt"))
      type 'TXT'
      zone_id new_resource.dns_zone
      aws_access_key_id new_resource.access_key_id
      aws_secret_access_key new_resource.secret_access_key
      overwrite true
      action :create
      not_if "nslookup -type=txt #{new_resource.realm}._domainkey.#{new_resource.domain}"
    end
  rescue
    log "Failed to create dkim entry for #{new_resource.key_directory}/#{new_resource.domain} (#{new_resource.realm})"
  end
end

action :delete do
  route53_record "#{new_resource.realm}._domainkey.#{new_resource.domain}" do
    retries 2
    retry_delay 10
    type 'TXT'
    zone_id new_resource.dns_zone
    aws_access_key_id new_resource.access_key_id
    aws_secret_access_key new_resource.secret_access_key
    action :delete
  end
  directory "#{new_resource.key_directory}/#{new_resource.domain}" do
    action :delete
    recursive true
  end
end

def get_txt(record)
  txt = /p=[^"]*/.match(record)
  quot = '"'
  "#{quot}v=DKIM1; k=rsa; #{txt}#{quot}"
end
