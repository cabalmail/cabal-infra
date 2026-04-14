'''Removes a user from a multi-user email address (admin only)'''
# pylint: disable=duplicate-code
import json
import os
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error

address_changed_topic_arn = os.environ.get('ADDRESS_CHANGED_TOPIC_ARN', '')

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')
sns = boto3.client('sns')


def handler(event, _context):
    '''Removes a user from an address'''
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    body = json.loads(event['body'])
    address = body['address']
    target_user = body['username']
    try:
        response = table.get_item(Key={'address': address})
        item = response.get('Item')
        if not item:
            return {
                'statusCode': 404,
                'body': json.dumps({'Error': f'Address "{address}" not found'})
            }
        current_users = item['user'].split('/')
        if target_user not in current_users:
            return {
                'statusCode': 400,
                'body': json.dumps({
                    'Error': f'User "{target_user}" not assigned to "{address}"'
                })
            }
        if len(current_users) <= 1:
            return {
                'statusCode': 400,
                'body': json.dumps({
                    'Error': 'Cannot remove the last user from an address. '
                             'Use revoke to delete the address entirely.'
                })
            }
        current_users.remove(target_user)
        item['user'] = '/'.join(current_users)
        table.put_item(Item=item)
        notify_containers()
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f"Error unassigning user {target_user} from address {address}: {err}")
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
