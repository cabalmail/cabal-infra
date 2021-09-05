# dynamodb-query

This cookbook provides a resource for querying a DynamoDB table. See [USAGE](#usage).

## Requirements

### Platforms

- Amazon Linux
- Amazon Linux 2

### Chef

- Chef 14.0+

## Attributes

This cookbook has four optional attributes that you can use to supply default values when querying via the [dynamodb-query resource](#dynamodb-query)

- `node['dynamodb-query']['default_table']` - Table to use when not specified as a resource property.
- `node['dynamodb-query']['default_index']` - Index to use when not specified as a resource property.
- `node['dynamodb-query']['default_awsregion']` - Region to use for the AWS API when not specified as a resource property.
- `node['dynamodb-query']['default_awsapikey']` - API key ID to use for the AWS API when not specified as a resource property.
- `node['dynamodb-query']['default_awssecretkey']` - Secret key to use for the AWS API when not specified as a resource property.

## Recipes

none

## Resources

### dynamodb-scan

Use dynamodb-scan to get all items from a DynamoDB table. See [sample usage](#usage) below.

### dynamodb-query

Use the dynamodb-query resource to query a DynamoDB table. See [sample usage](#usage) below.

## Usage

### Getting Started

Add this to your metadata.rb:

```ruby
depends 'dynamodb-query'
```

You have three options for passing IAM credentials:
1. If your node is in EC2, you can attach a roll with AmazonDynamoDBReadOnlyAccess policy attached.
2. You may supply an API key pair as attributes (see [Attributes](#attributes) above).
3. You may supply an API key pair as parameters to the resource as shown below.

### Making attributes available

This resource adds attributes to the node object. If run during converge (the standard behavior for resources), the attributes will not be available to other resources unless evaluated with `lazy {}`. Depending on your use case, it may be more convenient to force it to run during compile. The below examples show this.

### Examples

To perform a query and store the result in an attribute:

```ruby
dynamodb-query 'Get user list' do
  table 'mytable'
  index 'myindex'
  limit 10
  fields %w(username realname id)
  keycondition 'Id = :v1 AND MyIndex BETWEEN :v2a AND :v2b'
  namespace %w(system users)
  region 'us-east-1'
  apikey 'AKIAIxxxxxxxxxxxxxxx'
  secretkey 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
end.run_action(:query)
```

Presuming a suitable table and index, this would insert the following data into the node object:

```ruby
node.default['system']['users'] = [
  { username: 'user1', realname: 'User One', id: 1 },
  { username: 'user2', realname: 'User Two', id: 2 }
]
```

More advanced usage:

```ruby
dynamodb-query 'Get user list and query metadata' do
  table 'mytable'
  index 'myindex'
  limit 10
  fields %w(username realname id)
  keycondition 'Id = :v1 AND MyIndex BETWEEN :v2a AND :v2b'
  namespace %w(system users)
  precidence 'normal'
  metadata_namespace %w(system querymetadata)
  metadata_precidence 'default'
  region 'us-east-1'
  apikey 'AKIAIxxxxxxxxxxxxxxx'
  secretkey 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
end.run_action(:query)
```

This would insert the following data into the node object:

```ruby
node.normal['system']['users'] = [
  { username: 'user1', realname: 'User One', id: 1 },
  { username: 'user2', realname: 'User Two', id: 2 }
]
node.default['system']['querymetadata'] = {
  ConsumedCapackty: {
    CapacityUnits: 1,
    TableName: 'mytable'
  },
  Count: 2,
  ScannedCount: 2
}
```

Use the default attributes to simplify:

```ruby
dynamodb-query 'Get user list' do
  limit 10
  fields %w(username realname id)
  keycondition 'Id = :v1 AND MyIndex BETWEEN :v2a AND :v2b'
  namespace %w(system users)
end.run_action(:query)
```

To get _all_ items from a table:

```ruby
dynamodb-scan 'Get all users' do
  table 'mytable'
  namespace %w(system users)
end.run_action(:scan)
```

## Maintainer

Chris Carr

## License

**Copyright:** 2019, Chris Carr
```
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
