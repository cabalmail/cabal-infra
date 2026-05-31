'''Checks for the presence of a BIMI record and returns the image URL if found'''
import json
import time
import dns.exception # pylint: disable=import-error
import dns.resolver # pylint: disable=import-error
from helper import validate_dns_apex # pylint: disable=import-error

# Total wall-clock budget across all BIMI lookups for one request, so a slow or
# hostile authoritative NS for the queried domain cannot pin the Lambda for its
# whole timeout (Phase 4 of docs/0.10.x/application-surface-hardening-plan.md).
DNS_TOTAL_BUDGET_SECONDS = 5.0


def _resolver():
    '''A resolver bounded per the plan: lifetime caps total time across retries
    for a single query, timeout caps one query.'''
    resolver = dns.resolver.Resolver()
    resolver.lifetime = 5
    resolver.timeout = 2
    return resolver


def handler(event, _context):
    '''Checks for the presence of a BIMI record and returns the image URL if found'''
    query_string = event.get('queryStringParameters') or {}
    try:
        sender_domain = validate_dns_apex(query_string.get('sender_domain'))
    except ValueError as err:
        return {
            "statusCode": 400,
            "body": json.dumps({"status": f"Invalid input: {err}"})
        }
    sender_domain_parts = sender_domain.split(".")
    length = len(sender_domain_parts)
    resolver = _resolver()
    # Bound the per-suffix walk too: lifetime is per-query, so without a deadline
    # a many-label name could multiply it. Stop once the total budget is spent.
    deadline = time.monotonic() + DNS_TOTAL_BUDGET_SECONDS
    for part in range(length):
        if time.monotonic() >= deadline:
            break
        domain = ".".join(sender_domain_parts[part:])
        try:
            answer = resolver.resolve(f'default._bimi.{domain}', 'TXT')
            return {
                "statusCode": 200,
                "body": json.dumps({
                    "url": str(answer[0]).split(";")[1].split("=")[1]
                })
            }
        except (dns.resolver.NXDOMAIN, dns.resolver.NoAnswer):
            continue
        except dns.exception.DNSException:
            # Timeout or other resolver error: a slower NS won't get faster as
            # we climb the suffixes, so stop and fall back rather than 500.
            break

    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": f'https://www.{".".join(sender_domain_parts[length-2:])}/favicon.ico'
        })
    }
