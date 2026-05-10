'''Verifies the DKIM or SPF DNS record published for a domain (admin only)'''
import json
import os
import dns.exception  # pylint: disable=import-error
import dns.resolver  # pylint: disable=import-error

domains = json.loads(os.environ['DOMAINS'])
control_domain = os.environ['CONTROL_DOMAIN']


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


def expected_record(record_type, domain):
    '''Returns the expected (type, name, value) tuple for the record'''
    domain = domain.rstrip('.')
    if record_type == 'dkim':
        return ('CNAME', f'cabal._domainkey.{domain}', f'cabal._domainkey.{control_domain}')
    if record_type == 'spf':
        return ('TXT', domain, f'v=spf1 include:{control_domain} ~all')
    raise ValueError(f'Unsupported record_type: {record_type}')


def lookup(name, rdtype):
    '''Looks up a DNS record. Returns a list of values (strings) or None on NXDOMAIN.'''
    try:
        answers = dns.resolver.resolve(name, rdtype, raise_on_no_answer=False)
    except dns.resolver.NXDOMAIN:
        return None
    except (dns.resolver.NoAnswer, dns.exception.DNSException):
        return []
    values = []
    for rdata in answers:
        if rdtype == 'TXT':
            chunks = [c.decode('utf-8', errors='replace') if isinstance(c, bytes) else c
                      for c in rdata.strings]
            values.append(''.join(chunks))
        elif rdtype == 'CNAME':
            values.append(str(rdata.target).rstrip('.').lower())
        else:
            values.append(str(rdata))
    return values


def matches(record_type, expected_value, actual_values):
    '''Determines whether the actual record set matches the expected value'''
    if not actual_values:
        return False
    if record_type == 'dkim':
        return expected_value.lower().rstrip('.') in [v.lower().rstrip('.') for v in actual_values]
    if record_type == 'spf':
        return any(v.strip() == expected_value for v in actual_values)
    return False


def handler(event, _context):
    '''Checks the DKIM or SPF record published for a domain'''
    denial = admin_check(event)
    if denial:
        return denial
    params = event.get('queryStringParameters') or {}
    domain = (params.get('domain') or '').strip().lower().rstrip('.')
    record_type = (params.get('record_type') or '').strip().lower()
    if not domain or record_type not in ('dkim', 'spf'):
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'domain and record_type (dkim|spf) are required'})
        }

    apex, _zone_id = find_managed_apex(domain)
    managed = apex is not None
    is_apex = managed and domain == apex

    rtype, name, expected = expected_record(record_type, domain)
    actual = lookup(name, rtype)

    if actual is None:
        actual_status = 'nxdomain'
        actual_values = []
    elif not actual:
        actual_status = 'no_records'
        actual_values = []
    else:
        actual_status = 'found'
        actual_values = actual

    is_match = matches(record_type, expected, actual or [])
    repairable = managed and not is_apex and not is_match

    return {
        'statusCode': 200,
        'body': json.dumps({
            'domain': domain,
            'record_type': record_type,
            'managed': managed,
            'managed_apex': apex or '',
            'is_apex': is_apex,
            'expected': {
                'type': rtype,
                'name': name,
                'value': expected
            },
            'actual': {
                'status': actual_status,
                'values': actual_values
            },
            'matches': is_match,
            'repairable': repairable
        })
    }
