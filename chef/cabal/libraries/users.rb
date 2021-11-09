class CognitoUsers
  def self.list(pool_id, options)
    require 'aws-sdk-cognitoidentity'
    region = options[:region]
    cognito = Aws::CognitoIdentity::Client.new(region: region)
    resp = cognito.scan(identity_pool_id: pool_id, max_results: 1000)
    resp.identities
  end
end
