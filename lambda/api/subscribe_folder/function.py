'''Marks the specified folder as subscribed'''
import json
from helper import subscribe_folder # pylint: disable=import-error

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Marks the specified folder as subscribed'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    status = subscribe_folder(body['folder'].replace("/","."), body['host'], user)
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": str(status)
        })
    }
