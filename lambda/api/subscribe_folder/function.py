'''Marks the specified folder as subscribed'''
import json
from helper import subscribe_folder # pylint: disable=import-error
from helper import parse_json_body # pylint: disable=import-error
from helper import validate_folder_name # pylint: disable=import-error
from helper import invalid_input_response # pylint: disable=import-error

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Marks the specified folder as subscribed'''
    body, error = parse_json_body(event)
    if error:
        return error
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        folder = validate_folder_name(body.get('folder')).replace("/", ".")
    except ValueError as err:
        return invalid_input_response(err)
    status = subscribe_folder(folder, None, user)
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": str(status)
        })
    }
