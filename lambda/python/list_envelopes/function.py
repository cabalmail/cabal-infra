'''Retrieves IMAP envelopes for a user given a mailbox and list of message ids'''
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
    client.select_folder(body['mailbox'])
    envelopes = {}
    for msgid, data in client.fetch(body['ids'], ['ENVELOPE', 'FLAGS']).items():
        envelope = data[b'ENVELOPE']
        envelopes[msgid] = {
            "id": msgid,
            "date": envelope.date.__str__(),
            "subject": decode_subject(envelope.subject),
            "from": decode_from(envelope.from_),
            "flags": decode_flags(data[b'FLAGS'])
        }
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "data": {
              "envelopes": envelopes
            }
        })
    }

def decode_subject(data):
    '''Converts an email subject into a utf-8 string'''
    if data is None:
        return ''
    try:
        subject_parts = decode_header(data.decode())
    except UnicodeDecodeError:
        return "[[¿?]]"
    subject_strings = []
    for p in subject_parts:
        try:
            if isinstance(p[0], bytes):
                subject_strings.append(str(p[0], p[1] or 'utf-8'))
            if isinstance(p[0], str):
                subject_strings.append(p[0])
        except UnicodeDecodeError:
            subject_strings.append("[¿?]")

    return ''.join(subject_strings)

def decode_from(data):
    '''Converts a tuple of Address objects to a simple list of strings'''
    r = []
    for f in data:
        r.append(f"{f.mailbox.decode()}@{f.host.decode()}")
    return r

def decode_flags(data):
    '''Converts array of bytes to array of strings'''
    s = []
    for b in data:
        s.append(s.decode())
    return s
