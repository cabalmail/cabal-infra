'''Moves a message from source folder to destination folder'''
import json
from helper import ( # pylint: disable=import-error
    get_imap_client,
    validate_folder_name,
    validate_uid_list,
)

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Moves a message from source folder to destination folder'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event['body'])
    except (TypeError, json.JSONDecodeError):
        return _invalid('request body is not valid JSON')
    try:
        source = validate_folder_name(body.get('source'))
        destination = validate_folder_name(body.get('destination'))
        ids = validate_uid_list(body.get('ids'))
    except ValueError as err:
        return _invalid(err)
    client = get_imap_client(body['host'], user, source.replace("/", "."))
    # Dovecot advertises Trash as special-use but does not auto-create it
    # (no auto= in 15-mailboxes.conf), so the first delete on a fresh
    # mailbox has to create it here. Both web and Apple clients file
    # deletions in Trash.
    if destination == "Trash":
        try:
            client.create_folder(destination.replace("/", "."))
        except: # pylint: disable=bare-except
            pass
    try:
        client.move(ids, destination.replace("/", "."))
    except: # pylint: disable=bare-except
        client.logout()
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "unable"
            })
        }
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "submitted"
        })
    }

def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
