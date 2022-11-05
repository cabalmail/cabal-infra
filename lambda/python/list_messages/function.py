'''Retrieves IMAP messages for a user given a mailbox'''
import json
import logging
from datetime import datetime
from email.header import decode_header

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
        envelope = data[b'ENVELOPE']
        messages.append({
            "id": msgid,
            "date": envelope.date.__str__(),
            "subject": decode(decode_header(envelope.subject.decode())[0][0]),
            "from": decode_from(envelope.from_)
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

def decode_from(data):
    '''Converts a tuple of Address objects to a simple list of strings'''
    r = []
    for f in data:
        r.append(f"{f.mailbox.decode()}@{f.host.decode()}")
    return r

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
        return data.__str__()
    return f"Unsupported data type: %s" % data.__class__.__name__
