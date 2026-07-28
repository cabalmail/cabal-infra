'''Revokes an email address'''
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
address_changed_topic_arn = os.environ.get('ADDRESS_CHANGED_TOPIC_ARN', '')

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')
sns = boto3.client('sns')


def handler(event, _context):
    '''Revokes an email address'''
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
    # Take subdomain/tld/zone from the STORED row for `address`, never from the
    # request body. Authorization above is on `address` only, so honoring a
    # client-supplied subdomain/tld would let a caller who owns any one address
    # delete another user's DNS records: delete_dns_records targets
    # `{subdomain}.{tld}`, and the co-tenant guard (other_addresses_on_subdomain)
    # returns False for a single-tenant victim subdomain, so the DELETE would
    # proceed. The caller owns `address`, so its row is the authoritative source.
    item = table.get_item(Key={'address': address}).get('Item') or {}
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
        # Only ACTIVE (non-suspended) co-tenants keep the records alive: a
        # suspended address's contract is already "DNS absent", so it must not
        # block the delete (reinstate republishes the records if it comes back).
        if subdomain and tld and zone_id and \
                not active_addresses_on_subdomain(subdomain, tld, address):
            delete_address_dns_records(zone_id, subdomain, tld, control_domain)
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


def revoke_address(address):
    '''Deletes the address from DynamoDB'''
    table.delete_item(Key={'address': address})


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
