'''Retrieves IMAP message given a folder and ID'''
import json
import re
from helper import get_message # pylint: disable=import-error
from helper import sign_url # pylint: disable=import-error

def handler(event, _context):
    '''Retrieves IMAP message given a folder and ID'''
    query_string = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    message = get_message(
              query_string['host'], user, query_string['folder'], int(query_string['id']))
    body_plain = ""
    body_html = ""
    body_html_charset = "utf8"
    body_plain_charset = "utf8"
    recipient = get_recipient(message)
    if message.is_multipart():
        for part in message.walk():
            content_type = part.get_content_type()
            content_charset = part.get_content_charset()
            content_disposition = str(part.get('Content-Disposition'))
            if content_type == 'text/plain' and 'attachment' not in content_disposition:
                body_plain = part.get_payload(decode=True)
                body_plain_charset = content_charset
            if content_type == 'text/html' and 'attachment' not in content_disposition:
                body_html = part.get_payload(decode=True)
                body_html_charset = content_charset
    else:
        content_type = message.get_content_type()
        content_charset = message.get_content_charset()
        if content_type == 'text/plain':
            body_plain = message.get_payload(decode=True)
            body_plain_charset = content_charset
        if content_type == 'text/html':
            body_html = message.get_payload(decode=True)
            body_html_charset = content_charset

    try:
        body_html_decoded = body_html.decode(body_html_charset)
    except: # pylint: disable=bare-except
        print("Woopsy")
        body_html_decoded = str(body_html)

    try:
        body_plain_decoded = body_plain.decode(body_plain_charset)
    except: # pylint: disable=bare-except
        body_plain_decoded = str(body_plain)

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_raw": sign_url(
                                    query_string['host'].replace("imap", "cache"),
                                    f"{user}/{query_string['folder']}/{query_string['id']}/raw"),
            "message_body_plain": body_plain_decoded,
            "message_body_html": body_html_decoded,
            "recipient": recipient,
            "message_id": message.get_all('Message-ID'),
            "in_reply_to": message.get_all('In-Reply-To'),
            "references": message.get_all('References')
        })
    }

def get_recipient(message):
    """Extract final recipient from headers"""
    recipient = ""
    headers = message.get_all('Received')
    if headers:
        match = re.search("for <([^>]*)>;", headers[0])
        if match:
            recipient = match.group(1)
    return recipient
