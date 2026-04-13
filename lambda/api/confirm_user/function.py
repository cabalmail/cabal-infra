'''Confirms a pending user in the Cognito user pool (admin only)'''
import json
import os
import boto3  # pylint: disable=import-error

cognito = boto3.client('cognito-idp')
user_pool_id = os.environ['USER_POOL_ID']


def handler(event, _context):
    '''Confirms a pending user signup'''
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    try:
        body = json.loads(event['body'])
        username = body['username']
        cognito.admin_confirm_sign_up(
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
        'body': json.dumps({'status': 'confirmed', 'username': username})
    }
