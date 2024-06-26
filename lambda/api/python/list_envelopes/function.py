'''Retrieves IMAP envelopes for a user given a folder and list of message ids'''
import json
from email.header import decode_header
from helper import get_imap_client # pylint: disable=import-error

def handler(event, _context):
    '''Retrieves IMAP envelopes for a user given a folder and list of message ids'''
    query_string = event['queryStringParameters']
    ids = json.loads(query_string['ids'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    client = get_imap_client(query_string['host'], user,
                             query_string['folder'].replace("/","."), True)
    envelopes = {}
    flags = ['ENVELOPE', 'FLAGS', 'BODYSTRUCTURE', 'BODY[HEADER.FIELDS (X-PRIORITY)]']
    for msgid, data in client.fetch(ids, flags).items():
        envelope = data[b'ENVELOPE']
        priority_header = data[b'BODY[HEADER.FIELDS (X-PRIORITY)]'].decode()
        envelopes[msgid] = {
            "id": msgid,
            "date": str(envelope.date),
            "subject": decode_subject(envelope.subject),
            "from": decode_address(envelope.from_),
            "to": decode_address(envelope.to),
            "cc": decode_address(envelope.cc),
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
    for part in subject_parts:
        try:
            if isinstance(part[0], bytes):
                subject_strings.append(str(part[0], part[1] or 'utf-8'))
            if isinstance(part[0], str):
                subject_strings.append(part[0])
        except UnicodeDecodeError:
            subject_strings.append("[¿?]")

    return ''.join(subject_strings)

def decode_address(data):
    '''Converts a tuple of Address objects to a simple list of strings'''
    return_value = []
    if isinstance(data, type(None)):
        return return_value
    for fragment in data:
        try:
            return_value.append(f"{fragment.mailbox.decode()}@{fragment.host.decode()}")
        except: # pylint: disable=bare-except
            return_value.append("undisclosed-recipients")
    return return_value

def decode_flags(data):
    '''Converts array of bytes to array of strings'''
    return_value = []
    for flag in data:
        return_value.append(flag.decode())
    return return_value

def decode_body_structure(data):
    '''Converts bytes to strings in body structure'''
    return_value = []
    for obj in data:
        if isinstance(obj, list):
            return_value.append(decode_body_structure(obj))
        elif isinstance(obj, tuple):
            return_value.append(decode_body_structure(obj))
        elif isinstance(obj, bytes):
            return_value.append(obj.decode())
        else:
            return_value.append(obj)
    return return_value
