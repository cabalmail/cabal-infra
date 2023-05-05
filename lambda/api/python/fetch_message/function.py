'''Retrieves IMAP message given a folder and ID'''
import json
from helper import get_message
from helper import sign_url

def handler(event, _context):
    '''Retrieves IMAP message given a folder and ID'''
    qs = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username'];
    message = get_message(qs['host'], user, qs['folder'], int(qs['id']))
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
                                    qs['host'].replace("imap", "cache"),
                                    f"{user}/{qs['folder']}/{qs['id']}/raw"),
            "message_body_plain": body_plain_decoded,
            "message_body_html": body_html_decoded
        })
    }
