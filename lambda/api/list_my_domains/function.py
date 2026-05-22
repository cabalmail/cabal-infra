'''Lists the apex domains on which the calling user can create addresses.

The cabal-user-domain-access table is an allow list: a (user, domain) row
means the caller is permitted to use that apex. This function returns the
intersection of the configured DOMAINS list and the user's allow rows so
the React client can populate the address-creation picker with exactly the
apexes the user is entitled to.
'''
import json
import os
import boto3  # pylint: disable=import-error
from boto3.dynamodb.conditions import Key  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-user-domain-access')


def handler(event, _context):
    '''Returns {"Domains": [<allowed apex>...]}.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        allowed_set = set()
        query_kwargs = {
            'KeyConditionExpression': Key('user').eq(user),
            'ProjectionExpression': '#d',
            'ExpressionAttributeNames': {'#d': 'domain'}
        }
        while True:
            response = table.query(**query_kwargs)
            for item in response.get('Items', []):
                allowed_set.add(item['domain'])
            if 'LastEvaluatedKey' not in response:
                break
            query_kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
        allowed = [d for d in domains if d in allowed_set]
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps({'Domains': allowed})
    }
