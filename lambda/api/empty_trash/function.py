'''Permanently deletes every message in a trash folder'''
import json
from helper import ( # pylint: disable=import-error
    delete_prefix,
    get_imap_client,
    validate_trash_folder,
)

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Permanently deletes every message in a trash folder'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event['body'])
    except (TypeError, json.JSONDecodeError):
        return _invalid('request body is not valid JSON')
    try:
        folder = validate_trash_folder(body.get('folder'))
    except ValueError as err:
        return _invalid(err)
    host = body['host']
    imap_folder = folder.replace("/", ".")
    client = get_imap_client(host, user, imap_folder)
    try:
        # "1:*" covers the whole mailbox without materializing a UID list,
        # so this stays one round trip however full the trash is. On an
        # empty mailbox both calls are no-ops.
        client.delete_messages('1:*')
        client.expunge()
    except: # pylint: disable=bare-except
        client.logout()
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "unable"
            })
        }
    client.logout()
    # Best effort: drop the folder's cached raw bodies too.
    delete_prefix(host.replace("imap", "cache"), f"{user}/{imap_folder}/")
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "emptied"
        })
    }

def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
