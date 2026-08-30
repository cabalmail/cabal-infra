'''Creates a new email address'''
import json
import os
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error
from address_events import notify_containers  # pylint: disable=import-error
from helper import new_address_response_or_none  # pylint: disable=import-error
from helper import parse_json_body  # pylint: disable=import-error
from helper import publish_address_dns_records  # pylint: disable=import-error
from helper import user_authorized_for_domain  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Creates a new email address'''
    body, error = parse_json_body(event)
    if error:
        return error
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    refusal = new_address_response_or_none(body, domains, control_domain)
    if refusal:
        return refusal
    if not user_authorized_for_domain(user, body['tld']):
        return {
            'statusCode': 403,
            'body': json.dumps({
                'Error': f"Not permitted to create addresses on \"{body['tld']}\""
            })
        }
    # Derive the address server-side rather than trusting body['address']: it is
    # the DynamoDB primary key and the value user_authorized_for_sender matches
    # on, so it must equal the real routing identity, not an arbitrary client
    # string. username/subdomain/tld are all validated above.
    address = f"{body['username']}@{body['subdomain']}.{body['tld']}"
    try:
        publish_address_dns_records(
            domains[body['tld']], body['subdomain'], body['tld'], control_domain)
        record_address(user, body, address)
        notify_containers()
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f"Error creating address {address}: {err}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'address': address,
                'error': str(err)
            })
        }
    return {
        'statusCode': 201,
        'body': json.dumps({
            'address': address
        })
    }


def record_address(user, body, address):
    '''Records the new address in DynamoDB'''
    item = {
        'address': address,
        'tld': body['tld'],
        'user': user,
        'username': body['username'],
        'subdomain': body['subdomain'],
        'comment': body.get('comment', ''),
        'RequestTime': datetime.now(timezone.utc).isoformat()
    }
    # Eager-create support for the browser extension
    # (docs/1.x/browser-extension-plan.md, Phase 3.1.a): a pending address is
    # fully provisioned (DNS, sendmail maps) but unconfirmed. It is confirmed
    # by /confirm_address or by mail arriving (the imap tier's procmail hook),
    # and revoked by the reap_pending_addresses TTL reaper otherwise. Absent
    # or false means a normal, immediately-confirmed address, so existing
    # clients are unaffected.
    if body.get('pending') is True:
        item['pending'] = True
        item['pending_since'] = item['RequestTime']
    table.put_item(Item=item)
