'''Permanently deletes messages from a trash folder (flag + expunge)'''
import json
from helper import ( # pylint: disable=import-error
    delete_object,
    get_imap_client,
    validate_trash_folder,
    validate_uid_list,
)

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Permanently deletes messages from a trash folder (flag + expunge)'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event['body'])
    except (TypeError, json.JSONDecodeError):
        return _invalid('request body is not valid JSON')
    try:
        folder = validate_trash_folder(body.get('folder'))
        ids = validate_uid_list(body.get('ids'))
    except ValueError as err:
        return _invalid(err)
    if not ids:
        return _invalid('ids is empty')
    host = body['host']
    imap_folder = folder.replace("/", ".")
    client = get_imap_client(host, user, imap_folder)
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
    bucket = host.replace("imap", "cache")
    for msg_id in ids:
        delete_object(bucket, f"{user}/{imap_folder}/{msg_id}/raw")
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "purged"
        })
    }

def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
