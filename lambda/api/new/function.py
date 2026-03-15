'''Creates a new email address'''
# pylint: disable=duplicate-code
import json
import os
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']
address_changed_topic_arn = os.environ.get('ADDRESS_CHANGED_TOPIC_ARN', '')

r53 = boto3.client('route53')
ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')
sns = boto3.client('sns')


def handler(event, _context):
    '''Creates a new email address'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        create_dns_records(domains[body['tld']], body['subdomain'], body['tld'])
        record_address(user, body)
        notify_containers()
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f"Error creating address {body['address']}: {err}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'address': body['address'],
                'error': str(err)
            })
        }
    return {
        'statusCode': 201,
        'body': json.dumps({
            'address': body['address']
        })
    }


def change_item(name, value, record_type):
    '''Builds a Route 53 UPSERT change item'''
    return {
        'Action': 'UPSERT',
        'ResourceRecordSet': {
            'Name': name,
            'ResourceRecords': [{'Value': value}],
            'TTL': 3600,
            'Type': record_type
        }
    }


def create_dns_records(zone_id, subdomain, tld):
    '''Creates the DNS records for a new email address'''
    params = {
        'HostedZoneId': zone_id,
        'ChangeBatch': {
            'Changes': [
                change_item(
                    f'_dmarc.{subdomain}.{tld}',
                    f'_dmarc.{control_domain}', 'CNAME'),
                change_item(
                    f'{subdomain}.{tld}',
                    f'"v=spf1 include:{control_domain} ~all"', 'TXT'),
                change_item(
                    f'{subdomain}.{tld}',
                    f'10 smtp-in.{control_domain}', 'MX'),
                change_item(
                    f'cabal._domainkey.{subdomain}.{tld}',
                    f'cabal._domainkey.{control_domain}', 'CNAME'),
            ]
        }
    }
    r53.change_resource_record_sets(**params)


def record_address(user, body):
    '''Records the new address in DynamoDB'''
    table.put_item(Item={
        'address': body['address'],
        'tld': body['tld'],
        'user': user,
        'username': body['username'],
        'zone-id': domains[body['tld']],
        'subdomain': body['subdomain'],
        'comment': body.get('comment', ''),
        'RequestTime': datetime.now(timezone.utc).isoformat()
    })


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
