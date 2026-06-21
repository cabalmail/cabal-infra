'''Creates a new email address'''
# pylint: disable=duplicate-code,too-many-return-statements
import json
import os
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error
from helper import assert_zone_owns_apex  # pylint: disable=import-error
from helper import parse_json_body  # pylint: disable=import-error
from helper import user_authorized_for_domain  # pylint: disable=import-error
from helper import validate_dns_apex  # pylint: disable=import-error
from helper import validate_dns_subdomain  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']
address_changed_topic_arn = os.environ.get('ADDRESS_CHANGED_TOPIC_ARN', '')

# Subdomains reserved on the control domain. When the control domain doubles as
# a mail domain (it appears in mail_domains), these labels already carry
# infrastructure records in the control zone: CloudFront/NLB aliases (admin,
# www, imap, smtp, smtp-in, smtp-out), the system mail user (mail-admin), and
# the DKIM/DMARC selectors (cabal._domainkey, _dmarc). An address record at one
# of these names would either fail (Route 53 rejects an MX/TXT alongside an
# existing CNAME) or clobber an auth record (an SPF TXT UPSERT would overwrite
# the apex DKIM/DMARC TXT). These collisions only exist on the control domain;
# dedicated mail domains have no such records, so the guard is scoped to it.
RESERVED_CONTROL_SUBDOMAINS = frozenset({
    'admin', 'www', 'imap', 'smtp', 'smtp-in', 'smtp-out', 'mail-admin',
    'cabal._domainkey', '_dmarc',
})

r53 = boto3.client('route53')
ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')
sns = boto3.client('sns')


def handler(event, _context):
    '''Creates a new email address'''
    body, error = parse_json_body(event)
    if error:
        return error
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    if body['tld'] not in domains:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': f"Unknown domain \"{body['tld']}\""})
        }
    try:
        validate_dns_apex(body['tld'])
        validate_dns_subdomain(body['subdomain'])
    except ValueError as err:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': f'Invalid input: {err}'})
        }
    if body['tld'] == control_domain and \
            body['subdomain'].lower().rstrip('.') in RESERVED_CONTROL_SUBDOMAINS:
        return {
            'statusCode': 400,
            'body': json.dumps({
                'Error': (
                    f"Subdomain \"{body['subdomain']}\" is reserved on the "
                    f"control domain \"{control_domain}\""
                )
            })
        }
    if not user_authorized_for_domain(user, body['tld']):
        return {
            'statusCode': 403,
            'body': json.dumps({
                'Error': f"Not permitted to create addresses on \"{body['tld']}\""
            })
        }
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
    assert_zone_owns_apex(zone_id, tld)
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
