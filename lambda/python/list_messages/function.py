'''Retrieves IMAP message ids for a user given a mailbox and sorting criteria'''
import json
import logging

from imapclient import IMAPClient

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, _context):
    '''Retrieves IMAP message ids for a user given a mailbox and sorting criteria'''
    client = IMAPClient(host="imap.${control_domain}", use_uid=True, ssl=True)
    body = json.loads(event['body'])
    client.login(body['user'], body['password'])
    client.select_folder(body['mailbox'])
    response = client.sort(f"{body['sort_order']}{body['sort_field']}", [b'NOT', b'DELETED'])
    logger.info(response)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "data": {
                "message_ids": response
            }
        })
    }

