'''Disables a user in the Cognito user pool (admin only)'''  # pylint: disable=duplicate-code
import json
import os
import boto3  # pylint: disable=import-error
from admin_limits import audit_log, rate_limit_response_or_none  # pylint: disable=import-error

cognito = boto3.client('cognito-idp')
user_pool_id = os.environ['USER_POOL_ID']


def handler(event, _context):
    '''Disables a user account'''
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    caller = event['requestContext']['authorizer']['claims']['cognito:username']
    limited = rate_limit_response_or_none(caller, 'disable_user')
    if limited:
        return limited
    try:
        body = json.loads(event.get('body') or '')
    except (TypeError, ValueError):
        body = None
    if not isinstance(body, dict):
        return {
            'statusCode': 400,
            'body': json.dumps({'status': 'Invalid input: request body is not valid JSON'})
        }
    username = ''
    try:
        username = body['username']
        cognito.admin_disable_user(
            UserPoolId=user_pool_id,
            Username=username
        )
    except Exception as err:  # pylint: disable=broad-exception-caught
        audit_log(caller, 'disable_user', username, 'failure')
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    audit_log(caller, 'disable_user', username, 'success')
    return {
        'statusCode': 200,
        'body': json.dumps({'status': 'disabled', 'username': username})
    }
