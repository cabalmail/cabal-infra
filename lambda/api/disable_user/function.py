'''Disables a user in the Cognito user pool (admin only)'''
import os
import boto3  # pylint: disable=import-error
from admin_limits import admin_user_action_response  # pylint: disable=import-error

cognito = boto3.client('cognito-idp')
user_pool_id = os.environ['USER_POOL_ID']


def handler(event, _context):
    '''Disables a user account'''
    return admin_user_action_response(event, 'disable_user', 'disabled', disable_user)


def disable_user(username):
    '''Disables the named account in the user pool'''
    cognito.admin_disable_user(
        UserPoolId=user_pool_id,
        Username=username
    )
