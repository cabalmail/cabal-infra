'''Confirms a pending user in the Cognito user pool (admin only)'''
import os
import boto3  # pylint: disable=import-error
from admin_limits import admin_user_action_response  # pylint: disable=import-error

cognito = boto3.client('cognito-idp')
user_pool_id = os.environ['USER_POOL_ID']


def handler(event, _context):
    '''Confirms a pending user signup'''
    return admin_user_action_response(event, 'confirm_user', 'confirmed', confirm_user)


def confirm_user(username):
    '''Confirms the named pending signup in the user pool'''
    cognito.admin_confirm_sign_up(
        UserPoolId=user_pool_id,
        Username=username
    )
