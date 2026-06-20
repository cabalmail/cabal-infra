'''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
import json
from helper import ( # pylint: disable=import-error
    get_imap_client,
    validate_folder_name,
    validate_pagination,
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
        offset, limit = validate_pagination(
            query_string.get('offset'), query_string.get('limit'))
    except ValueError as err:
        return _invalid(err)
    client = get_imap_client(query_string['host'], user, folder.replace("/", "."))
    flags = [b'NOT', b'DELETED']
    response = client.sort(sort_criterion, flags)
    client.logout()
    # Dovecot SORT stays the source of truth for ordering; offset/limit slice
    # the result server-side so a large folder returns one page instead of every
    # UID. Slicing is positional, not UID-based, because the sort key may be
    # DATE/FROM/SUBJECT/etc. -- UID order is not result order. `total` is the
    # full count so a client can show "N of total" without the whole list. With
    # neither param set this returns the full sorted list unchanged.
    total = len(response)
    message_ids = response[offset:offset + limit] if limit is not None else response[offset:]
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_ids": message_ids,
            "total": total
        })
    }

def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
