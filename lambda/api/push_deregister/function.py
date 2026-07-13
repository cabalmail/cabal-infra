'''Deletes an APNs device-token registration for the calling user.

The Apple clients call this on sign-out (and when the user turns push off in
the app). Deleting a row that is already gone is a success: the goal state is
"this device no longer receives pushes". push_dispatch also prunes rows on
APNs Unregistered/BadDeviceToken, so this endpoint is the polite path, not the
only one. See docs/0.11.0/push-notifications.md.
'''
import json
import os
import re
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('PUSH_TOKENS_TABLE_NAME', 'cabal-push-tokens')
table = ddb.Table(TABLE_NAME)

# Same shape rule as push_register; see the comment there.
DEVICE_TOKEN_RE = re.compile(r'^[0-9a-f]{16,400}$')


def handler(event, _context):
    '''Deletes the caller's device-token row.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event.get('body') or '{}')
    except (TypeError, ValueError):
        return {'statusCode': 400, 'body': json.dumps({'Error': 'Invalid JSON body.'})}

    device_token = str(body.get('device_token', '')).lower()
    if not DEVICE_TOKEN_RE.match(device_token):
        return {'statusCode': 400, 'body': json.dumps({'Error': 'Invalid device_token.'})}

    try:
        table.delete_item(Key={'user': user, 'device_token': device_token})
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {'statusCode': 500, 'body': json.dumps({'Error': str(err)})}
    return {'statusCode': 200, 'body': json.dumps({'status': 'deregistered'})}
