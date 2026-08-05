'''Admin-endpoint gate: group authorization, rate limiting, and audit logging.

Phase 5 of docs/0.10.x/application-surface-hardening-plan.md. Deliberately
depends on only boto3 (provided by the Lambda runtime) and the standard
library, so the admin user-management handlers can adopt it without pulling in
helper.py's imapclient / dnspython imports or its module-load master-password
fetch. The admin-group check lives here rather than in helper.py for the same
reason: most admin handlers import nothing heavier than boto3, and the guard is
the first thing every one of them runs.
'''
import json
import time
import boto3  # pylint: disable=import-error

RATE_LIMIT_TABLE = 'cabal-rate-limits'
# Ceiling per caller per window. The plan's target is 30 mutations / minute.
RATE_LIMIT_MAX = 30
RATE_LIMIT_WINDOW_SECONDS = 60

_ddb = boto3.resource('dynamodb')
_rate_limit_table = _ddb.Table(RATE_LIMIT_TABLE)


def is_admin(groups_claim):
    '''True when the caller's `cognito:groups` claim contains the exact `admin`
    group. The claim is a serialized list -- API Gateway may render it as
    "admin", "admin,users", or "[admin users]" -- so we split on commas and
    whitespace and match a whole element. A substring test (`'admin' in claim`)
    would wrongly admit any group whose name merely contains "admin"
    (e.g. "admin-readonly", "nonadmin").'''
    members = (groups_claim or '').strip('[]').replace(',', ' ').split()
    return 'admin' in members


def admin_response_or_none(event):
    """Returns a 403 response when the caller lacks the admin group, else None"""
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if not is_admin(groups):
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    return None


def audit_log(caller, action, target, outcome):
    '''Emits one structured JSON audit line for an admin mutation.

    The AUDIT prefix makes the lines greppable; the JSON body
    (caller, action, target, outcome) is queryable in CloudWatch Logs Insights.
    '''
    print('AUDIT ' + json.dumps({
        'caller': caller,
        'action': action,
        'target': target,
        'outcome': outcome,
    }, sort_keys=True))


def check_rate_limit(caller, limit=RATE_LIMIT_MAX, window=RATE_LIMIT_WINDOW_SECONDS):
    '''Fixed-window per-caller counter in cabal-rate-limits.

    Atomically records this request and returns True when the caller is within
    `limit` for the current window, False when the ceiling is exceeded. Fails
    OPEN on any error (including a not-yet-created table) so a storage problem
    can never lock admins out of account management.
    '''
    now = int(time.time())
    window_id = now // window
    key = f'{caller}#{window_id}'
    # TTL two windows out so a stale counter cannot linger after the window ends.
    expires_at = (window_id + 2) * window
    try:
        resp = _rate_limit_table.update_item(
            Key={'pk': key},
            UpdateExpression='SET expires_at = :exp ADD #n :one',
            ExpressionAttributeNames={'#n': 'count'},
            ExpressionAttributeValues={':one': 1, ':exp': expires_at},
            ReturnValues='UPDATED_NEW',
        )
        count = int(resp['Attributes']['count'])
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'[rate-limit] WARN fail-open for {caller!r}: {err}')
        return True
    return count <= limit


def rate_limit_response_or_none(caller, action):
    '''Returns a 429 response (after emitting one rate_limited audit line) when
    `caller` has exceeded the admin-mutation ceiling, else None.'''
    if check_rate_limit(caller):
        return None
    audit_log(caller, action, '', 'rate_limited')
    return {
        'statusCode': 429,
        'body': json.dumps({'Error': 'Rate limit exceeded; slow down and retry shortly'})
    }
