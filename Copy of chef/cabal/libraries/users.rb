class CognitoUsers
  def self.list(pool_id, options)
    require 'aws-sdk-cognitoidentityprovider'
    region = options[:region]
    cognito = Aws::CognitoIdentityProvider::Client.new(region: region)
    resp = cognito.list_users({
      user_pool_id: pool_id
    })
    resp.users
  end
end