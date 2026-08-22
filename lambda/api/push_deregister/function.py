'''Deletes a push device-token registration for the calling user.

The clients call this on sign-out (and when the user turns push off in the
app). Deleting a row that is already gone is a success: the goal state is
"this device no longer receives pushes". push_dispatch also prunes rows on
push-service rejections (APNs Unregistered/BadDeviceToken, FCM UNREGISTERED),
so this endpoint is the polite path, not the only one. See
docs/0.11.x/push-notifications.md and docs/1.x/android-push-notifications.md.
'''
import json
import os
import re
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('PUSH_TOKENS_TABLE_NAME', 'cabal-push-tokens')
table = ddb.Table(TABLE_NAME)

# Same shape rules as push_register; see the comments there. This endpoint's
# body carries no bundle_id, so the two grammars are tried in turn: a token
# that reads as APNs hex is normalized to lowercase (matching what
# registration stored); anything else must fit the FCM charset and is used
# as-is (FCM tokens are case-significant, and a real one always carries a
# colon or base64url payload that the hex rule rejects).
APNS_DEVICE_TOKEN_RE = re.compile(r'^[0-9a-f]{16,400}$')
FCM_DEVICE_TOKEN_RE = re.compile(r'^[A-Za-z0-9_:\-]{16,400}$')


def handler(event, _context):
    '''Deletes the caller's device-token row.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event.get('body') or '{}')
    except (TypeError, ValueError):
        return {'statusCode': 400, 'body': json.dumps({'Error': 'Invalid JSON body.'})}

    device_token = str(body.get('device_token', ''))
    if APNS_DEVICE_TOKEN_RE.match(device_token.lower()):
        device_token = device_token.lower()
    elif not FCM_DEVICE_TOKEN_RE.match(device_token):
        return {'statusCode': 400, 'body': json.dumps({'Error': 'Invalid device_token.'})}

    try:
        table.delete_item(Key={'user': user, 'device_token': device_token})
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {'statusCode': 500, 'body': json.dumps({'Error': str(err)})}
    return {'statusCode': 200, 'body': json.dumps({'status': 'deregistered'})}
