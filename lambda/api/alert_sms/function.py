'''SMS sink: accepts webhook payloads from monitoring tools and publishes to SNS.

Callers authenticate with a shared secret in the X-Alert-Secret header (read
from SSM Parameter Store at cold start). The function formats a short SMS
(<=160 chars) and publishes to the alerts SNS topic, which has per-on-call
phone number subscriptions.
'''
import base64
import hmac
import json
import os
import boto3  # pylint: disable=import-error

ALERTS_TOPIC_ARN = os.environ['ALERTS_TOPIC_ARN']
SHARED_SECRET_PARAM = os.environ['SHARED_SECRET_PARAM']
SES_EMAIL_FROM = os.environ.get('SES_EMAIL_FROM', '')
SES_EMAIL_TO = os.environ.get('SES_EMAIL_TO', '')

ssm = boto3.client('ssm')
sns = boto3.client('sns')
ses = boto3.client('ses')

_SHARED_SECRET = None


def get_shared_secret():
    '''Fetches and caches the shared secret from SSM.'''
    global _SHARED_SECRET  # pylint: disable=global-statement
    if _SHARED_SECRET is None:
        response = ssm.get_parameter(Name=SHARED_SECRET_PARAM, WithDecryption=True)
        _SHARED_SECRET = response['Parameter']['Value']
    return _SHARED_SECRET


def _reply(status, message=None):
    '''Builds an API Gateway / Function URL response.'''
    body = {'message': message} if message else {}
    return {
        'statusCode': status,
        'body': json.dumps(body),
        'headers': {'Content-Type': 'application/json'}
    }


def _headers(event):
    '''Normalizes header lookups across API Gateway v1 and Lambda Function URL v2 events.'''
    headers = event.get('headers') or {}
    return {k.lower(): v for k, v in headers.items()}


def _format_sms(payload):
    '''Truncates a formatted summary to fit in a single SMS segment.'''
    severity = payload.get('severity', 'info').upper()
    source = payload.get('source', 'unknown')
    summary = payload.get('summary', '(no summary)')
    prefix = f"[{severity}] {source}: "
    budget = 160 - len(prefix)
    if len(summary) > budget:
        summary = summary[:max(0, budget - 1)] + '\u2026'
    return prefix + summary


def handler(event, _context):  # pylint: disable=too-many-return-statements
    '''Validates the shared secret and publishes the alert to SNS.'''
    headers = _headers(event)
    provided = headers.get('x-alert-secret', '')
    expected = get_shared_secret()
    if not provided or not hmac.compare_digest(provided, expected):
        return _reply(401, 'invalid or missing X-Alert-Secret header')

    try:
        body = event.get('body') or '{}'
        if event.get('isBase64Encoded'):
            body = base64.b64decode(body).decode('utf-8')
        payload = json.loads(body)
    except (ValueError, TypeError) as err:
        return _reply(400, f'invalid JSON body: {err}')

    severity = payload.get('severity', 'info').lower()
    if severity == 'info':
        return _reply(204)

    if severity == 'critical':
        message = _format_sms(payload)
        try:
            sns.publish(TopicArn=ALERTS_TOPIC_ARN, Message=message)
        except Exception as err:  # pylint: disable=broad-exception-caught
            print(f"Error publishing to SNS: {err}")
            return _reply(500, f'sns publish failed: {err}')
        return _reply(204)

    if severity == 'warning':
        if not SES_EMAIL_FROM or not SES_EMAIL_TO:
            print(f"Warning received but SES email not configured; dropping: {payload}")
            return _reply(204)
        source = payload.get('source', 'unknown')
        summary = payload.get('summary', '(no summary)')
        try:
            ses.send_email(
                Source=SES_EMAIL_FROM,
                Destination={'ToAddresses': [SES_EMAIL_TO]},
                Message={
                    'Subject': {'Data': f"[warning] {source}"},
                    'Body': {'Text': {'Data': summary}}
                }
            )
        except Exception as err:  # pylint: disable=broad-exception-caught
            print(f"Error sending SES email: {err}")
            return _reply(500, f'ses send failed: {err}')
        return _reply(204)

    return _reply(400, f'unknown severity: {severity}')
