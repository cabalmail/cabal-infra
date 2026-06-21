'''Retrieves IMAP envelopes for a user given a folder and list of message ids'''
import json
import time
from helper import ( # pylint: disable=import-error
    ENVELOPE_FETCH_KEYS,
    envelope_dict,
    folder_message_count,
    get_imap_client,
    log_folder_size_bucket,
    validate_folder_name,
    validate_uid_list,
)

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Retrieves IMAP envelopes for a user given a folder and list of message ids'''
    start = time.monotonic()
    query_string = event.get('queryStringParameters') or {}
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        folder = validate_folder_name(query_string.get('folder'))
        ids = validate_uid_list(_parse_ids(query_string.get('ids')))
    except ValueError as err:
        return _invalid(err)
    imap_folder = folder.replace("/", ".")
    client = get_imap_client(query_string['host'], user, imap_folder, True)
    envelopes = {}
    for msgid, data in client.fetch(ids, ENVELOPE_FETCH_KEYS).items():
        envelopes[msgid] = envelope_dict(msgid, data)
    # Time only the envelope fetch -- the size lookup below is an extra STATUS
    # for observability, not request work, so it stays out of duration_ms.
    duration_ms = int((time.monotonic() - start) * 1000)
    total = folder_message_count(client, imap_folder)
    client.logout()
    # Tag the request with a coarse folder-size bucket so CloudWatch Insights can
    # correlate envelope-fetch latency with folder size (Layer 4.1 of the
    # large-mailbox hardening plan).
    log_folder_size_bucket(folder, total, 'list_envelopes', duration_ms)
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
