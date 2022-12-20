'''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
import json
import boto3
from imapclient import IMAPClient

ssm = boto3.client('ssm')
mpw = ssm.get_parameter(Name='/cabal/master_password', WithDecryption=True)

def handler(event, _context):
    '''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
    body = json.loads(event['body'])
    client = IMAPClient(host=body['host'], use_uid=True, ssl=True)
    client.login(f"{body['user']}*admin", mpw)
    client.select_folder(body['folder'])
    response = client.sort(f"{body['sort_order']}{body['sort_field']}", [b'NOT', b'DELETED'])
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_ids": response
        })
    }

