'''Sets IMAP flags on messages for a user given a folder and list of message ids'''
import json
from helper import ( # pylint: disable=import-error
    get_imap_client,
    validate_flag,
    validate_folder_name,
    validate_uid_list,
)

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Sets IMAP flags on messages for a user given a folder and list of message ids'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event['body'])
    except (TypeError, json.JSONDecodeError):
        return _invalid('request body is not valid JSON')
    try:
        folder = validate_folder_name(body.get('folder'))
        ids = validate_uid_list(body.get('ids'))
        flag = validate_flag(body.get('flag'))
    except ValueError as err:
        return _invalid(err)
    client = get_imap_client(body['host'], user, folder.replace("/", "."))
    if body.get('op') == 'set':
        client.add_flags(ids, flag, True)
    else:
        client.remove_flags(ids, flag, True)
    # No post-store SORT: both clients discard the returned UID list and
    # re-poll for ordering, so the second full-folder walk was pure waste on
    # large mailboxes. Acknowledge like /move_messages does.
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "submitted"
        })
    } # pylint: disable=duplicate-code

def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
