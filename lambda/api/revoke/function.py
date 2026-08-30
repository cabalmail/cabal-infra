'''Revokes an email address'''
# pylint: disable=duplicate-code
import json
import os
import boto3  # pylint: disable=import-error
from address_events import notify_containers  # pylint: disable=import-error
from helper import authorized_address_request  # pylint: disable=import-error
from helper import teardown_address_dns_if_unused  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Revokes an email address'''
    address, item, error = authorized_address_request(event)
    if error:
        return error
    try:
        # Row-sourced subdomain/tld, DOMAINS-sourced zone, and the co-tenant
        # guard all live in the shared teardown (see its docstring for the
        # authorization and stale-zone-id rationale).
        teardown_address_dns_if_unused(item, address, domains, control_domain)
        revoke_address(address)
        notify_containers()
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f"Error revoking address {address}: {err}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'Error': str(err)
            })
        }
    return {
        'statusCode': 202,
        'body': json.dumps({
            'status': 'success',
            'address': address
        })
    }


def revoke_address(address):
    '''Deletes the address from DynamoDB'''
    table.delete_item(Key={'address': address})
