users = []
Cognito.list(node['cognito']['pool_id'], { region: node['ec2']['region'] }).each do |user|
  users.push(user.username)
end

users.each do |u|
  directory "/home/#{u}" do
    owner u
    group u
    mode 0700
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
