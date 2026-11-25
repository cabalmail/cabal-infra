'''Revokes one of the caller's agent access grants.

Phase A of docs/1.x/agent-mail-access-plan.md. The row is kept with a
`revoked_at` stamp, so the user's list still shows what the grant was and when
it was last used; its TTL removes it at the original expiry. The /mcp
authorizer caches nothing, so the next request that presents the token is
refused.

Body: {"grant_id": "<16 hex>"}.
'''
import time
from agent_grants import ( # pylint: disable=import-error
    caller,
    grants_table,
    json_object_body,
    response,
    user_grants,
    validate_grant_id,
)


def handler(event, _context):
    '''Stamps revoked_at on the caller's grant named by grant_id.'''
    user = caller(event)
    body, error = json_object_body(event)
    if error:
        return error
    try:
        grant_id = validate_grant_id(body.get('grant_id'))
    except ValueError as err:
        return response(400, {'status': f'Invalid input: {err}'})
    # Looked up through the caller's own rows, so a grant id that belongs to
    # someone else is indistinguishable from one that does not exist.
    match = next((item for item in user_grants(user)
                  if item.get('grant_id') == grant_id), None)
    if match is None:
        return response(404, {'status': 'No such grant'})
    if match.get('revoked_at'):
        return response(200, {'grant_id': grant_id, 'revoked': True})
    grants_table().update_item(
        Key={'token_hash': match['token_hash']},
        UpdateExpression='SET revoked_at = :now',
        ConditionExpression='#u = :user',
        ExpressionAttributeNames={'#u': 'user'},
        ExpressionAttributeValues={':now': int(time.time()), ':user': user},
    )
    print(f'[revoke_agent_grant] user={user} grant_id={grant_id}')
    return response(200, {'grant_id': grant_id, 'revoked': True})
