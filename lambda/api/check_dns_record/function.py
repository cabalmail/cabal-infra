'''Verifies the DKIM or SPF DNS record published for a domain (admin only)'''
import json
import os
import dns.exception  # pylint: disable=import-error
import dns.resolver  # pylint: disable=import-error
from helper import ( # pylint: disable=import-error
    admin_response_or_none,
    find_managed_apex,
    validate_dns_apex,
)

DOMAINS = json.loads(os.environ['DOMAINS'])
CONTROL_DOMAIN = os.environ['CONTROL_DOMAIN']

# Bound DNS lookups so a slow or hostile authoritative NS for the queried
# domain cannot pin the Lambda for its whole timeout (Phase 4 of
# docs/0.10.x/application-surface-hardening-plan.md). lifetime caps total time
# across retries; timeout caps a single query.
_RESOLVER = dns.resolver.Resolver()
_RESOLVER.lifetime = 5
_RESOLVER.timeout = 2


def expected_record(record_type, domain):
    '''Returns the expected (type, name, value) tuple for the record'''
    domain = domain.rstrip('.')
    if record_type == 'dkim':
        return ('CNAME', f'cabal._domainkey.{domain}', f'cabal._domainkey.{CONTROL_DOMAIN}')
    if record_type == 'spf':
        return ('TXT', domain, f'v=spf1 include:{CONTROL_DOMAIN} ~all')
    raise ValueError(f'Unsupported record_type: {record_type}')


def lookup(name, rdtype):
    '''Looks up a DNS record. Returns a list of values (strings) or None on NXDOMAIN.'''
    try:
        answers = _RESOLVER.resolve(name, rdtype, raise_on_no_answer=False)
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
        wanted = expected_value.lower().rstrip('.')
        return wanted in [v.lower().rstrip('.') for v in actual_values]
    if record_type == 'spf':
        return any(v.strip() == expected_value for v in actual_values)
    return False


def summarise_actual(actual):
    '''Normalises a lookup() return into the API response shape'''
    if actual is None:
        return {'status': 'nxdomain', 'values': []}
    if not actual:
        return {'status': 'no_records', 'values': []}
    return {'status': 'found', 'values': actual}


def parse_request(event):
    '''Returns ((domain, record_type), None) on success or (None, error_response).'''
    params = event.get('queryStringParameters') or {}
    domain = (params.get('domain') or '').strip().lower().rstrip('.')
    record_type = (params.get('record_type') or '').strip().lower()
    if not domain or record_type not in ('dkim', 'spf'):
        return (None, {
            'statusCode': 400,
            'body': json.dumps({'Error': 'domain and record_type (dkim|spf) are required'})
        })
    try:
        validate_dns_apex(domain)
    except ValueError as err:
        return (None, {
            'statusCode': 400,
            'body': json.dumps({'Error': f'Invalid domain: {err}'})
        })
    return ((domain, record_type), None)


def handler(event, _context):
    '''Checks the DKIM or SPF record published for a domain'''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    parsed, err = parse_request(event)
    if err:
        return err
    domain, record_type = parsed

    apex, _zone_id = find_managed_apex(DOMAINS, domain)
    managed = apex is not None
    is_apex = managed and domain == apex

    rtype, name, expected = expected_record(record_type, domain)
    actual = lookup(name, rtype)
    is_match = matches(record_type, expected, actual or [])

    return {
        'statusCode': 200,
        'body': json.dumps({
            'domain': domain,
            'record_type': record_type,
            'managed': managed,
            'managed_apex': apex or '',
            'is_apex': is_apex,
            'expected': {'type': rtype, 'name': name, 'value': expected},
            'actual': summarise_actual(actual),
            'matches': is_match,
            'repairable': managed and not is_apex and not is_match
        })
    }
