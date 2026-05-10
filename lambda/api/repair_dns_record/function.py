'''Publishes (UPSERTs) the DKIM or SPF record for a managed subdomain (admin only)'''
import json
import os
import boto3  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']

r53 = boto3.client('route53')


def admin_check(event):
    '''Returns a 403 response when the caller lacks the admin group'''
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    return None


def find_managed_apex(domain):
    '''Returns the managed apex (and zone id) that owns `domain`, or (None, None)'''
    domain = (domain or '').lower().rstrip('.')
    best = None
    for apex, zone_id in domains.items():
        apex_lower = apex.lower()
        if domain == apex_lower or domain.endswith('.' + apex_lower):
            if best is None or len(apex_lower) > len(best[0]):
                best = (apex_lower, zone_id)
    if best is None:
        return (None, None)
    return best


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


def handler(event, _context):
    '''Publishes the linking DKIM or SPF record for a managed subdomain'''
    denial = admin_check(event)
    if denial:
        return denial
    try:
        body = json.loads(event.get('body') or '{}')
    except json.JSONDecodeError:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'Invalid JSON body'})
        }
    domain = (body.get('domain') or '').strip().lower().rstrip('.')
    record_type = (body.get('record_type') or '').strip().lower()
    if not domain or record_type not in ('dkim', 'spf'):
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'domain and record_type (dkim|spf) are required'})
        }

    apex, zone_id = find_managed_apex(domain)
    if not apex:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': f'{domain} is not managed by Cabal'})
        }
    if domain == apex:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'Apex records are not configured by design'})
        }

    if record_type == 'dkim':
        rtype = 'CNAME'
        name = f'cabal._domainkey.{domain}'
        value = f'cabal._domainkey.{control_domain}'
    else:
        rtype = 'TXT'
        name = domain
        value = f'"v=spf1 include:{control_domain} ~all"'

    try:
        upsert_record(zone_id, name, value, rtype)
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'Failed to upsert {rtype} {name}: {err}')
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }

    return {
        'statusCode': 200,
        'body': json.dumps({
            'domain': domain,
            'record_type': record_type,
            'published': {
                'type': rtype,
                'name': name,
                'value': value
            }
        })
    }
