'''Retrieves IMAP mailboxes for a user'''
import json
import logging
from imapclient import IMAPClient

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, _context):
    '''Retrieves IMAP mailboxes for a user'''
    client = IMAPClient(host="imap.${control_domain}", use_uid=True, ssl=True)
    logger.info(event['body'])
    body = json.loads(event['body'])
    client.login(body['user'], body['password'])
    response = client.list_folders()
    client.logout()
    logger.info(response)
    return {
        "statusCode": 200,
        "body": json.dumps({
            "data": decode(response[0])
        })
    }

def decode(data):
    '''Converts the byte strings in a complex object to utf-8 strings'''
    if isinstance(data, list):
        return [decode(x) for x in data]
    if isinstance(data, tuple):
        return [decode(x) for x in data]
    if isinstance(data, str):
        return data
    return data.decode('utf-8')
