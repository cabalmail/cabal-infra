'''Revokes pending (eagerly-created) addresses that were never confirmed.

The floor under the browser extension's eager-create model
(docs/1.x/browser-extension-plan.md, Phase 3.1.c): an address created with
pending=true is confirmed by /confirm_address on form submit or by mail
arriving (the imap tier's procmail hook); if neither happens within
PENDING_TTL_HOURS, this scheduled Lambda revokes it -- the row, the shared
DNS records (when no active co-tenant needs them), and an SNS reconfigure
event so the mail tiers drop it. Scheduled by EventBridge Scheduler; see
terraform/infra/modules/app/reap_pending_addresses.tf. Not an API endpoint.
'''
import json
import os
from datetime import datetime, timedelta, timezone
import boto3  # pylint: disable=import-error
from botocore.exceptions import ClientError  # pylint: disable=import-error
from address_events import notify_containers  # pylint: disable=import-error
from helper import teardown_address_dns_if_unused  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']
PENDING_TTL_HOURS = int(os.environ.get('PENDING_TTL_HOURS', '24'))

ddb = boto3.resource('dynamodb')
table = ddb.Table('cabal-addresses')
cloudwatch = boto3.client('cloudwatch')


def handler(_event, _context):
    '''Scans for expired pending addresses and revokes them'''
    cutoff = (datetime.now(timezone.utc)
              - timedelta(hours=PENDING_TTL_HOURS)).isoformat()
    scanned = 0
    reaped = 0
    # pending_since is written as datetime.isoformat() in UTC, so the
    # lexicographic comparison DynamoDB performs on the strings is also the
    # chronological one.
    scan_kwargs = {
        'FilterExpression': '#p = :true AND pending_since < :cutoff',
        'ExpressionAttributeNames': {'#p': 'pending'},
        'ExpressionAttributeValues': {':true': True, ':cutoff': cutoff},
        'ProjectionExpression': 'address, subdomain, tld'
    }
    while True:
        response = table.scan(**scan_kwargs)
        for item in response.get('Items', []):
            scanned += 1
            if reap_one(item):
                reaped += 1
        if 'LastEvaluatedKey' not in response:
            break
        scan_kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
    if reaped:
        notify_containers()
    emit_metric(reaped)
    print(f'[reap-pending] expired {scanned}, reaped {reaped}, '
          f'ttl {PENDING_TTL_HOURS}h')
    return {
        'statusCode': 200,
        'body': json.dumps({'scanned': scanned, 'reaped': reaped})
    }


def reap_one(item):
    '''Revokes one expired pending address; False if it was confirmed mid-scan.

    The row is deleted first, conditioned on still being pending, so a
    /confirm_address (or procmail clear-on-receive) landing between the scan
    and this delete wins cleanly: the condition fails and the address -- now
    confirmed and possibly already carrying mail -- keeps its DNS records.'''
    address = item['address']
    try:
        table.delete_item(
            Key={'address': address},
            ConditionExpression='#p = :true',
            ExpressionAttributeNames={'#p': 'pending'},
            ExpressionAttributeValues={':true': True}
        )
    except ClientError as err:
        if err.response['Error']['Code'] == 'ConditionalCheckFailedException':
            print(f'[reap-pending] {address} confirmed mid-scan; skipping')
            return False
        raise
    try:
        teardown_address_dns_if_unused(item, address, domains, control_domain)
    except Exception as err:  # pylint: disable=broad-exception-caught
        # The row is already gone, so the address no longer routes; orphaned
        # DNS records are harmless and the next teardown on the subdomain
        # (or a manual pass) removes them. Log and keep reaping.
        print(f'[reap-pending] DNS teardown failed for {address}: {err}')
    print(f'[reap-pending] reaped {address}')
    return True


def emit_metric(reaped):
    '''Emits the PendingAddressesReaped metric; every run, so a zero is
    distinguishable from the reaper not running at all'''
    try:
        cloudwatch.put_metric_data(
            Namespace='Cabalmail',
            MetricData=[{
                'MetricName': 'PendingAddressesReaped',
                'Value': reaped,
                'Unit': 'Count'
            }]
        )
    except Exception as err:  # pylint: disable=broad-exception-caught
        # Observability must not fail the reap itself.
        print(f'[reap-pending] metric emit failed: {err}')
