'''Retrieves IMAP message given a folder and ID'''
import json
from s3 import get_message
from s3 import sign_url

def handler(event, _context):
    '''Retrieves IMAP message given a folder and ID'''
    body = json.loads(event['body'])
    message = get_message(body['host'], body['user'], body['folder'], body['id'])
    body_plain = ""
    body_html = ""
    if message.is_multipart():
        for part in message.walk():
            ct = part.get_content_type()
            cd = str(part.get('Content-Disposition'))
            if ct == 'text/plain' and 'attachment' not in cd:
                body_plain = part.get_payload(decode=True)
            if ct == 'text/html' and 'attachment' not in cd:
                body_html = part.get_payload(decode=True)
    else:
        ct = message.get_content_type()
        if ct == 'text/plain':
            body_plain = message.get_payload(decode=True)
        if ct == 'text/html':
            body_html = message.get_payload(decode=True)

    try:
        body_html_decoded = body_html.decode()
    except:
        body_html_decoded = body_html.__str__()

    try:
        body_plain_decoded = body_plain.decode()
    except:
        body_plain_decoded = body_plain.__str__()

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_raw": sign_url(
                                    body['host'].replace("imap", "cache"),
                                    f"{body['user']}/{body['folder']}/{body['id']}/bytes"),
            "message_body_plain": body_plain_decoded,
            "message_body_html": body_html_decoded
        })
    }
