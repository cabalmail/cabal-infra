'''Lists all email addresses across all users (admin only)'''
# pylint: disable=duplicate-code
import json
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Lists all addresses with their assigned users'''
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    try:
        items = []
        scan_kwargs = {
            'ExpressionAttributeNames': {
                '#user': 'user',
                '#c': 'comment'
            },
            'ProjectionExpression': 'subdomain, #c, tld, address, username, #user'
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
        'body': json.dumps({'Items': items})
    }
