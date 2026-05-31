'''Sets per-user, per-domain create-address permission (admin only).

Writes or removes an allow row in cabal-user-domain-access. Body shape:

    {"user": "<cognito-username>", "domain": "<apex>", "allowed": <bool>}

allowed=True writes an allow row; allowed=False deletes any existing row,
restoring the default-deny state. The domain must be a known mail apex
domain (as declared via the DOMAINS env var).
'''
# pylint: disable=too-many-return-statements
import json
import os
import boto3  # pylint: disable=import-error
from admin_limits import audit_log, rate_limit_response_or_none  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
user_pool_id = os.environ['USER_POOL_ID']

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-user-domain-access')
cognito = boto3.client('cognito-idp')


def handler(event, _context):
    '''Add or remove a (user, domain) deny entry.'''
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    caller = event['requestContext']['authorizer']['claims']['cognito:username']
    limited = rate_limit_response_or_none(caller, 'set_user_domain_access')
    if limited:
        return limited
    try:
        body = json.loads(event.get('body') or '{}')
    except (TypeError, ValueError):
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'Invalid JSON body.'})
        }
    username = body.get('user')
    domain = body.get('domain')
    allowed = body.get('allowed')
    if not username or not domain or not isinstance(allowed, bool):
        return {
            'statusCode': 400,
            'body': json.dumps({
                'Error': 'Body requires user (str), domain (str), allowed (bool).'
            })
        }
    if domain not in domains:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': f'Unknown domain "{domain}"'})
        }
    if not cognito_user_exists(username):
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': f'User "{username}" does not exist'})
        }
    try:
        if allowed:
            table.put_item(Item={'user': username, 'domain': domain})
        else:
            table.delete_item(Key={'user': username, 'domain': domain})
    except Exception as err:  # pylint: disable=broad-exception-caught
        audit_log(caller, 'set_user_domain_access', f'{username}:{domain}', 'failure')
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    audit_log(caller, 'set_user_domain_access', f'{username}:{domain}',
              'allowed' if allowed else 'denied')
    return {
        'statusCode': 200,
        'body': json.dumps({
            'user': username,
            'domain': domain,
            'allowed': allowed
        })
    }


def cognito_user_exists(username):
    '''Returns True if the username exists in the Cognito user pool.'''
    try:
        cognito.admin_get_user(UserPoolId=user_pool_id, Username=username)
        return True
    except cognito.exceptions.UserNotFoundException:
        return False
