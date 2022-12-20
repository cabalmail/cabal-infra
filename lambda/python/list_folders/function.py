'''Retrieves IMAP folders for a user'''
import json
import boto3
from imapclient import IMAPClient

ssm = boto3.client('ssm')
mpw = ssm.get_parameter(Name='/cabal/master_password', WithDecryption=True)

def handler(event, _context):
    '''Retrieves IMAP folders for a user'''
    body = json.loads(event['body'])
    client = IMAPClient(host=body['host'], use_uid=True, ssl=True)
    client.login(f"{body['user']}*admin", mpw)
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
