'''Reinstates a suspended email address: republishes its DNS records and
clears the suspended flag in DynamoDB'''
# pylint: disable=duplicate-code
import json
import os
import boto3  # pylint: disable=import-error
from helper import parse_json_body  # pylint: disable=import-error
from helper import publish_address_dns_records  # pylint: disable=import-error
from helper import user_authorized_for_sender  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Reinstates a suspended email address'''
    body, error = parse_json_body(event)
    if error:
        return error
    address = body['address']
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    if not user_authorized_for_sender(user, address):
        return {
            'statusCode': 403,
            'body': json.dumps({
                'Error': 'Address not associated with authenticated user'
            })
        }
    item = table.get_item(Key={'address': address}).get('Item') or {}
    if not item.get('suspended'):
        return {
            'statusCode': 200,
            'body': json.dumps({
                'status': 'success',
                'address': address,
                'suspended': False
            })
        }
    subdomain = item.get('subdomain')
    tld = item.get('tld')
    # DOMAINS wins over the row's cached zone-id: the row value is a snapshot
    # from address-creation time and goes stale if a hosted zone is ever
    # recreated (legacy rows point at zones that no longer exist, which fails
    # Route 53 calls with NoSuchHostedZone). The cached value remains only as
    # a fallback for a tld that has since been dropped from DOMAINS.
    zone_id = domains.get(tld) or item.get('zone-id')
    if not (subdomain and tld and zone_id):
        # Without the stored routing fields the DNS records cannot be
        # republished, and clearing the flag anyway would report an address as
        # live that DNS-wise is not.
        return {
            'statusCode': 500,
            'body': json.dumps({
                'Error': f'Cannot determine DNS zone for {address}'
            })
        }
    try:
        # UPSERTs, so this is idempotent when the records still exist (e.g. an
        # active co-tenant address kept them alive through the suspension).
        publish_address_dns_records(zone_id, subdomain, tld, control_domain)
        clear_suspended(address)
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f"Error reinstating address {address}: {err}")
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
            'suspended': False
        })
    }


def clear_suspended(address):
    '''Clears the suspended flag in DynamoDB'''
    table.update_item(
        Key={'address': address},
        UpdateExpression='REMOVE #s, SuspendTime',
        ExpressionAttributeNames={'#s': 'suspended'}
    )
