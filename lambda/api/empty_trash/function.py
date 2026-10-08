'''Permanently deletes every message in a trash folder'''
import json
from helper import ( # pylint: disable=import-error
    delete_prefix,
    get_imap_client,
    invalid_input_response,
    validate_trash_folder,
    CACHE_BUCKET,
)

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Permanently deletes every message in a trash folder'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event['body'])
    except (TypeError, json.JSONDecodeError):
        return invalid_input_response('request body is not valid JSON')
    try:
        folder = validate_trash_folder(body.get('folder'))
    except ValueError as err:
        return invalid_input_response(err)
    imap_folder = folder.replace("/", ".")
    client = get_imap_client(None, user, imap_folder)
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
    delete_prefix(CACHE_BUCKET, f"{user}/{imap_folder}/")
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "emptied"
        })
    }
