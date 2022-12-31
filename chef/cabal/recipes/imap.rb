include_recipe 'cabal::_common'
include_recipe 'cabal::_imap_dovecot'
include_recipe 'cabal::_imap_sendmail'
include_recipe 'cabal::_imap_dns'
include_recipe 'cabal::_common_users'

port '143'
port '993'
port '25'