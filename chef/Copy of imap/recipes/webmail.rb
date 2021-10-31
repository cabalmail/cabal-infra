yum_package %w(php56 php56-fpm)

service 'php-fpm' do
  action [:start, :enable]
end

rainloop_data = '/usr/share/nginx/html/rainloop/data/_data_/_default_/storage/cfg'
identities = {}
accounts = {}
data_bag('users').each do |u|
  accounts[u]  = {
    Accounts: ["#{u}@cabalmail.com"],
  }
  identities[u] = [
    {
      Id: '',
      Email: 'x@example.com',
      Name: 'USER A DIFFERENT ADDRESS',
      ReplyTo: '',
      Bcc: '',
      Signature: '',
      SignatureInsertBefore: false
    }
  ]
end

DynamoDBQuery.scan('cabal-addresses', { region: node['ec2']['region'] }).each do |item|
  unless item['user'].include? '/'
    identities[item['user']] << {
      Id: item['address'],
      Email: item['address'],
      Name: '',
      ReplyTo: '',
      Bcc: '',
      Signature: '',
      SignatureInsertBefore: false
    }
  end
end

data_bag('users').each do |u|
  accounts[u]['Identities'] = identities[u].map{ |i| i[:Id] }.sort
  directory "#{rainloop_data}/#{u[0..1]}/#{u}@cabalmail.com" do
    owner 'nginx'
    group 'apache'
    recursive true
    mode 0755
  end
  file "#{rainloop_data}/#{u[0..1]}/#{u}@cabalmail.com/identities.test" do
    content Chef::JSONCompat.to_json(identities[u])
    owner 'nginx'
    group 'apache'
    mode 0644
  end
  file "#{rainloop_data}/#{u[0..1]}/#{u}@cabalmail.com/accounts_identities_order.test" do
    content Chef::JSONCompat.to_json(accounts[u])
    owner 'nginx'
    group 'apache'
    mode 0644
  end
end

# [
#   {
#     "Id":"",
#     "Email":"chris@cabalmail.com",
#     "Name":"",
#     "ReplyTo":"",
#     "Bcc":"",
#     "Signature":"",
#     "SignatureInsertBefore":false
#   },
#   {
#     "Id":"a2n4141xeul1im63sw4hzcrnassvmd48",
#     "Email":"xxx@example.com",
#     "Name":"Don't Use Me",
#     "ReplyTo":"",
#     "Bcc":"",
#     "Signature":"",
#     "SignatureInsertBefore":false
#   }
# ]

