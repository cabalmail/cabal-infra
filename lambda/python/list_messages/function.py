'''Retrieves IMAP messages for a user given a mailbox'''
import json
import logging
from imapclient import IMAPClient

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, _context):
    '''Retrieves IMAP messages for a user given a mailbox'''
    client = IMAPClient(host="imap.${control_domain}", use_uid=True, ssl=True)
    body = json.loads(event['body'])
    client.login(body['user'], body['password'])
    select_info = client.select_folder(body['mailbox'])
    response = client.search([b'NOT', b'DELETED'])
    client.logout()
    logger.info(response)
    return {
        "statusCode": 200,
        "body": json.dumps({
            "data": {
                "message_data": decode(response),
                "folder_data": decode(select_info)
            }
        })
    }

def decode(data):
    '''Converts the byte strings in a complex object to utf-8 strings'''
    if isinstance(data, list):
        return [decode(x) for x in data]
    if isinstance(data, tuple):
        return [decode(x) for x in data]
    if isinstance(data, dict):
        return [decode(x) for x in data]
    if isinstance(data, str):
        return data
    id isinstance(data, int):
        return data
    return f"Unsupported data type: %s" % type(data).__class__.__name__
