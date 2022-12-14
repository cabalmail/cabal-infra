'''Retrieves IMAP mailboxes for a user'''
import json
# import logging
from imapclient import IMAPClient

# logger = logging.getLogger()
# logger.setLevel(logging.INFO)

def handler(event, _context):
    '''Retrieves IMAP mailboxes for a user'''
    body = json.loads(event['body'])
    client = IMAPClient(host=body['host'], use_uid=True, ssl=True)
    client.login(body['user'], body['password'])
    response = client.list_folders()
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps(decode_mailbox_list(response))
    }

def decode_mailbox_list(data):
    '''Converts mailbox list to simple list'''
    mailboxes = []
    for m in data:
        mailboxes.append(m[2])
    return mailboxes
