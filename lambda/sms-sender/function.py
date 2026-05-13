"""Sends Cognito SMS verification codes via Twilio."""
import base64
import os
import boto3
from twilio.rest import Client  # pylint: disable=import-error
from aws_encryption_sdk import (  # pylint: disable=import-error
    EncryptionSDKClient,
    StrictAwsKmsMasterKeyProvider,
    CommitmentPolicy,
)

region = os.environ['AWS_REGION']
twilio_account_sid_param = os.environ['TWILIO_ACCOUNT_SID_PARAM']
twilio_api_key_param = os.environ['TWILIO_API_KEY_PARAM']
twilio_api_secret_param = os.environ['TWILIO_API_SECRET_PARAM']
twilio_from_number_param = os.environ['TWILIO_FROM_NUMBER_PARAM']
# Optional at import so a code/topology deploy race doesn't crash
# the cold start. _get_key_provider() raises a useful error at
# invocation time if it's actually missing.
kms_key_id = os.environ.get('KMS_KEY_ID')

ssm = boto3.client('ssm', region_name=region)

# Cognito encrypts the custom SMS sender OTP via the AWS Encryption
# SDK, not raw KMS - the ciphertext carries the SDK's envelope and
# raw kms.decrypt() rejects it with InvalidCiphertextException. The
# SDK does its own kms:Decrypt under the hood through the key
# provider, so existing IAM (kms:Decrypt on the key) is sufficient.
#
# FORBID_ENCRYPT_ALLOW_DECRYPT lets us decrypt ciphertexts produced
# with or without key commitment. We never encrypt, so the
# forbid-encrypt half doesn't constrain us and we don't have to
# guess which mode Cognito is using.
_ENCRYPTION_CLIENT = EncryptionSDKClient(
    commitment_policy=CommitmentPolicy.FORBID_ENCRYPT_ALLOW_DECRYPT,
)
_KEY_PROVIDER = None

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

        # twilio.rest.Client signature is (username, password,
        # account_sid). For API-key auth - which is what we're doing -
        # the API Key SID (SK...) is the username and the secret is
        # the password; the Account SID moves to the third arg. (Auth
        # Token auth is Client(account_sid, auth_token) instead, which
        # is what everyone remembers and is easy to mis-port.)
        _TWILIO_CLIENT = Client(api_key, api_secret, account_sid)
    return _TWILIO_CLIENT


def _get_key_provider():
    """Build (and cache) the AWS Encryption SDK key provider."""
    global _KEY_PROVIDER  # pylint: disable=global-statement
    if _KEY_PROVIDER is None:
        if not kms_key_id:
            raise RuntimeError(
                'KMS_KEY_ID env var not set; cannot construct '
                'AWS Encryption SDK key provider for decryption'
            )
        _KEY_PROVIDER = StrictAwsKmsMasterKeyProvider(key_ids=[kms_key_id])
    return _KEY_PROVIDER


def _decrypt_code(event):
    """Decrypt the OTP Cognito handed us in event['request']['code']."""
    ciphertext = base64.b64decode(event['request']['code'])
    plaintext, _header = _ENCRYPTION_CLIENT.decrypt(
        source=ciphertext,
        key_provider=_get_key_provider(),
    )
    return plaintext.decode('utf-8')


def _message_body(trigger_source, code):
    """Compose the SMS body based on which Cognito trigger fired."""
    if trigger_source == 'CustomSMSSender_ForgotPassword':
        return f'Your Cabalmail password reset code is {code}'
    if trigger_source == 'CustomSMSSender_Authentication':
        return f'Your Cabalmail sign-in code is {code}'
    # SignUp, ResendCode, UpdateUserAttribute, VerifyUserAttribute,
    # AdminCreateUser all fall through here.
    return f'Your Cabalmail verification code is {code}'


def _mask_phone_number(phone_number):
    """Return a redacted phone number safe for logs."""
    if not phone_number:
        return '[redacted]'
    return f'***{str(phone_number)[-2:]}'


def handler(event, _context):
    """Sends the Cognito-generated SMS code via Twilio. Returns event unchanged."""
    try:
        trigger = event.get('triggerSource')
        phone_number = event['request']['userAttributes']['phone_number']
        code = _decrypt_code(event)
        print(f'[SMS] Sending {trigger} code')
        send_sms(phone_number, _message_body(trigger, code))
        print('[SMS] Sent')
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
