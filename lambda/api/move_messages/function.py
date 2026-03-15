'''Moves a message from source folder to destination folder'''
import json
from helper import get_imap_client # pylint: disable=import-error

def handler(event, _context):
    '''Moves a message from source folder to destination folder'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    client = get_imap_client(body['host'], user, body['source'].replace("/","."))
    if body['destination'] == "Deleted Messages":
        try:
            client.create_folder(body['destination'].replace("/","."))
        except: # pylint: disable=bare-except
            pass
    try:
        client.move(body['ids'], body['destination'].replace("/","."))
    except: # pylint: disable=bare-except
        client.logout()
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "unable"
            })
        }
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "submitted"
        })
    }
