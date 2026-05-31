'''Sets IMAP flags on messages for a user given a folder and list of message ids'''
import json
from helper import ( # pylint: disable=import-error
    get_imap_client,
    validate_flag,
    validate_folder_name,
    validate_sort_criterion,
    validate_uid_list,
)

def handler(event, _context):
    '''Sets IMAP flags on messages for a user given a folder and list of message ids'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event['body'])
    except (TypeError, json.JSONDecodeError):
        return _invalid('request body is not valid JSON')
    try:
        folder = validate_folder_name(body.get('folder'))
        ids = validate_uid_list(body.get('ids'))
        flag = validate_flag(body.get('flag'))
        sort_criterion = validate_sort_criterion(
            body.get('sort_order'), body.get('sort_field'))
    except ValueError as err:
        return _invalid(err)
    client = get_imap_client(body['host'], user, folder.replace("/", "."))
    if body.get('op') == 'set':
        client.add_flags(ids, flag, True)
    else:
        client.remove_flags(ids, flag, True)
    response = client.sort(sort_criterion, [b'NOT', b'DELETED'])
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_ids": response
        })
    } # pylint: disable=duplicate-code

def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
