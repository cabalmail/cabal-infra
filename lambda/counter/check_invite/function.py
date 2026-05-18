'''Cognito pre-signup trigger that gates signups on a shared invitation code.

Compares the `invitationCode` validation-data value supplied by the client
against the INVITATION_CODE env var. When INVITATION_CODE is empty (the
default) the check is disabled and every signup is allowed through.
'''
import os
import hmac

expected_code = os.environ.get('INVITATION_CODE', '')


def handler(event, _context):
    '''Pre-sign-up Cognito trigger: reject signups missing the shared code.'''
    if not expected_code:
        return event
    validation_data = (event.get('request') or {}).get('validationData') or {}
    supplied = validation_data.get('invitationCode', '')
    if not hmac.compare_digest(supplied, expected_code):
        raise Exception('Invalid invitation code.')
    return event
