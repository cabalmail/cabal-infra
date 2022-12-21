'''Retrieves IMAP folders for a user'''
import json
import boto3
from s3 import get_imap_client

ssm = boto3.client('ssm')
mpw = ssm.get_parameter(Name='/cabal/master_password',
                        WithDecryption=True)["Parameter"]["Value"]

def handler(event, _context):
    '''Retrieves IMAP folders for a user'''
    body = json.loads(event['body'])
    client = get_imap_client(body['host'], body['user'])
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
