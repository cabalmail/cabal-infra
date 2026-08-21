'''Enables a user in the Cognito user pool (admin only)'''
import os
import boto3  # pylint: disable=import-error
from admin_limits import admin_user_action_response  # pylint: disable=import-error

cognito = boto3.client('cognito-idp')
user_pool_id = os.environ['USER_POOL_ID']


def handler(event, _context):
    '''Enables a disabled user account'''
    return admin_user_action_response(event, 'enable_user', 'enabled', enable_user)


def enable_user(username):
    '''Enables the named account in the user pool'''
    cognito.admin_enable_user(
        UserPoolId=user_pool_id,
        Username=username
    )
