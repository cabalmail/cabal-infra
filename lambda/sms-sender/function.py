"""Sends Cognito SMS verification codes via Twilio."""
import base64
import os
import boto3
from twilio.rest import Client  # pylint: disable=import-error

region = os.environ['AWS_REGION']
twilio_account_sid_param = os.environ['TWILIO_ACCOUNT_SID_PARAM']
twilio_api_key_param = os.environ['TWILIO_API_KEY_PARAM']
twilio_api_secret_param = os.environ['TWILIO_API_SECRET_PARAM']
twilio_from_number_param = os.environ['TWILIO_FROM_NUMBER_PARAM']
# Optional. KMS can recover the key id from the ciphertext metadata
# for symmetric keys, so a missing KMS_KEY_ID is recoverable. The
# .get() also avoids crashing at module import if app.yml has shipped
# new code before infra.yml has had a chance to apply a matching env
# var change - the assign_osid Lambda uses the same pattern.
kms_key_id = os.environ.get('KMS_KEY_ID')

kms = boto3.client('kms', region_name=region)
ssm = boto3.client('ssm', region_name=region)

_TWILIO_CLIENT = None
_TWILIO_FROM_NUMBER = None


def _get_twilio_client():
    """Build (and cache at cold-start) the Twilio client."""
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


def _decrypt_code(event):
    """Decrypt the OTP Cognito handed us in event['request']['code'].

    The ciphertext is base64-encoded and encrypted under the user
    pool's configured KMS key (var.sms_kms_key_arn) with
    EncryptionContext = {'username': <user>, 'userpoolId': <pool>}.
    KMS Decrypt fails with InvalidCiphertextException if the context
    doesn't match, so we have to mirror it exactly.
    """
    ciphertext = base64.b64decode(event['request']['code'])
    decrypt_args = {
        'CiphertextBlob': ciphertext,
        'EncryptionContext': {
            'username': event['userName'],
            'userpoolId': event['userPoolId'],
        },
    }
    if kms_key_id:
        decrypt_args['KeyId'] = kms_key_id
    response = kms.decrypt(**decrypt_args)
    return response['Plaintext'].decode('utf-8')


def _message_body(trigger_source, code):
    """Compose the SMS body based on which Cognito trigger fired."""
    if trigger_source == 'CustomSMSSender_ForgotPassword':
        return f'Your Cabalmail password reset code is {code}'
    if trigger_source == 'CustomSMSSender_Authentication':
        return f'Your Cabalmail sign-in code is {code}'
    # SignUp, ResendCode, UpdateUserAttribute, VerifyUserAttribute,
    # AdminCreateUser all fall through here.
    return f'Your Cabalmail verification code is {code}'


def handler(event, _context):
    """Sends the Cognito-generated SMS code via Twilio. Returns event unchanged."""
    try:
        trigger = event.get('triggerSource')
        phone_number = event['request']['userAttributes']['phone_number']
        code = _decrypt_code(event)
        print(f'[SMS] Sending {trigger} code to {phone_number}')
        send_sms(phone_number, _message_body(trigger, code))
        print(f'[SMS] Sent to {phone_number}')
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'[SMS] Error: {type(err).__name__}: {err}')
    return event


def send_sms(phone_number, body):
    """Send SMS via Twilio. Swallows non-retryable Twilio errors."""
    client = _get_twilio_client()
    try:
        message = client.messages.create(
            body=body,
            from_=_TWILIO_FROM_NUMBER,
            to=phone_number,
        )
        print(f'[Twilio] Message SID: {message.sid}')
    except Exception as err:  # pylint: disable=broad-exception-caught
        if _is_retryable(err):
            raise
        print(f'[Twilio] Non-retryable error, swallowing: {type(err).__name__}: {err}')


def _is_retryable(error):
    """Whether a Twilio failure looks worth retrying."""
    error_code = getattr(error, 'code', None)
    if error_code in [20001, 20002]:
        return True
    if isinstance(error, ConnectionError):
        return True
    return False
