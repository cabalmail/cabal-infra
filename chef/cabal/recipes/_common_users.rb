users = []
uid   = 2000
CognitoUsers.list(node['cognito']['pool_id'], { region: node['ec2']['region'] }).each do |user|
  users.push(user)
end
users.sort_by { |u| u.user_create_date }
users.each do |u|
  user u.username do
    uid uid
  end
  directory "/home/#{u.username}" do
    owner u.username
    group u.username
    mode 0700
  end
  directory "/home/#{u.username}/Maildir" do
    owner u.username
    group u.username
    mode 0700
  end
  directory "/home/#{u.username}/.procmail" do
    owner u.username
    group u.username
    mode 0755
  end
  cookbook_file "/home/#{u.username}/.procmailrc" do
    source 'procmailrc'
    owner u.username
    group u.username
    mode 0744
  end
  uid += 1
end
