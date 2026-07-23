'''Cognito pre-token-generation trigger gating admin tokens on MFA.

Phase 1 of docs/0.10.x/identity-iam-hardening-plan.md: members of the
admin group must have an MFA factor configured before tokens are issued.
Non-admins pass through untouched (no API calls, no added latency).

Two modes, controlled by the ENFORCE_ADMIN_MFA env var:

- audit (default, anything but "true"): un-enrolled admins are logged
  ("would_block") but tokens still issue. This is the soak mode - flip
  to enforce only after every admin has enrolled, because enrollment
  itself requires a signed-in session: an enforced, un-enrolled admin
  cannot sign in to enroll and needs operator intervention (flip the
  flag off, or aws cognito-idp admin-set-user-mfa-preference).
- enforce ("true"): raises, which makes Cognito refuse token issuance.
  The message is surfaced to the client inside the Lambda-trigger error.

Fails open on unexpected errors (e.g. an AdminGetUser throttle): a
broken trigger must degrade to "no gate", never to "no admin can use
their mailbox". The pre-token-generation trigger also runs on refresh,
so enforcement bounds an already-signed-in admin session too.
'''
import json
import os
import boto3  # pylint: disable=import-error

enforce = os.environ.get('ENFORCE_ADMIN_MFA', '').lower() == 'true'
admin_group = os.environ.get('ADMIN_GROUP', 'admin')

cognito = boto3.client('cognito-idp')


class AdminMfaRequired(Exception):
    '''Raised in enforce mode for an admin with no MFA factor. Cognito
    fails token issuance and surfaces the message to the client.'''


def _log(action, event, detail=''):
    '''One structured line per decision, greppable in CloudWatch.'''
    print(json.dumps({
        'component': 'require_admin_mfa',
        'action': action,
        'user': event.get('userName', ''),
        'triggerSource': event.get('triggerSource', ''),
        'enforce': enforce,
        'detail': detail,
    }))


def handler(event, _context):
    '''Pre-token-generation trigger: pass non-admins through; look up an
    admin's MFA settings and block (enforce) or log (audit) when none
    are configured.'''
    request = event.get('request') or {}
    groups = (request.get('groupConfiguration') or {}).get('groupsToOverride') or []
    if admin_group not in groups:
        return event
    try:
        user = cognito.admin_get_user(
            UserPoolId=event['userPoolId'],
            Username=event['userName'],
        )
        mfa_settings = user.get('UserMFASettingList') or []
    except Exception as err:  # pylint: disable=broad-exception-caught
        # Fail open: a lookup hiccup must not lock every admin out.
        _log('lookup_failed_open', event, str(err))
        return event
    if mfa_settings:
        return event
    if enforce:
        _log('blocked', event)
        raise AdminMfaRequired(
            'Admin accounts require multi-factor authentication. '
            'Ask the operator to re-enable access, then enroll an '
            'authenticator app under Security.'
        )
    _log('would_block', event)
    return event
