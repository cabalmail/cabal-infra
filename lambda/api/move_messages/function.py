'''Moves a message from source folder to destination folder'''
import json
from helper import ( # pylint: disable=import-error
    apply_in_batches,
    batch_result_response,
    get_imap_client,
    parse_bulk_request,
    validate_folder_name,
    validate_uid_list,
)

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Moves a message from source folder to destination folder'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    body, error = parse_bulk_request(event)
    if error:
        return error
    try:
        source = validate_folder_name(body.get('source'))
        destination = validate_folder_name(body.get('destination'))
        ids = validate_uid_list(body.get('ids'))
    except ValueError as err:
        return _invalid(err)
    client = get_imap_client(body['host'], user, source.replace("/", "."))
    # Trash is auto-created by Dovecot at namespace init (auto = create in
    # 15-mailboxes.conf), which the get_imap_client LOGIN above triggers, so
    # it always exists before the move. No force-create round trip needed.
    dest = destination.replace("/", ".")
    moved_ids, failed_ids = apply_in_batches(ids, lambda batch: client.move(batch, dest))
    client.logout()
    return batch_result_response(moved_ids, failed_ids, "moved_ids")

def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
