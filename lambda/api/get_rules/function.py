'''Fetches the current user's mail rules (docs/1.x/user-mail-rules-plan.md).'''
import json
import os
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('USER_RULES_TABLE_NAME', 'cabal-user-rules')
table = ddb.Table(TABLE_NAME)


def handler(event, _context):
    '''Returns the caller's rule set, or an empty version-0 set if none exists.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        # Consistent read so a reload right after a 409 (set_rules optimistic-
        # concurrency conflict) is guaranteed to see the winning write.
        response = table.get_item(Key={'user': user}, ConsistentRead=True)
        item = response.get('Item', {})
        body = {
            'rules': json.loads(item.get('rules', '[]')),
            'version': int(item.get('version', 0)),
            'updatedAt': item.get('updatedAt', ''),
        }
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps(body)
    }
