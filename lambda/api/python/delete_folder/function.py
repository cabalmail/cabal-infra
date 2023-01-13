'''Delete a new folder and returns updated folder list'''
import json
from helper import get_imap_client
from helper import get_folder_list

def handler(event, _context):
    '''Delete a new folder and returns updated folder list'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username'];
    client = get_imap_client(body['host'], user, 'INBOX')
    name = body['name'].replace("/",".")
    client.delete_folder(name)
    response = get_folder_list(client)
    client.logout()
    return {
        "statusCode": 201,
        "body": json.dumps(response)
    }