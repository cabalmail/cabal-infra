'''Creates a new folder and returns updated folder list'''
import json
from helper import get_imap_client # pylint: disable=import-error
from helper import get_folder_list # pylint: disable=import-error
from helper import parse_json_body # pylint: disable=import-error

from helper import maintenance_guard # pylint: disable=import-error


@maintenance_guard
def handler(event, _context):
    '''Creates a new folder and returns updated folder list'''
    body, error = parse_json_body(event)
    if error:
        return error
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    client = get_imap_client(body['host'], user, 'INBOX')
    if body['parent'] == "":
        client.create_folder(body['name'])
    else:
        parent = body['parent'].replace("/",".")
        client.create_folder(f"{parent}.{body['name']}")
    response = get_folder_list(client)
    client.logout()
    return {
        "statusCode": 201,
        "body": json.dumps(response)
    }
