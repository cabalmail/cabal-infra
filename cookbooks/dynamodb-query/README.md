# dynamodb-query

This cookbook provides a resource for querying a DynamoDB table. See [USAGE](#usage).

## Requirements

### Platforms

- Amazon Linux 2

### Chef

- Chef 17.*

## Attributes

none

## Recipes

none

## Resources

none

## Libraries

DynamoDB

### scan Method

The `scan` method takes two arguments: A tablename and a hash. The only supported option is `region`, which is the AWS region.

## Usage

### Getting Started

Add this to your metadata.rb:

```ruby
depends 'dynamodb-query'
```

You must pass credentials using an IAM role, which implies that you can only use this cookbook on an EC2 cloud instance.

### Example

```ruby
DynamoDBQuery.scan('users', { region: node['ec2']['region'] }).each do |u|
  user u['username'] do
    shell u['shell']
    password u['pwhash']
  end
end
```

## Maintainer

Chris Carr

## License

**Copyright:** 2019, Chris Carr

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.