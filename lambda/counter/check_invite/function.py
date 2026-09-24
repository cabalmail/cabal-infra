'''Cognito pre-signup trigger that gates signups on a shared invitation code.

Compares the `invitationCode` validation-data value supplied by the client
against the INVITATION_CODE env var. When INVITATION_CODE is empty (the
default) the check is disabled and every signup is allowed through.

The gate exists to keep strangers from self-registering through the public
app client. It does not apply to AdminCreateUser: Cognito invokes this
trigger for that path too (triggerSource PreSignUp_AdminCreateUser), but
the caller has already been authorized by IAM. Terraform cannot satisfy the
check anyway: the AWS provider normalizes aws_cognito_user validation_data
keys the way it normalizes user attributes, so `invitationCode` arrives here
as `custom:invitationCode`. Without the exemption Terraform cannot create a
system user (master, dmarc, ci-probe) once this code is deployed with the
code set. The bootstrap placeholder (check_invite.tf) is a no-op, so a
one-shot fresh apply gets past it; bring-ups are rarely one-shot.

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

# The one trigger source the invitation gate exempts. Self-service signup is
# PreSignUp_SignUp; federated signup is PreSignUp_ExternalProvider.
ADMIN_CREATE = 'PreSignUp_AdminCreateUser'


class InvalidInvitationCode(Exception):
    '''Raised when the supplied invitation code does not match the shared
    secret. Cognito surfaces the message verbatim to the client as a
    UserLambdaValidationException.'''


def handler(event, _context):
    '''Pre-sign-up Cognito trigger: reject signups missing the shared code
    (admin-created users excepted), and auto-confirm the user when SMS is
    off (no delivery channel exists to complete the default self-serve
    confirmation).'''
    if expected_code and event.get('triggerSource') != ADMIN_CREATE:
        validation_data = (event.get('request') or {}).get('validationData') or {}
        supplied = validation_data.get('invitationCode', '')
        if not hmac.compare_digest(supplied, expected_code):
            raise InvalidInvitationCode('Invalid invitation code.')
    if not sms_enabled:
        response = event.setdefault('response', {})
        response['autoConfirmUser'] = True
    return event
