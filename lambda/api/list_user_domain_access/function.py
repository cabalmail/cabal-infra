'''Lists all per-user, per-domain allow entries (admin only).

The cabal-user-domain-access table is an allow list: each row represents a
(user, domain) pair where the user IS permitted to create addresses on
that apex domain. Absence of a row is the default-deny state.
'''
import json
import boto3  # pylint: disable=import-error
from admin_limits import admin_response_or_none  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-user-domain-access')


def handler(event, _context):
    '''Returns the full allow list as a flat array of {user, domain} items.'''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    try:
        items = []
        scan_kwargs = {
            'ProjectionExpression': '#u, #d',
            'ExpressionAttributeNames': {
                '#u': 'user',
                '#d': 'domain'
            }
        }
        while True:
            response = table.scan(**scan_kwargs)
            items.extend(response.get('Items', []))
            if 'LastEvaluatedKey' not in response:
                break
            scan_kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps({'Allowances': items})
    }
