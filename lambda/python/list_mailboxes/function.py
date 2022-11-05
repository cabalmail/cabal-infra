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
            "data": decode_mailbox_list(response)
        })
    }

def decode_mailbox_list(data):
    '''Converts mailbox list to simple list'''
    mailboxes = []
    for m in data:
        mailboxes.append(m[2])
    return mailboxes
