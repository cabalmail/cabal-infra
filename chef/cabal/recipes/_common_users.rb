# TODO: Get these from some user pool
%w(test1 test2 test3).each do |u|
# TODO: Get from some kink of vault
  password = 'test1234'
  user u do
    password password
  end
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
