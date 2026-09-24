'''Marks every unseen message in a folder as read.

The mail twin of /rss_mark_all_read (docs/1.x/cross-media-ux-plan.md,
Phase 1). The native clients talk to this API rather than IMAP, so a
client cannot issue the STORE itself, and paging every UID through
/set_flag is the wrong shape for a large folder: one SEARCH here finds
the unseen set and a batched STORE flips it.
'''
import json
from helper import ( # pylint: disable=import-error
    apply_in_batches,
    get_imap_client,
    validate_folder_name,
)

from helper import maintenance_guard # pylint: disable=import-error

SEEN = '\\Seen'


@maintenance_guard
def handler(event, _context):
    '''Marks every unseen message in the requested folder as read.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event['body'])
    except (TypeError, json.JSONDecodeError):
        return _invalid('request body is not valid JSON')
    if not isinstance(body, dict):
        return _invalid('request body must be an object')
    try:
        folder = validate_folder_name(body.get('folder'))
    except ValueError as err:
        return _invalid(err)
    client = get_imap_client(body.get('host'), user, folder.replace("/", "."))
    try:
        # SEARCH UNSEEN materializes only the unread UIDs, which is what the
        # response counts; STORE 1:* would touch every message and, without
        # .SILENT, echo every message's flags back. The store is chunked
        # like /set_flag so a folder with thousands unread cannot brush the
        # 29s API Gateway ceiling in one command; a failed batch leaves its
        # messages unread and the client re-polls, so nothing is lost.
        unseen = client.search(['UNSEEN'])
    except: # pylint: disable=bare-except
        client.logout()
        return _unable()
    flipped, failed = apply_in_batches(list(unseen),
                                       lambda batch: client.add_flags(batch, SEEN, True))
    client.logout()
    if failed and not flipped:
        return _unable()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "marked",
            "flipped": len(flipped),
            "failed": len(failed),
        })
    }


def _unable():
    '''The 500 returned when the IMAP conversation fails outright.'''
    return {
        "statusCode": 500,
        "body": json.dumps({"status": "unable"})
    }


def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
