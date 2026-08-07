'''Lists all email addresses across all users (admin only)'''
# pylint: disable=duplicate-code
import json
import boto3  # pylint: disable=import-error
from admin_limits import admin_response_or_none  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Lists all addresses with their assigned users'''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    try:
        items = []
        scan_kwargs = {
            'ExpressionAttributeNames': {
                '#user': 'user',
                '#c': 'comment',
                '#s': 'suspended'
            },
            'ProjectionExpression': 'subdomain, #c, tld, address, username, #user, #s'
        }
        while True:
            response = table.scan(**scan_kwargs)
            for item in response.get('Items', []):
                item['suspended'] = bool(item.get('suspended'))
                items.append(item)
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
        'body': json.dumps({'Items': items})
    }
