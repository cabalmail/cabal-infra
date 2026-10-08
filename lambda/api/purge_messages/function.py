'''Permanently deletes messages from a trash folder (flag + expunge)'''
import json
from helper import ( # pylint: disable=import-error
    delete_object,
    get_imap_client,
    invalid_input_response,
    validate_trash_folder,
    validate_uid_list,
    CACHE_BUCKET,
)

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Permanently deletes messages from a trash folder (flag + expunge)'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event['body'])
    except (TypeError, json.JSONDecodeError):
        return invalid_input_response('request body is not valid JSON')
    try:
        folder = validate_trash_folder(body.get('folder'))
        ids = validate_uid_list(body.get('ids'))
    except ValueError as err:
        return invalid_input_response(err)
    if not ids:
        return invalid_input_response('ids is empty')
    imap_folder = folder.replace("/", ".")
    client = get_imap_client(None, user, imap_folder)
    try:
        client.delete_messages(ids)
        # UID EXPUNGE (Dovecot supports UIDPLUS), so only the requested
        # messages are removed even if others carry \Deleted.
        client.expunge(ids)
    except: # pylint: disable=bare-except
        client.logout()
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "unable"
            })
        }
    client.logout()
    # Best effort: drop cached raw bodies so a purged message is not
    # retrievable from the cache bucket afterwards.
    for msg_id in ids:
        delete_object(CACHE_BUCKET, f"{user}/{imap_folder}/{msg_id}/raw")
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "purged"
        })
    }
