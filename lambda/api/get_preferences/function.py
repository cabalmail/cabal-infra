'''Fetches the current user's preferences (theme/accent/density/name/app),
with the version set_preferences has counted the row up to.'''
import json
import os
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('USER_PREFERENCES_TABLE_NAME', 'cabal-user-preferences')
table = ddb.Table(TABLE_NAME)

# set_preferences holds the same table for its 409 answer, which is this
# Lambda's answer for the row as it is; test_preferences_version.py holds
# the two equal.
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
        # A consistent read: a client pulls straight after it writes (the
        # Apple clients push an unsent change and then pull), and a read
        # of the row as it was before that write would put the older
        # values back over the change just sent (#2442).
        response = table.get_item(Key={'user': user}, ConsistentRead=True)
        item = response.get('Item', {})
        prefs = {k: item.get(k, default) for k, default in DEFAULTS.items()}
        # The Apple clients namespace their own preferences under `app` (a
        # DynamoDB Map) so they never collide with the flat theme/accent/
        # density fields the React app owns. Absent for users who have only
        # ever used the web client - an empty object, which the Apple client
        # reads as "fall back to local defaults".
        prefs['app'] = item.get('app', {})
        # What a client sends back as `expectedVersion` with its next
        # write. Top level, never inside `app`: the native clients decode
        # that map as string to string, and a number in it would fail the
        # whole pull on builds in the field. 0 for a row no versioned
        # write has touched.
        prefs['version'] = int(item.get('prefs_version', 0))
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps(prefs)
    }
