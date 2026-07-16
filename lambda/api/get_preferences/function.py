'''Fetches the current user's preferences (theme/accent/density/name/app).'''
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
    'name': '',
}


def handler(event, _context):
    '''Returns saved preferences for the caller, or defaults if none exist.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        response = table.get_item(Key={'user': user})
        item = response.get('Item', {})
        prefs = {k: item.get(k, default) for k, default in DEFAULTS.items()}
        # The Apple clients namespace their own preferences under `app` (a
        # DynamoDB Map) so they never collide with the flat theme/accent/
        # density fields the React app owns. Absent for users who have only
        # ever used the web client - an empty object, which the Apple client
        # reads as "fall back to local defaults".
        prefs['app'] = item.get('app', {})
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps(prefs)
    }
