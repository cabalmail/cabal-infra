'''Deletes a user from the Cognito user pool (admin only)'''  # pylint: disable=duplicate-code
import json
import os
import boto3  # pylint: disable=import-error
from boto3.dynamodb.conditions import Key  # pylint: disable=import-error
from admin_limits import audit_log, rate_limit_response_or_none  # pylint: disable=import-error

cognito = boto3.client('cognito-idp')
user_pool_id = os.environ['USER_POOL_ID']
ddb = boto3.resource('dynamodb')
user_domain_access_table = ddb.Table('cabal-user-domain-access')


def handler(event, _context):
    '''Deletes a user account'''
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    caller = event['requestContext']['authorizer']['claims']['cognito:username']
    limited = rate_limit_response_or_none(caller, 'delete_user')
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
        if username == caller:
            return {
                'statusCode': 400,
                'body': json.dumps({'Error': 'Cannot delete your own account'})
            }
        cognito.admin_delete_user(
            UserPoolId=user_pool_id,
            Username=username
        )
        purge_domain_access(username)
    except Exception as err:  # pylint: disable=broad-exception-caught
        audit_log(caller, 'delete_user', username, 'failure')
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    audit_log(caller, 'delete_user', username, 'success')
    return {
        'statusCode': 200,
        'body': json.dumps({'status': 'deleted', 'username': username})
    }


def purge_domain_access(username):
    '''Removes all (username, *) rows from cabal-user-domain-access so a
    re-created user with the same name doesn't inherit stale grants.'''
    query_kwargs = {
        'KeyConditionExpression': Key('user').eq(username),
        'ProjectionExpression': '#d',
        'ExpressionAttributeNames': {'#d': 'domain'}
    }
    while True:
        response = user_domain_access_table.query(**query_kwargs)
        with user_domain_access_table.batch_writer() as batch:
            for item in response.get('Items', []):
                batch.delete_item(Key={'user': username, 'domain': item['domain']})
        if 'LastEvaluatedKey' not in response:
            break
        query_kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
