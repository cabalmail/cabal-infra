'''Sets IMAP flags on messages for a user given a folder and list of message ids'''
import json
from helper import ( # pylint: disable=import-error
    apply_in_batches,
    batch_result_response,
    get_imap_client,
    parse_bulk_request,
    validate_flag,
    validate_folder_name,
    validate_uid_list,
)

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Sets IMAP flags on messages for a user given a folder and list of message ids'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    body, error = parse_bulk_request(event)
    if error:
        return error
    try:
        folder = validate_folder_name(body.get('folder'))
        ids = validate_uid_list(body.get('ids'))
        flag = validate_flag(body.get('flag'))
    except ValueError as err:
        return _invalid(err)
    client = get_imap_client(body['host'], user, folder.replace("/", "."))
    # Chunk the store like /move_messages so a large selection can't blow the
    # 29s ceiling in one UID STORE. Flags are idempotent, so a failed batch is
    # safe to retry. No post-store SORT: both clients discard the returned UID
    # list and re-poll for ordering, so that second full-folder walk was waste.
    store = client.add_flags if body.get('op') == 'set' else client.remove_flags
    flagged_ids, failed_ids = apply_in_batches(ids, lambda batch: store(batch, flag, True))
    client.logout()
    return batch_result_response(flagged_ids, failed_ids, "flagged_ids")

def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
