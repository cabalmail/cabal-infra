'''REQUEST authorizer for /mcp: admits a request carrying a live agent grant.

Phase A of docs/1.x/agent-mail-access-plan.md. Every other API route uses the
Cognito authorizer; this one exists because an AI assistant holds a
revocable, scope-limited credential instead of the user's Cognito session.

The request must carry `Authorization: Bearer <token>`, and the token is one
of two kinds:

- A minted grant token, `cbl_agt_...`. It is hashed and looked up; an unknown,
  revoked or expired grant is refused.
- A Cognito access token from the OAuth sign-in claude.ai's custom connectors
  run (agent_oauth.py). It is verified against the pool's signing keys and
  must have been issued to the MCP app client with the MCP read scope. Phase A
  grants it what a minted grant gets: read-only, INBOX only.

Anything else, or a token that fails its check, is refused with 401
("Unauthorized" is the one exception message API Gateway turns into a 401
rather than a 500; the gateway response in mcp.tf adds the header that tells
an OAuth client where to sign in). A live credential yields an Allow for the
method being called, with the grant's identity and scope in the context the
/mcp Lambda reads. API Gateway is configured not to cache the result, so
revoking a minted grant takes effect on the next request.
'''
import time
from agent_grants import ( # pylint: disable=import-error
    ACCESS_READ_ONLY,
    MINTABLE_FOLDERS,
    grants_table,
    is_live,
    is_token_shaped,
    token_hash,
)
from agent_oauth import ( # pylint: disable=import-error
    TokenRejected,
    looks_like_jwt,
    oauth_config,
    session_id,
    verify_access_token,
)

# Write last_used_at at most this often per grant, so a busy agent costs one
# write a minute rather than one per request. The value is therefore accurate
# to the minute, which is all the user's "last used" column needs.
LAST_USED_RESOLUTION_SECONDS = 60


def handler(event, _context):
    '''Returns an IAM policy admitting the request, or raises Unauthorized.'''
    token = bearer_token(event)
    if token is not None and is_token_shaped(token):
        return grant_policy(event, token)
    if token is not None and looks_like_jwt(token):
        return oauth_policy(event, token)
    raise Exception('Unauthorized')  # pylint: disable=broad-exception-raised


def grant_policy(event, token):
    '''Admits a minted cbl_agt_ token whose grant is live.'''
    hashed = token_hash(token)
    item = grants_table().get_item(Key={'token_hash': hashed}).get('Item')
    now = int(time.time())
    if not is_live(item, now):
        print(f'[authorize_agent] refused grant_id={hashed[:16]} '
              f'reason={"unknown" if not item else "revoked or expired"}')
        raise Exception('Unauthorized')  # pylint: disable=broad-exception-raised
    record_use(hashed, now)
    # Context values must be strings, numbers or booleans, so the folder
    # set travels comma-joined; folder names cannot contain a comma
    # (helper._FOLDER_NAME_RE).
    return allow(event, item['user'], {
        'user': item['user'],
        'grant_id': item['grant_id'],
        'access': item['access'],
        'folders': ','.join(sorted(item.get('folders') or [])),
    })


def oauth_policy(event, token):
    '''Admits a Cognito access token from the MCP OAuth sign-in. Its scope is
    fixed rather than per grant: Phase A's read-only, INBOX-only.'''
    config = oauth_config()
    if config is None:
        print('[authorize_agent] refused oauth token reason=oauth not configured')
        raise Exception('Unauthorized')  # pylint: disable=broad-exception-raised
    try:
        claims = verify_access_token(token, config, int(time.time()))
    except TokenRejected as err:
        print(f'[authorize_agent] refused oauth token reason={err}')
        raise Exception('Unauthorized') from err  # pylint: disable=broad-exception-raised
    return allow(event, claims['username'], {
        'user': claims['username'],
        'grant_id': session_id(claims),
        'access': ACCESS_READ_ONLY,
        'folders': ','.join(sorted(MINTABLE_FOLDERS)),
    })


def allow(event, principal, context):
    '''An Allow policy for the method being called, carrying `context`.'''
    return {
        'principalId': principal,
        'policyDocument': {
            'Version': '2012-10-17',
            'Statement': [{
                'Action': 'execute-api:Invoke',
                'Effect': 'Allow',
                'Resource': event['methodArn'],
            }],
        },
        'context': context,
    }


def bearer_token(event):
    '''The bearer credential from the Authorization header, or None. Its kind
    is the caller's to check.'''
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
    return token.strip() or None


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
