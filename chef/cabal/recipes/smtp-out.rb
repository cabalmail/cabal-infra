include_recipe 'cabal::_common'
include_recipe 'cabal::_smtp-common_sendmail'
include_recipe 'cabal::_smtp-out_sendmail'
include_recipe 'cabal::_smtp-out_dkim'
include_recipe 'cabal::_common_users'

port '25'
port '465'
port '587'