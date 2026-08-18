'''Creates a new email address assigned to one or more users (admin only)'''
# pylint: disable=too-many-return-statements
import json
import os
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error
from address_events import notify_containers  # pylint: disable=import-error
from admin_limits import ( # pylint: disable=import-error
    admin_response_or_none,
    audit_log,
    rate_limit_response_or_none,
)
from helper import new_address_response_or_none  # pylint: disable=import-error
from helper import parse_json_body  # pylint: disable=import-error
from helper import publish_address_dns_records  # pylint: disable=import-error
from helper import user_authorized_for_domain  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']
user_pool_id = os.environ['USER_POOL_ID']

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')
cognito = boto3.client('cognito-idp')


def handler(event, _context):
    '''Creates a new email address assigned to one or more users'''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    caller = event['requestContext']['authorizer']['claims']['cognito:username']
    limited = rate_limit_response_or_none(caller, 'new_address_admin')
    if limited:
        return limited
    body, error = parse_json_body(event)
    if error:
        return error
    usernames = body.get('usernames') or []
    if not usernames:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'At least one username is required'})
        }
    refusal = new_address_response_or_none(body, domains, control_domain)
    if refusal:
        return refusal
    # Derive the address server-side rather than trusting body['address']: it is
    # the DynamoDB primary key and the value user_authorized_for_sender matches
    # on, so it must equal the real routing identity. username/subdomain/tld are
    # all validated above.
    address = f"{body['username']}@{body['subdomain']}.{body['tld']}"
    try:
        for username in usernames:
            if not cognito_user_exists(username):
                return {
                    'statusCode': 400,
                    'body': json.dumps({'Error': f'User "{username}" does not exist'})
                }
            if not user_authorized_for_domain(username, body['tld']):
                return {
                    'statusCode': 403,
                    'body': json.dumps({
                        'Error': (
                            f'User "{username}" is not permitted to create '
                            f"addresses on \"{body['tld']}\""
                        )
                    })
                }
        publish_address_dns_records(
            domains[body['tld']], body['subdomain'], body['tld'], control_domain)
        record_address(usernames, body, address)
        notify_containers()
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f"Error creating address {address}: {err}")
        audit_log(caller, 'new_address_admin', address, 'failure')
        return {
            'statusCode': 500,
            'body': json.dumps({
                'address': address,
                'error': str(err)
            })
        }
    audit_log(caller, 'new_address_admin', address, 'success')
    return {
        'statusCode': 201,
        'body': json.dumps({
            'address': address,
            'user': '/'.join(usernames)
        })
    }


def cognito_user_exists(username):
    '''Returns True if the username exists in the Cognito user pool'''
    try:
        cognito.admin_get_user(UserPoolId=user_pool_id, Username=username)
        return True
    except cognito.exceptions.UserNotFoundException:
        return False


def record_address(usernames, body, address):
    '''Records the new address in DynamoDB'''
    table.put_item(Item={
        'address': address,
        'tld': body['tld'],
        'user': '/'.join(usernames),
        'username': body['username'],
        'subdomain': body['subdomain'],
        'comment': body.get('comment', ''),
        'RequestTime': datetime.now(timezone.utc).isoformat()
    })
