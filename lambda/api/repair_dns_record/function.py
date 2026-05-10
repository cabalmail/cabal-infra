'''Publishes (UPSERTs) the DKIM or SPF record for a managed subdomain (admin only)'''
import json
import os
import boto3  # pylint: disable=import-error
from helper import admin_response_or_none, find_managed_apex  # pylint: disable=import-error

DOMAINS = json.loads(os.environ['DOMAINS'])
CONTROL_DOMAIN = os.environ['CONTROL_DOMAIN']

r53 = boto3.client('route53')


def upsert_record(zone_id, name, value, record_type):
    '''Issues a Route 53 UPSERT for the given record'''
    r53.change_resource_record_sets(
        HostedZoneId=zone_id,
        ChangeBatch={
            'Changes': [{
                'Action': 'UPSERT',
                'ResourceRecordSet': {
                    'Name': name,
                    'Type': record_type,
                    'TTL': 3600,
                    'ResourceRecords': [{'Value': value}]
                }
            }]
        }
    )


def record_for(record_type, domain):
    '''Returns the (type, name, value) tuple to publish for the linking record'''
    if record_type == 'dkim':
        return ('CNAME', f'cabal._domainkey.{domain}', f'cabal._domainkey.{CONTROL_DOMAIN}')
    return ('TXT', domain, f'"v=spf1 include:{CONTROL_DOMAIN} ~all"')


def _err(status, message):
    '''Builds a JSON error response'''
    return {'statusCode': status, 'body': json.dumps({'Error': message})}


def validate(event):
    '''Returns ((domain, record_type, zone_id), None) or (None, error_response).'''
    try:
        body = json.loads(event.get('body') or '{}')
    except json.JSONDecodeError:
        return (None, _err(400, 'Invalid JSON body'))
    domain = (body.get('domain') or '').strip().lower().rstrip('.')
    record_type = (body.get('record_type') or '').strip().lower()
    if not domain or record_type not in ('dkim', 'spf'):
        return (None, _err(400, 'domain and record_type (dkim|spf) are required'))
    apex, zone_id = find_managed_apex(DOMAINS, domain)
    if not apex:
        return (None, _err(400, f'{domain} is not managed by Cabal'))
    if domain == apex:
        return (None, _err(400, 'Apex records are not configured by design'))
    return ((domain, record_type, zone_id), None)


def handler(event, _context):
    '''Publishes the linking DKIM or SPF record for a managed subdomain'''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    parsed, err = validate(event)
    if err:
        return err
    domain, record_type, zone_id = parsed
    rtype, name, value = record_for(record_type, domain)
    try:
        upsert_record(zone_id, name, value, rtype)
    except Exception as ex:  # pylint: disable=broad-exception-caught
        print(f'Failed to upsert {rtype} {name}: {ex}')
        return _err(500, str(ex))
    return {
        'statusCode': 200,
        'body': json.dumps({
            'domain': domain,
            'record_type': record_type,
            'published': {'type': rtype, 'name': name, 'value': value}
        })
    }
