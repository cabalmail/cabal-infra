template '/usr/bin/cognito.bash' do
  mode '0100'
  owner 'root'
  group 'root'
  source 'cognito.bash.erb'
  variables(
    :region => node['cognito']['region'],
    :client_id => node['cognito']['client_id']
  )
end