'''Creates a new folder and returns updated folder list'''
import json
import logging
from imapclient.exceptions import IMAPClientError # pylint: disable=import-error
from helper import get_imap_client # pylint: disable=import-error
from helper import get_folder_list # pylint: disable=import-error
from helper import parse_json_body # pylint: disable=import-error
from helper import validate_folder_name # pylint: disable=import-error

from helper import maintenance_guard # pylint: disable=import-error


def _create_failed(path, err):
    '''Maps a failed CREATE onto a response the client can show. Left
    unhandled, every IMAP-level failure escaped as an unhandled exception and
    API Gateway turned it into a 502, which no client can describe to the
    user. The already-exists case is the common one and is the user's to fix,
    so it gets its own 409 and names the folder.'''
    text = str(err)
    if 'ALREADYEXISTS' in text.upper() or 'already exists' in text.lower():
        return {
            "statusCode": 409,
            "body": json.dumps({
                "status": f"A folder called {path.split('.')[-1]} already exists"
            })
        }
    logging.warning('could not create folder %r: %s', path, text)
    return {
        "statusCode": 500,
        "body": json.dumps({"status": "Unable to create folder"})
    }


@maintenance_guard
def handler(event, _context):
    '''Creates a new folder and returns updated folder list'''
    body, error = parse_json_body(event)
    if error:
        return error
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    # Validate the folder path the same way every read/message-op handler does,
    # so a mutating call can't inject an empty/traversal-shaped mailbox name.
    try:
        name = validate_folder_name(body.get('name'))
        parent = body.get('parent') or ""
        if parent:
            parent = validate_folder_name(parent)
    except ValueError as err:
        return {
            "statusCode": 400,
            "body": json.dumps({"status": f"Invalid input: {err}"})
        }
    client = get_imap_client(None, user, 'INBOX')
    path = name if parent == "" else f"{parent.replace('/', '.')}.{name}"
    try:
        client.create_folder(path)
    except IMAPClientError as err:
        client.logout()
        return _create_failed(path, err)
    response = get_folder_list(client)
    client.logout()
    return {
        "statusCode": 201,
        "body": json.dumps(response)
    }
