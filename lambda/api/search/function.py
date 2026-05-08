'''Searches a folder using IMAP SEARCH and returns matching UIDs.'''
import json
from helper import get_imap_client # pylint: disable=import-error

def handler(event, _context):
    '''Returns UIDs of messages in `folder` matching the IMAP SEARCH `query`.

    Powers the Apple client's mailbox search. The Lambda accepts the raw
    SEARCH criteria as a single string (e.g. `TEXT "hello"`,
    `FROM alice SUBJECT meeting`) so the wire shape mirrors what the
    `LiveImapClient` used to send (`UID SEARCH \\(query)`); the IMAP
    server itself enforces folder/user scoping via the per-user master
    login established in `helper.get_imap_client`.

    Optional `charset` query parameter is forwarded to the server. When
    absent, `imapclient` omits the CHARSET clause and the server falls
    back to its default (US-ASCII / unspecified). UTF-8 callers should
    set `charset=UTF-8` so non-ASCII literals are interpreted correctly.
    '''
    query_string = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    folder = query_string['folder'].replace("/", ".")
    raw_query = query_string.get('query') or 'ALL'
    charset = query_string.get('charset')
    client = get_imap_client(query_string['host'], user, folder, True)
    if charset:
        message_ids = client.search(raw_query, charset)
    else:
        message_ids = client.search(raw_query)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_ids": list(message_ids)
        })
    }
