'''Revokes an email address'''
# pylint: disable=duplicate-code
import json
import os
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error
from helper import user_authorized_for_sender  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']
address_changed_topic_arn = os.environ.get('ADDRESS_CHANGED_TOPIC_ARN', '')

r53 = boto3.client('route53')
ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')
sns = boto3.client('sns')


def handler(event, _context):
    '''Revokes an email address'''
    body = json.loads(event['body'])
    address = body['address']
    subdomain = body['subdomain']
    tld = body['tld']
    zone_id = domains[tld]
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    if not user_authorized_for_sender(user, address):
        return {
            'statusCode': 403,
            'body': json.dumps({
                'Error': 'Address not associated with authenticated user'
            })
        }
    try:
        if not other_addresses_on_subdomain(subdomain, tld, address):
            delete_dns_records(zone_id, subdomain, tld)
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


def other_addresses_on_subdomain(subdomain, tld, address):
    '''Checks if other addresses share the same subdomain and TLD'''
    response = table.scan(
        FilterExpression='subdomain = :sub AND tld = :tld AND address <> :addr',
        ExpressionAttributeValues={
            ':sub': subdomain,
            ':tld': tld,
            ':addr': address
        },
        ProjectionExpression='address'
    )
    return len(response.get('Items', [])) > 0


def change_item(name, value, record_type):
    '''Builds a Route 53 DELETE change item'''
    return {
        'Action': 'DELETE',
        'ResourceRecordSet': {
            'Name': name,
            'ResourceRecords': [{'Value': value}],
            'TTL': 3600,
            'Type': record_type
        }
    }


def delete_dns_records(zone_id, subdomain, tld):
    '''Deletes the DNS records for an email address'''
    params = {
        'HostedZoneId': zone_id,
        'ChangeBatch': {
            'Changes': [
                change_item(
                    f'{subdomain}.{tld}',
                    f'10 smtp-in.{control_domain}', 'MX'),
                change_item(
                    f'cabal._domainkey.{subdomain}.{tld}',
                    f'cabal._domainkey.{control_domain}', 'CNAME'),
                change_item(
                    f'_dmarc.{subdomain}.{tld}',
                    f'_dmarc.{control_domain}', 'CNAME'),
                change_item(
                    f'{subdomain}.{tld}',
                    f'"v=spf1 include:{control_domain} ~all"', 'TXT'),
            ]
        }
    }
    r53.change_resource_record_sets(**params)


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
