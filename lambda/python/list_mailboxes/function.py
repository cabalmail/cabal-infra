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

def decode(l):
    '''Converts the byte strings in a complex object to utf-8 strings'''
    if isinstance(l, list):
        return [decode(x) for x in l]
    if isinstance(l, tuple):
        return [decode(x) for x in l]
    if isinstance(l, str):
        return l
    return l.decode('utf-8')
