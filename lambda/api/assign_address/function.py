'''Assigns an additional user to an existing email address (admin only)'''
# pylint: disable=duplicate-code
import json
import os
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error

address_changed_topic_arn = os.environ.get('ADDRESS_CHANGED_TOPIC_ARN', '')
user_pool_id = os.environ['USER_POOL_ID']

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')
sns = boto3.client('sns')
cognito = boto3.client('cognito-idp')


def handler(event, _context):
    '''Adds a user to an existing address'''
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    body = json.loads(event['body'])
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
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
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


def notify_containers():
    '''Publishes an address change event to SNS'''
    if not address_changed_topic_arn:
        print('ADDRESS_CHANGED_TOPIC_ARN not set, skipping SNS publish')
        return
    sns.publish(
        TopicArn=address_changed_topic_arn,
        Message=json.dumps({
            'event': 'address_changed',
            'timestamp': datetime.now(timezone.utc).isoformat()
        })
    )
