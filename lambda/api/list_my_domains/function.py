'''Lists the apex domains on which the calling user can create addresses.

The full set of mail domains is supplied via the DOMAINS env var; this
function intersects it with the deny list in cabal-user-domain-access so the
React client knows which domains to expose in the address-creation picker.
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
        denied = set()
        query_kwargs = {
            'KeyConditionExpression': Key('user').eq(user),
            'ProjectionExpression': '#d',
            'ExpressionAttributeNames': {'#d': 'domain'}
        }
        while True:
            response = table.query(**query_kwargs)
            for item in response.get('Items', []):
                denied.add(item['domain'])
            if 'LastEvaluatedKey' not in response:
                break
            query_kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
        allowed = [d for d in domains if d not in denied]
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps({'Domains': allowed})
    }
