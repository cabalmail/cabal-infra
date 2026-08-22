'''Removes a user from a multi-user email address (admin only)'''
# pylint: disable=too-many-return-statements
import json
import boto3  # pylint: disable=import-error
from address_events import notify_containers  # pylint: disable=import-error
from admin_limits import ( # pylint: disable=import-error
    admin_response_or_none,
    audit_log,
    parse_json_object_body,
    rate_limit_response_or_none,
)

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Removes a user from an address'''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    caller = event['requestContext']['authorizer']['claims']['cognito:username']
    limited = rate_limit_response_or_none(caller, 'unassign_address')
    if limited:
        return limited
    body, invalid = parse_json_object_body(event)
    if invalid:
        return invalid
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
        audit_log(caller, 'unassign_address', f'{address}:{target_user}', 'failure')
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    audit_log(caller, 'unassign_address', f'{address}:{target_user}', 'success')
    return {
        'statusCode': 200,
        'body': json.dumps({
            'address': address,
            'user': item['user']
        })
    }
