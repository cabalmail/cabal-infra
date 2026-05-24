'''Retrieves IMAP envelopes for a user given a folder and list of message ids'''
import json
from helper import ( # pylint: disable=import-error
    ENVELOPE_FETCH_KEYS,
    envelope_dict,
    get_imap_client,
)

def handler(event, _context):
    '''Retrieves IMAP envelopes for a user given a folder and list of message ids'''
    query_string = event['queryStringParameters']
    ids = json.loads(query_string['ids'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    client = get_imap_client(query_string['host'], user,
                             query_string['folder'].replace("/","."), True)
    envelopes = {}
    for msgid, data in client.fetch(ids, ENVELOPE_FETCH_KEYS).items():
        envelopes[msgid] = envelope_dict(msgid, data)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "envelopes": envelopes
        })
    }
