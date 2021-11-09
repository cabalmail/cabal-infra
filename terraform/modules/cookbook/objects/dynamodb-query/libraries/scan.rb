class DynamoDBQuery
  def self.scan(table, options)
    require 'aws-sdk-dynamodb'
    region = options[:region]
    dynamodb = Aws::DynamoDB::Client.new(region: region)
    resp = dynamodb.scan(table_name: table)
    resp.items
  end
end
