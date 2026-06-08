'''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
import json
from helper import ( # pylint: disable=import-error
    get_imap_client,
    validate_folder_name,
    validate_sort_criterion,
)

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
    query_string = event.get('queryStringParameters') or {}
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        folder = validate_folder_name(query_string.get('folder'))
        sort_criterion = validate_sort_criterion(
            query_string.get('sort_order'), query_string.get('sort_field'))
    except ValueError as err:
        return _invalid(err)
    client = get_imap_client(query_string['host'], user, folder.replace("/", "."))
    flags = [b'NOT', b'DELETED']
    response = client.sort(sort_criterion, flags)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_ids": response
        })
    }

def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
