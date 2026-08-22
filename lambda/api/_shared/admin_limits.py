'''Admin-endpoint preamble: group authorization, rate limiting, audit logging,
and request-body parsing.

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


def parse_json_object_body(event):
    '''Parses the request body as a JSON object, returning (body, error).

    On success `error` is None and `body` is the decoded dict; on a missing,
    empty, non-JSON, or non-object body `error` is a ready-to-return 400 and
    `body` is None, so a handler can `return error` instead of relaying an
    unhandled 500 with a traceback.

    Deliberately NOT helper.parse_json_body: that one distinguishes three
    causes in its message text ("request body is required" / "is not valid
    JSON" / "must be a JSON object") while these handlers have always answered
    with the single "is not valid JSON" wording for all three. Unifying them
    would change what a client reads, so the two live side by side until
    someone decides to change the wire response on purpose.
    '''
    try:
        body = json.loads(event.get('body') or '')
    except (TypeError, ValueError):
        body = None
    if not isinstance(body, dict):
        return None, {
            'statusCode': 400,
            'body': json.dumps({'status': 'Invalid input: request body is not valid JSON'})
        }
    return body, None


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


def admin_user_action_response(event, action, status, operate):
    '''Runs one admin user-management mutation end to end and returns its
    response: admin guard, rate limit, JSON-object body, then `operate` on the
    body's `username`, audit-logged either way.

    `operate` is called with the username and its return value is ignored --
    all a handler varies is `action` (the rate-limit and audit name), `status`
    (the word echoed back on success) and the one API call itself.

    Shared by confirm_user, disable_user and enable_user, whose handlers were
    byte-identical apart from those three tokens. delete_user keeps its own
    copy: it refuses a self-delete part way through and purges the user's
    domain-access rows inside the same try, so folding it in would mean a
    second callback that can short-circuit the envelope rather than merely do
    extra work. set_user_domain_access differs further still: it reads a
    three-field body, parses it itself, and reports allowed/denied rather than
    a status word.

    A body carrying no `username` stays a 500 with a failure audit line rather
    than a 400: the KeyError is raised inside the try, exactly where it was
    raised when each handler carried this envelope itself.
    '''
    denial = admin_response_or_none(event)
    if denial:
        return denial
    caller = event['requestContext']['authorizer']['claims']['cognito:username']
    limited = rate_limit_response_or_none(caller, action)
    if limited:
        return limited
    body, invalid = parse_json_object_body(event)
    if invalid:
        return invalid
    username = ''
    try:
        username = body['username']
        operate(username)
    except Exception as err:  # pylint: disable=broad-exception-caught
        audit_log(caller, action, username, 'failure')
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    audit_log(caller, action, username, 'success')
    return {
        'statusCode': 200,
        'body': json.dumps({'status': status, 'username': username})
    }
