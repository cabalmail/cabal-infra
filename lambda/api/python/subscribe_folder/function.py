'''Marks the specified folder as subscribed'''
import json
from helper import subscribe_folder # pylint: disable=import-error

def handler(event, _context):
    '''Moves a message from source folder to destination folder'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    status = subscribe_folder(body['folder'], body['host'], user)
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": status
        })
    }
