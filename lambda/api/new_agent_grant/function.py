'''Mints an agent access grant: a bearer token an AI assistant presents to /mcp.

Phase A of docs/1.x/agent-mail-access-plan.md. The plaintext token is in
this response and nowhere else; the table keeps only its SHA-256.

Body (all optional): `label` (required in practice, e.g. "Claude on my
laptop"), `expires_in_days` (1-365, default 90), `folders` (Phase A: only
["INBOX"]), `access` (Phase A: only "read_only").
'''
import time
from agent_grants import ( # pylint: disable=import-error
    MAX_ACTIVE_GRANTS,
    caller,
    grant_id_for,
    grants_table,
    is_live,
    json_object_body,
    new_token,
    public_view,
    response,
    token_hash,
    user_grants,
    validate_access,
    validate_expiry_days,
    validate_folders,
    validate_label,
)


def handler(event, _context):
    '''Mints a grant for the caller and returns its token once.'''
    user = caller(event)
    body, error = json_object_body(event)
    if error:
        return error
    try:
        label = validate_label(body.get('label'))
        days = validate_expiry_days(body.get('expires_in_days'))
        folders = validate_folders(body.get('folders'))
        access = validate_access(body.get('access'))
    except ValueError as err:
        return response(400, {'status': f'Invalid input: {err}'})

    now = int(time.time())
    live = [item for item in user_grants(user) if is_live(item, now)]
    if len(live) >= MAX_ACTIVE_GRANTS:
        return response(409, {
            'status': f'You already have {MAX_ACTIVE_GRANTS} active agent grants; '
                      'revoke one before minting another.',
        })

    token = new_token()
    hashed = token_hash(token)
    item = {
        'token_hash': hashed,
        'grant_id': grant_id_for(hashed),
        'user': user,
        'label': label,
        'folders': set(folders),
        'access': access,
        'created_at': now,
        'expires_at': now + days * 86400,
    }
    # The condition can only fail on a 256-bit collision, but a put that
    # silently replaced another user's row would hand them this caller's
    # grant, so it costs nothing to refuse.
    grants_table().put_item(
        Item=item, ConditionExpression='attribute_not_exists(token_hash)')
    print(f'[new_agent_grant] user={user} grant_id={item["grant_id"]} '
          f'access={access} folders={",".join(folders)} expires_at={item["expires_at"]}')
    view = public_view(item, now)
    view['token'] = token
    view['mcp_url'] = mcp_url(event)
    return response(201, view)


def mcp_url(event):
    '''The /mcp endpoint on the API this request arrived through.'''
    context = event.get('requestContext') or {}
    domain = context.get('domainName')
    stage = context.get('stage')
    if not domain or not stage:
        return None
    return f'https://{domain}/{stage}/mcp'
