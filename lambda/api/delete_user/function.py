'''Deletes a user from the Cognito user pool (admin only)'''  # pylint: disable=duplicate-code
import json
import os
import boto3  # pylint: disable=import-error

cognito = boto3.client('cognito-idp')
user_pool_id = os.environ['USER_POOL_ID']


def handler(event, _context):
    '''Deletes a user account'''
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    caller = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event['body'])
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
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps({'status': 'deleted', 'username': username})
    }
