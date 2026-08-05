'''Lists all users in the Cognito user pool (admin only)'''
import json
import os
import boto3  # pylint: disable=import-error
from admin_limits import admin_response_or_none  # pylint: disable=import-error

cognito = boto3.client('cognito-idp')
user_pool_id = os.environ['USER_POOL_ID']


def handler(event, _context):
    '''Lists all users in the Cognito user pool'''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    try:
        users = []
        params = {
            'UserPoolId': user_pool_id
        }
        while True:
            response = cognito.list_users(**params)
            for user in response['Users']:
                attrs = {a['Name']: a['Value'] for a in user.get('Attributes', [])}
                users.append({
                    'username': user['Username'],
                    'status': user['UserStatus'],
                    'enabled': user['Enabled'],
                    'created': user['UserCreateDate'].isoformat(),
                    'osid': attrs.get('custom:osid', '')
                })
            pagination_token = response.get('PaginationToken')
            if not pagination_token:
                break
            params['PaginationToken'] = pagination_token
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps({'Users': users})
    }
