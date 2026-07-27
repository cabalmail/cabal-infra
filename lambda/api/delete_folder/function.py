'''Delete a new folder and returns updated folder list'''
import json
import logging
from imapclient.exceptions import IMAPClientError # pylint: disable=import-error
from helper import get_imap_client # pylint: disable=import-error
from helper import get_folder_list # pylint: disable=import-error
from helper import parse_json_body # pylint: disable=import-error
from helper import validate_folder_name # pylint: disable=import-error

from helper import maintenance_guard # pylint: disable=import-error


def _delete_failed(name, err):
    '''Maps a failed DELETE onto a response the client can show. Left
    unhandled, every IMAP-level failure escaped as an unhandled exception and
    API Gateway turned it into a 502, which no client can describe to the
    user. The already-gone case is the common one — another client, or another
    tab, removed the folder first — so it gets its own 404 and names the
    folder.'''
    text = str(err)
    if 'NONEXISTENT' in text.upper() or "doesn't exist" in text.lower():
        return {
            "statusCode": 404,
            "body": json.dumps({
                "status": f"There is no folder called {name.split('.')[-1]}"
            })
        }
    logging.warning('could not delete folder %r: %s', name, text)
    return {
        "statusCode": 500,
        "body": json.dumps({"status": "Unable to delete folder"})
    }


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
    try:
        client.delete_folder(name)
    except IMAPClientError as err:
        client.logout()
        return _delete_failed(name, err)
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
