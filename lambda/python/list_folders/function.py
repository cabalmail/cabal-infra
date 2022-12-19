'''Retrieves IMAP folders for a user'''
import json
# import logging
from imapclient import IMAPClient

# logger = logging.getLogger()
# logger.setLevel(logging.INFO)

def handler(event, _context):
    '''Retrieves IMAP folders for a user'''
    body = json.loads(event['body'])
    client = IMAPClient(host=body['host'], use_uid=True, ssl=True)
    client.login(body['user'], body['password'])
    response = client.list_folders()
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps(decode_folder_list(response))
    }

def decode_folder_list(data):
    '''Converts folder list to simple list'''
    folders = []
    for m in data:
        folders.append(m[2])
    return folders
