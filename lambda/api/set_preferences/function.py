'''Persists the current user's webmail preferences (theme/accent/density).'''
import json
import os
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('USER_PREFERENCES_TABLE_NAME', 'cabal-user-preferences')
table = ddb.Table(TABLE_NAME)

ALLOWED = {
    'theme':   {'light', 'dark'},
    'accent':  {'ink', 'oxblood', 'forest', 'azure', 'amber', 'plum'},
    'density': {'compact', 'normal', 'roomy'},
}


def handler(event, _context):
    '''Validates and upserts the caller's preferences row.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event.get('body') or '{}')
    except (TypeError, ValueError):
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'Invalid JSON body.'})
        }
    item = {'user': user}
    for key, allowed in ALLOWED.items():
        if key in body:
            value = body[key]
            if value not in allowed:
                return {
                    'statusCode': 400,
                    'body': json.dumps({'Error': f'Invalid value for {key}.'})
                }
            item[key] = value
    if len(item) == 1:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'No known preference keys supplied.'})
        }
    try:
        table.put_item(Item=item)
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps({k: v for k, v in item.items() if k != 'user'})
    }
