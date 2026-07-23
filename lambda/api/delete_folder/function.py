'''Delete a new folder and returns updated folder list'''
import json
import logging
from helper import get_imap_client # pylint: disable=import-error
from helper import get_folder_list # pylint: disable=import-error
from helper import parse_json_body # pylint: disable=import-error
from helper import validate_folder_name # pylint: disable=import-error

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Delete a new folder and returns updated folder list'''
    body, error = parse_json_body(event)
    if error:
        return error
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        name = validate_folder_name(body.get('name')).replace("/", ".")
    except ValueError as err:
        return {
            "statusCode": 400,
            "body": json.dumps({"status": f"Invalid input: {err}"})
        }
    client = get_imap_client(None, user, 'INBOX')
    client.delete_folder(name)
    try:
        # Dovecot keeps LSUB entries for deleted mailboxes, so drop the
        # subscription too or the folder lingers in clients' Subscribed list.
        # Best-effort: the delete already succeeded, and a subscription
        # hiccup must not turn that into an error response.
        client.unsubscribe_folder(name)
    except Exception:  # pylint: disable=broad-exception-caught
        logging.warning('could not unsubscribe deleted folder %r', name)
    response = get_folder_list(client)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps(response)
    }
