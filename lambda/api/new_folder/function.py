'''Creates a new folder and returns updated folder list'''
import json
from helper import get_imap_client # pylint: disable=import-error
from helper import get_folder_list # pylint: disable=import-error
from helper import parse_json_body # pylint: disable=import-error
from helper import validate_folder_name # pylint: disable=import-error

from helper import maintenance_guard # pylint: disable=import-error


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
    if parent == "":
        client.create_folder(name)
    else:
        parent = parent.replace("/",".")
        client.create_folder(f"{parent}.{name}")
    response = get_folder_list(client)
    client.logout()
    return {
        "statusCode": 201,
        "body": json.dumps(response)
    }
