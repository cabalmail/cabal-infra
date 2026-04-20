'''Creates a new email address assigned to one or more users (admin only)'''
# pylint: disable=duplicate-code
import json
import os
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']
address_changed_topic_arn = os.environ.get('ADDRESS_CHANGED_TOPIC_ARN', '')
user_pool_id = os.environ['USER_POOL_ID']

r53 = boto3.client('route53')
ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')
sns = boto3.client('sns')
cognito = boto3.client('cognito-idp')


def handler(event, _context):
    '''Creates a new email address assigned to one or more users'''
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    body = json.loads(event['body'])
    usernames = body.get('usernames') or []
    if not usernames:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'At least one username is required'})
        }
    try:
        for username in usernames:
            if not cognito_user_exists(username):
                return {
                    'statusCode': 400,
                    'body': json.dumps({'Error': f'User "{username}" does not exist'})
                }
        create_dns_records(domains[body['tld']], body['subdomain'], body['tld'])
        record_address(usernames, body)
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
            'address': body['address'],
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


def record_address(usernames, body):
    '''Records the new address in DynamoDB'''
    table.put_item(Item={
        'address': body['address'],
        'tld': body['tld'],
        'user': '/'.join(usernames),
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
