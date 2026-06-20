'''Returns IMAP STATUS data (MESSAGES, UNSEEN, UIDVALIDITY, UIDNEXT) for a
folder, plus an optional FLAGGED count.'''
import json
from helper import get_imap_client # pylint: disable=import-error
from helper import maintenance_guard # pylint: disable=import-error

ATTRS = ['MESSAGES', 'UNSEEN', 'UIDVALIDITY', 'UIDNEXT']
TRUTHY = {'1', 'true', 'True', 'yes', 'YES'}


@maintenance_guard
def handler(event, _context):
    '''Returns STATUS attributes for a folder, optionally with a FLAGGED count.

    Drives two pollers:
      * the Apple client's `idle(folder:)` loop, which reads UIDNEXT (folder
        changed) and UNSEEN (inbox badge); and
      * the React message list's steady-state poll (Phase 6 of the
        large-mailbox hardening plan), which reads UNSEEN/FLAGGED for the
        filter-pill counts and UIDNEXT/MESSAGES to decide when the sorted UID
        list needs re-fetching.

    STATUS has no flagged attribute, so `?flagged=1` adds one SEARCH FLAGGED on
    the selected folder. It is opt-in so the Apple idle path -- which never
    needs it -- keeps paying for the cheap STATUS-only round trip. The count
    excludes DELETED-but-not-expunged messages to match the `NOT DELETED` set
    /list_messages returns, so the "Flagged" pill and the list agree.
    '''
    query_string = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    folder = query_string['folder'].replace("/", ".")
    want_flagged = query_string.get('flagged') in TRUTHY
    # SEARCH runs against the selected mailbox, so a flagged count needs the
    # target folder selected; otherwise stay on INBOX (STATUS reads any folder
    # regardless of selection -- the cheap path the Apple idle poll uses).
    selected = folder if want_flagged else 'INBOX'
    client = get_imap_client(query_string['host'], user, selected, True)
    status = client.folder_status(folder, ATTRS)
    body = {
        "messages": status.get(b'MESSAGES'),
        "unseen": status.get(b'UNSEEN'),
        "uid_validity": status.get(b'UIDVALIDITY'),
        "uid_next": status.get(b'UIDNEXT')
    }
    if want_flagged:
        body["flagged"] = len(client.search(['FLAGGED', 'NOT', 'DELETED']))
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps(body)
    }
