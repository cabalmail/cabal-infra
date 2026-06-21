'''Marks the specified folder as unsubscribed'''
import json
from helper import unsubscribe_folder # pylint: disable=import-error
from helper import parse_json_body # pylint: disable=import-error

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Marks the specified folder as unsubscribedr'''
    body, error = parse_json_body(event)
    if error:
        return error
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    status = unsubscribe_folder(body['folder'].replace("/","."), body['host'], user)
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": str(status)
        })
    }
