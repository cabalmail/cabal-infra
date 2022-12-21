'''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
import json
import boto3
from s3 import get_imap_client

ssm = boto3.client('ssm')
mpw = ssm.get_parameter(Name='/cabal/master_password',
                        WithDecryption=True)["Parameter"]["Value"]

def handler(event, _context):
    '''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
    body = json.loads(event['body'])
    client = get_imap_client(body['host'], body['user'])
    client.select_folder(body['folder'])
    response = client.sort(f"{body['sort_order']}{body['sort_field']}", [b'NOT', b'DELETED'])
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_ids": response
        })
    }

