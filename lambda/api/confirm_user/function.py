'''Confirms a pending user in the Cognito user pool (admin only)'''
import json
import os
import boto3  # pylint: disable=import-error
from admin_limits import ( # pylint: disable=import-error
    admin_response_or_none,
    parse_json_object_body,
)

cognito = boto3.client('cognito-idp')
user_pool_id = os.environ['USER_POOL_ID']


def handler(event, _context):
    '''Confirms a pending user signup'''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    body, invalid = parse_json_object_body(event)
    if invalid:
        return invalid
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
