'''Enables a user in the Cognito user pool (admin only)'''  # pylint: disable=duplicate-code
import json
import os
import boto3  # pylint: disable=import-error
from admin_limits import audit_log, rate_limit_response_or_none  # pylint: disable=import-error

cognito = boto3.client('cognito-idp')
user_pool_id = os.environ['USER_POOL_ID']


def handler(event, _context):
    '''Enables a disabled user account'''
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    caller = event['requestContext']['authorizer']['claims']['cognito:username']
    limited = rate_limit_response_or_none(caller, 'enable_user')
    if limited:
        return limited
    username = ''
    try:
        body = json.loads(event['body'])
        username = body['username']
        cognito.admin_enable_user(
            UserPoolId=user_pool_id,
            Username=username
        )
    except Exception as err:  # pylint: disable=broad-exception-caught
        audit_log(caller, 'enable_user', username, 'failure')
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    audit_log(caller, 'enable_user', username, 'success')
    return {
        'statusCode': 200,
        'body': json.dumps({'status': 'enabled', 'username': username})
    }
