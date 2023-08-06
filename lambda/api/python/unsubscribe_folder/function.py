'''Marks the specified folder as unsubscribed'''
import json
from helper import unsubscribe_folder # pylint: disable=import-error

def handler(event, _context):
    '''Moves a message from source folder to destination folder'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    status = unsubscribe_folder(body['folder'], body['host'], user)
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": status
        })
    }
