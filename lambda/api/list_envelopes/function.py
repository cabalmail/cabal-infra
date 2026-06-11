'''Retrieves IMAP envelopes for a user given a folder and list of message ids'''
import json
from helper import ( # pylint: disable=import-error
    ENVELOPE_FETCH_KEYS,
    envelope_dict,
    get_imap_client,
    validate_folder_name,
    validate_uid_list,
)

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Retrieves IMAP envelopes for a user given a folder and list of message ids'''
    query_string = event.get('queryStringParameters') or {}
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        folder = validate_folder_name(query_string.get('folder'))
        ids = validate_uid_list(_parse_ids(query_string.get('ids')))
    except ValueError as err:
        return _invalid(err)
    client = get_imap_client(query_string['host'], user,
                             folder.replace("/", "."), True)
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

def _parse_ids(raw):
    '''Parses the `ids` query param (a JSON array string) into a list.'''
    if raw is None:
        raise ValueError('ids is required')
    try:
        return json.loads(raw)
    except (TypeError, json.JSONDecodeError) as exc:
        raise ValueError('ids is not valid JSON') from exc

def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
