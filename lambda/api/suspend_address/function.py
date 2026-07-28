'''Suspends an email address: removes its DNS records while keeping the
address in DynamoDB and the mail-tier runtime configuration, so it can be
reinstated later'''
# pylint: disable=duplicate-code
import json
import os
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error
from helper import delete_address_dns_records  # pylint: disable=import-error
from helper import parse_json_body  # pylint: disable=import-error
from helper import user_authorized_for_sender  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')


def handler(event, _context):
    '''Suspends an email address'''
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
    # Like revoke, take subdomain/tld/zone from the STORED row, never from the
    # request body: authorization above is on `address` only, so honoring a
    # client-supplied subdomain/tld would let a caller who owns any one address
    # delete another user's DNS records.
    item = table.get_item(Key={'address': address}).get('Item') or {}
    if item.get('suspended'):
        return {
            'statusCode': 200,
            'body': json.dumps({
                'status': 'success',
                'address': address,
                'suspended': True
            })
        }
    subdomain = item.get('subdomain')
    tld = item.get('tld')
    # The zone is resolved from DOMAINS, never from the zone-id cached on the
    # row: that value is a snapshot from address-creation time that goes stale
    # if a hosted zone is ever recreated (legacy rows pointed at zones that no
    # longer exist, failing Route 53 calls with NoSuchHostedZone). For a tld no
    # longer in DOMAINS this resolves to None and the DNS step is skipped --
    # the Lambda role's Route 53 grant only covers managed zones anyway.
    zone_id = domains.get(tld)
    try:
        # DNS records are shared by every address on the subdomain, so only
        # remove them when no other ACTIVE (non-suspended) address needs them.
        if subdomain and tld and zone_id and \
                not active_addresses_on_subdomain(subdomain, tld, address):
            delete_address_dns_records(zone_id, subdomain, tld, control_domain)
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


def active_addresses_on_subdomain(subdomain, tld, address):
    '''Checks if other non-suspended addresses share the same subdomain and TLD'''
    scan_kwargs = {
        'FilterExpression': (
            'subdomain = :sub AND tld = :tld AND address <> :addr '
            'AND (attribute_not_exists(#s) OR #s = :false)'
        ),
        'ExpressionAttributeNames': {'#s': 'suspended'},
        'ExpressionAttributeValues': {
            ':sub': subdomain,
            ':tld': tld,
            ':addr': address,
            ':false': False
        },
        'ProjectionExpression': 'address'
    }
    while True:
        response = table.scan(**scan_kwargs)
        if response.get('Items'):
            return True
        if 'LastEvaluatedKey' not in response:
            break
        scan_kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
    return False


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
