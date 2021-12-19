provides :port

property :port, String, name_property: true, required: true

action :open do
  execute "add port #{new_resource.port} to zone" do
    not_if "firewall-cmd --permanent --zone=public --query-port=#{new_resource.port}/tcp"
    command(<<-EOC)
    firewall-cmd --permanent --zone=public --add-port=#{new_resource.port}/tcp
    EOC
  end
end

action :close do
  execute "add port #{new_resource.port} to zone" do
    only_if "firewall-cmd --permanent --zone=public --query-port=#{new_resource.port}/tcp"
    command(<<-EOC)
    firewall-cmd --permanent --zone=public --remove-port=#{new_resource.port}/tcp
    EOC
  end
end