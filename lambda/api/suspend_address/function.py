'''Suspends an email address: removes its DNS records while keeping the
address in DynamoDB and the mail-tier runtime configuration, so it can be
reinstated later'''
# pylint: disable=duplicate-code
import json
import os
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error
from helper import authorized_address_request  # pylint: disable=import-error
from helper import teardown_address_dns_if_unused  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Suspends an email address'''
    address, item, error = authorized_address_request(event)
    if error:
        return error
    if item.get('suspended'):
        return {
            'statusCode': 200,
            'body': json.dumps({
                'status': 'success',
                'address': address,
                'suspended': True
            })
        }
    try:
        # Row-sourced subdomain/tld, DOMAINS-sourced zone, and the co-tenant
        # guard all live in the shared teardown (see its docstring for the
        # authorization and stale-zone-id rationale).
        teardown_address_dns_if_unused(item, address, domains, control_domain)
        mark_suspended(address)
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f"Error suspending address {address}: {err}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'Error': str(err)
            })
        }
    return {
        'statusCode': 200,
        'body': json.dumps({
            'status': 'success',
            'address': address,
            'suspended': True
        })
    }


def mark_suspended(address):
    '''Marks the address suspended in DynamoDB'''
    table.update_item(
        Key={'address': address},
        UpdateExpression='SET #s = :true, SuspendTime = :now',
        ExpressionAttributeNames={'#s': 'suspended'},
        ExpressionAttributeValues={
            ':true': True,
            ':now': datetime.now(timezone.utc).isoformat()
        }
    )
