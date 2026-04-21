'''Fetches the current user's webmail preferences (theme/accent/density).'''
import json
import os
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('USER_PREFERENCES_TABLE_NAME', 'cabal-user-preferences')
table = ddb.Table(TABLE_NAME)

DEFAULTS = {
    'theme': 'light',
    'accent': 'forest',
    'density': 'compact',
}


def handler(event, _context):
    '''Returns saved preferences for the caller, or defaults if none exist.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        response = table.get_item(Key={'user': user})
        item = response.get('Item', {})
        prefs = {k: item.get(k, default) for k, default in DEFAULTS.items()}
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps(prefs)
    }
