'''Returns IMAP STATUS data (MESSAGES, UNSEEN, UIDVALIDITY, UIDNEXT) for a folder.'''
import json
from helper import get_imap_client # pylint: disable=import-error
from helper import maintenance_guard # pylint: disable=import-error

ATTRS = ['MESSAGES', 'UNSEEN', 'UIDVALIDITY', 'UIDNEXT']


@maintenance_guard
def handler(event, _context):
    '''Returns STATUS attributes for a folder.

    Used by the Apple client to drive cache invalidation (UIDVALIDITY) and
    the inbox unread badge (UNSEEN). The React client doesn't call this —
    its UI doesn't track those values — so the endpoint is additive.
    '''
    query_string = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    folder = query_string['folder'].replace("/", ".")
    client = get_imap_client(query_string['host'], user, 'INBOX', True)
    status = client.folder_status(folder, ATTRS)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "messages": status.get(b'MESSAGES'),
            "unseen": status.get(b'UNSEEN'),
            "uid_validity": status.get(b'UIDVALIDITY'),
            "uid_next": status.get(b'UIDNEXT')
        })
    }
