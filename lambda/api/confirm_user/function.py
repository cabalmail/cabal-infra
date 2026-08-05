'''Confirms a pending user in the Cognito user pool (admin only)'''
import json
import os
import boto3  # pylint: disable=import-error
from admin_limits import admin_response_or_none  # pylint: disable=import-error

cognito = boto3.client('cognito-idp')
user_pool_id = os.environ['USER_POOL_ID']


def handler(event, _context):
    '''Confirms a pending user signup'''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    try:
        body = json.loads(event.get('body') or '')
    except (TypeError, ValueError):
        body = None
    if not isinstance(body, dict):
        return {
            'statusCode': 400,
            'body': json.dumps({'status': 'Invalid input: request body is not valid JSON'})
        }
    try:
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
