'''Assigns an additional user to an existing email address (admin only)'''
# pylint: disable=too-many-return-statements
import json
import os
import boto3  # pylint: disable=import-error
from address_events import notify_containers  # pylint: disable=import-error
from admin_limits import ( # pylint: disable=import-error
    admin_response_or_none,
    audit_log,
    parse_json_object_body,
    rate_limit_response_or_none,
)

user_pool_id = os.environ['USER_POOL_ID']

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')
cognito = boto3.client('cognito-idp')


def handler(event, _context):
    '''Adds a user to an existing address'''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    caller = event['requestContext']['authorizer']['claims']['cognito:username']
    limited = rate_limit_response_or_none(caller, 'assign_address')
    if limited:
        return limited
    body, invalid = parse_json_object_body(event)
    if invalid:
        return invalid
    address = body['address']
    new_user = body['username']
    try:
        if not cognito_user_exists(new_user):
            return {
                'statusCode': 400,
                'body': json.dumps({'Error': f'User "{new_user}" does not exist'})
            }
        response = table.get_item(Key={'address': address})
        item = response.get('Item')
        if not item:
            return {
                'statusCode': 404,
                'body': json.dumps({'Error': f'Address "{address}" not found'})
            }
        current_users = item['user'].split('/')
        if new_user in current_users:
            return {
                'statusCode': 400,
                'body': json.dumps({
                    'Error': f'User "{new_user}" already assigned to "{address}"'
                })
            }
        current_users.append(new_user)
        item['user'] = '/'.join(current_users)
        table.put_item(Item=item)
        notify_containers()
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f"Error assigning user {new_user} to address {address}: {err}")
        audit_log(caller, 'assign_address', f'{address}:{new_user}', 'failure')
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    audit_log(caller, 'assign_address', f'{address}:{new_user}', 'success')
    return {
        'statusCode': 200,
        'body': json.dumps({
            'address': address,
            'user': item['user']
        })
    }


def cognito_user_exists(username):
    '''Returns True if the username exists in the Cognito user pool'''
    try:
        cognito.admin_get_user(UserPoolId=user_pool_id, Username=username)
        return True
    except cognito.exceptions.UserNotFoundException:
        return False
