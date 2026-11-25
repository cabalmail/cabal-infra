'''REQUEST authorizer for /mcp: admits a request carrying a live agent grant.

Phase A of docs/tentative/agent-mail-access-plan.md. Every other API route uses
the Cognito authorizer; this one exists because an AI assistant holds a
long-lived, revocable, scope-limited grant token instead of the user's Cognito
session.

The request must carry `Authorization: Bearer cbl_agt_...`. The token is
hashed and looked up; a missing, malformed, unknown, revoked or expired token
is refused with 401 ("Unauthorized" is the one exception message API Gateway
turns into a 401 rather than a 500). A live grant yields an Allow for the
method being called, with the grant's identity and scope in the context the
/mcp Lambda reads. API Gateway is configured not to cache the result, so
revocation takes effect on the next request.
'''
import time
from agent_grants import ( # pylint: disable=import-error
    grants_table,
    is_live,
    is_token_shaped,
    token_hash,
)

# Write last_used_at at most this often per grant, so a busy agent costs one
# write a minute rather than one per request. The value is therefore accurate
# to the minute, which is all the user's "last used" column needs.
LAST_USED_RESOLUTION_SECONDS = 60


def handler(event, _context):
    '''Returns an IAM policy admitting the request, or raises Unauthorized.'''
    token = bearer_token(event)
    if token is None:
        raise Exception('Unauthorized')  # pylint: disable=broad-exception-raised
    hashed = token_hash(token)
    item = grants_table().get_item(Key={'token_hash': hashed}).get('Item')
    now = int(time.time())
    if not is_live(item, now):
        print(f'[authorize_agent] refused grant_id={hashed[:16]} '
              f'reason={"unknown" if not item else "revoked or expired"}')
        raise Exception('Unauthorized')  # pylint: disable=broad-exception-raised
    record_use(hashed, now)
    return {
        'principalId': item['user'],
        'policyDocument': {
            'Version': '2012-10-17',
            'Statement': [{
                'Action': 'execute-api:Invoke',
                'Effect': 'Allow',
                'Resource': event['methodArn'],
            }],
        },
        # Context values must be strings, numbers or booleans, so the folder
        # set travels comma-joined; folder names cannot contain a comma
        # (helper._FOLDER_NAME_RE).
        'context': {
            'user': item['user'],
            'grant_id': item['grant_id'],
            'access': item['access'],
            'folders': ','.join(sorted(item.get('folders') or [])),
        },
    }


def bearer_token(event):
    '''The grant token from the Authorization header, or None.'''
    headers = event.get('headers') or {}
    value = None
    for name, header in headers.items():
        if name.lower() == 'authorization':
            value = header
            break
    if not isinstance(value, str):
        return None
    scheme, _, token = value.strip().partition(' ')
    if scheme.lower() != 'bearer':
        return None
    token = token.strip()
    return token if is_token_shaped(token) else None


def record_use(hashed, now):
    '''Best-effort last_used_at update. A failure here never
    refuses a request: the counters are a summary for the user, not a gate.'''
    try:
        grants_table().update_item(
            Key={'token_hash': hashed},
            UpdateExpression='SET last_used_at = :now',
            ConditionExpression='attribute_not_exists(last_used_at) OR last_used_at < :cutoff',
            ExpressionAttributeValues={
                ':now': now,
                ':cutoff': now - LAST_USED_RESOLUTION_SECONDS,
            },
        )
    except Exception:  # pylint: disable=broad-exception-caught
        pass
