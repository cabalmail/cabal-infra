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
    body_html_charset = "utf8"
    body_plain_charset = "utf8"
    if message.is_multipart():
        for part in message.walk():
            ct = part.get_content_type()
            ch = part.get_content_charset()
            cd = str(part.get('Content-Disposition'))
            if ct == 'text/plain' and 'attachment' not in cd:
                body_plain = part.get_payload(decode=True)
                body_plain_charset = ch
            if ct == 'text/html' and 'attachment' not in cd:
                body_html = part.get_payload(decode=True)
                body_html_charset = ch
    else:
        ct = message.get_content_type()
        ch = message.get_content_charset()
        if ct == 'text/plain':
            body_plain = message.get_payload(decode=True)
            body_plain_charset = ch
        if ct == 'text/html':
            body_html = message.get_payload(decode=True)
            body_html_charset = ch

    try:
        body_html_decoded = body_html.decode(body_html_charset)
    except:
        print("Woopsy")
        body_html_decoded = body_html.__str__()

    try:
        body_plain_decoded = body_plain.decode(body_plain_charset)
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
