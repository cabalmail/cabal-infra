"""Sends Cognito SMS verification codes via Twilio"""
import os
import json
import base64
import boto3
from twilio.rest import Client  # pylint: disable=import-error

region = os.environ['AWS_REGION']
twilio_account_sid_param = os.environ['TWILIO_ACCOUNT_SID_PARAM']
twilio_api_key_param = os.environ['TWILIO_API_KEY_PARAM']
twilio_api_secret_param = os.environ['TWILIO_API_SECRET_PARAM']
twilio_from_number_param = os.environ['TWILIO_FROM_NUMBER_PARAM']

kms = boto3.client('kms', region_name=region)
ssm = boto3.client('ssm', region_name=region)

_TWILIO_CLIENT = None
_TWILIO_FROM_NUMBER = None


def _get_twilio_client():
    """Get Twilio client, cached at cold-start"""
    global _TWILIO_CLIENT  # pylint: disable=global-statement
    global _TWILIO_FROM_NUMBER  # pylint: disable=global-statement
    if _TWILIO_CLIENT is None:
        resp_sid = ssm.get_parameter(Name=twilio_account_sid_param, WithDecryption=True)
        account_sid = resp_sid['Parameter']['Value']

        resp_key = ssm.get_parameter(Name=twilio_api_key_param, WithDecryption=True)
        api_key = resp_key['Parameter']['Value']

        resp_secret = ssm.get_parameter(Name=twilio_api_secret_param, WithDecryption=True)
        api_secret = resp_secret['Parameter']['Value']

        resp_number = ssm.get_parameter(Name=twilio_from_number_param, WithDecryption=False)
        _TWILIO_FROM_NUMBER = resp_number['Parameter']['Value']

        _TWILIO_CLIENT = Client(account_sid, api_key, api_secret)
    return _TWILIO_CLIENT


def handler(event, _context):
    """Sends SMS verification code via Twilio. Returns event unchanged."""
    try:
        request = event['request']
        phone_number = request['userAttributes']['phone_number']
        code = request['codeParameter']

        print(f'[SMS] Sending code to {phone_number}')
        send_sms(phone_number, code)
        print(f'[SMS] Sent to {phone_number}')

    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'[SMS] Error: {type(err).__name__}: {err}')

    return event


def send_sms(phone_number, code):
    """Send SMS via Twilio"""
    client = _get_twilio_client()
    message_body = f'Your Cabalmail verification code is {code}'

    try:
        message = client.messages.create(
            body=message_body,
            from_=_TWILIO_FROM_NUMBER,
            to=phone_number
        )
        print(f'[Twilio] Message SID: {message.sid}')
    except Exception as err:  # pylint: disable=broad-exception-caught
        if _is_retryable(err):
            raise
        print(f'[Twilio] Non-retryable error, swallowing: {type(err).__name__}: {err}')


def _is_retryable(error):
    """Check if Twilio error is retryable"""
    error_code = getattr(error, 'code', None)
    if error_code in [20001, 20002]:
        return True
    if isinstance(error, ConnectionError):
        return True
    return False
