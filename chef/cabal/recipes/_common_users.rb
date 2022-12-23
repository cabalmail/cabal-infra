users = []
CognitoUsers.list(node['cognito']['pool_id'], { region: node['ec2']['region'] }).each do |user|
  users.push(user)
end
users.sort_by { |u| u.user_create_date }
users.each do |u|
  u.attributes.each do |a|
    if (a.name == "zoneinfo") then
      uid = a.value
    end
  end
  user u.username do
    uid u.zoneinfo
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
end
