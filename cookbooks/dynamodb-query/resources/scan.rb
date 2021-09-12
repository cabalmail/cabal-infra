resource_name :dynamodb_scan
unified_mode true
property :table, String, required: true
property :apikey, String, required: false
property :secretkey, String, required: false
property :region, String, required: false
property :namespace, Array, required: true

action :scan do
  begin
    require 'aws-sdk'
    dynamodb = Aws::DynamoDB::Client.new(region: new_resource.region)
    resp = dynamodb.scan(table_name: new_resource.table)
    ns = new_resource.namespace
    case ns.length
    when 1
      node.default[ns[0]] = resp.items
    when 2
      node.default[ns[0]][ns[1]] = resp.items
    when 3
      node.default[ns[0]][ns[1]][ns[2]] = resp.items
    when 4
      node.default[ns[0]][ns[1]][ns[2]][ns[3]] = resp.items
    else
      raise "Namespace to deep"
    end
  end
end
