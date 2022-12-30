'''Retrieves IMAP folders for a user'''
import json
from s3 import get_imap_client

def handler(event, _context):
    '''Retrieves IMAP folders for a user'''
    qs = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username'];
    client = get_imap_client(qs['host'], user, 'INBOX')
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
        folders.append(m[2].replace(".","/"))
    return folders.sort(key=folder_sort)

def folder_sort(k):
    if k == 'INBOX':
        return ' '
    return k