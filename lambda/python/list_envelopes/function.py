'''Retrieves IMAP envelopes for a user given a folder and list of message ids'''
import json
from datetime import datetime
from email.header import decode_header
from s3 import get_imap_client

def handler(event, _context):
    '''Retrieves IMAP envelopes for a user given a folder and list of message ids'''
    qs = event['queryStringParameters']
    ids = json.loads(qs['ids'])
    user = event['requestContext']['authorizer']['claims']['cognito:username'];
    client = get_imap_client(qs['host'], user, qs['folder'])
    envelopes = {}
    for msgid, data in client.fetch(ids, ['ENVELOPE', 'FLAGS', 'BODYSTRUCTURE', 'BODY[HEADER.FIELDS (X-PRIORITY)]']).items():
        envelope = data[b'ENVELOPE']
        priority_header = data[b'BODY[HEADER.FIELDS (X-PRIORITY)]'].decode()
        envelopes[msgid] = {
            "id": msgid,
            "date": envelope.date.__str__(),
            "subject": decode_subject(envelope.subject),
            "from": decode_address(envelope.from_),
            "to": decode_address(envelope.to),
            "flags": decode_flags(data[b'FLAGS']),
            "struct": decode_body_structure(data[b'BODYSTRUCTURE']),
            "priority": [f"priority-{s}" for s in priority_header.split() if s.isdigit()]
        }
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "envelopes": envelopes
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

def decode_address(data):
    '''Converts a tuple of Address objects to a simple list of strings'''
    r = []
    for f in data:
        r.append(f"{f.mailbox.decode()}@{f.host.decode()}")
    return r

def decode_flags(data):
    '''Converts array of bytes to array of strings'''
    s = []
    for b in data:
        s.append(b.decode())
    return s

def decode_body_structure(data):
    '''Converts bytes to strings in body structure'''
    s = []
    for i in data:
        if isinstance(i, list):
            s.append(decode_body_structure(i))
        elif isinstance(i, tuple):
            s.append(decode_body_structure(i))
        elif isinstance(i, bytes):
            s.append(i.decode())
        else:
          s.append(i)
    return s
