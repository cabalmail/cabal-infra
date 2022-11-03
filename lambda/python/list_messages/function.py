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
    logger.info(response)
    messages = []
    for msgid, data in client.fetch(response, ['ENVELOPE']).items():
        messages.append({
            "id": msgid,
            "data": decode(data[b'ENVELOPE'])
        })
    logger.info(messages)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "data": {
                "message_data": messages,
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
    if isinstance(data, int):
        return data
    if isinstance(data, bytes):
        return data.decode('utf-8')
    if isinstance(data, datetime):
        return data
    if isinstance(data, NoneType):
        return data
    return f"Unsupported data type: %s" % data.__class__.__name__
