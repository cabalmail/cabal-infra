'''Cognito pre-signup trigger that gates signups on a shared invitation code.

Compares the `invitationCode` validation-data value supplied by the client
against the INVITATION_CODE env var. When INVITATION_CODE is empty (the
default) the check is disabled and every signup is allowed through.

When SMS_ENABLED is not "true", the pool has no SMS delivery path
configured (see issue #712 and terraform/infra/modules/user_pool/main.tf),
so the trigger auto-confirms the user in-Lambda: without this the account
would sit UNCONFIRMED and the client would fall through to a Cognito
verification step that has no channel to deliver on.
'''
import os
import hmac

expected_code = os.environ.get('INVITATION_CODE', '')
sms_enabled = os.environ.get('SMS_ENABLED', '').lower() == 'true'


class InvalidInvitationCode(Exception):
    '''Raised when the supplied invitation code does not match the shared
    secret. Cognito surfaces the message verbatim to the client as a
    UserLambdaValidationException.'''


def handler(event, _context):
    '''Pre-sign-up Cognito trigger: reject signups missing the shared code,
    and auto-confirm the user when SMS is off (no delivery channel exists
    to complete the default self-serve confirmation).'''
    if expected_code:
        validation_data = (event.get('request') or {}).get('validationData') or {}
        supplied = validation_data.get('invitationCode', '')
        if not hmac.compare_digest(supplied, expected_code):
            raise InvalidInvitationCode('Invalid invitation code.')
    if not sms_enabled:
        response = event.setdefault('response', {})
        response['autoConfirmUser'] = True
    return event
