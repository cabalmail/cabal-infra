'''Lists the caller's agent access grants, newest first. Never returns token
material: neither the plaintext (which is not stored) nor its hash.

Phase A of docs/1.x/agent-mail-access-plan.md.'''
import time
from agent_grants import caller, public_view, response, user_grants # pylint: disable=import-error


def handler(event, _context):
    '''Returns {"grants": [...]} for the caller.'''
    now = int(time.time())
    grants = [public_view(item, now) for item in user_grants(caller(event))]
    grants.sort(key=lambda grant: grant['created_at'] or 0, reverse=True)
    return response(200, {'grants': grants})
