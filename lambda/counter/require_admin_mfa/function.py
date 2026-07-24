'''Cognito pre-token-generation trigger gating tokens on MFA enrollment.

Phase 1 of docs/0.10.x/identity-iam-hardening-plan.md, extended to all
human users (the plan's deferred "TOTP-required for non-admins" open
question, resolved 2026-07): every non-exempt user must have an MFA
factor before tokens are issued. Two independently-flagged gates:

- ENFORCE_ADMIN_MFA: admin-group members. No grace window - admins are
  hand-placed and expected to enroll immediately.
- ENFORCE_USER_MFA: everyone else, with a GRACE_HOURS window from
  account creation so a new signup can reach the Security page and
  enroll before the gate hardens behind them.

Each gate is audit-by-default (anything but "true" logs would_block and
issues tokens); flip only after the affected population has enrolled,
because enrollment requires a signed-in session - an enforced,
un-enrolled user cannot sign in to enroll and needs operator rescue
(flip the flag off, or aws cognito-idp admin-set-user-mfa-preference).

EXEMPT_USERS names the service and machine accounts that authenticate
with a password and can never enroll (see require_admin_mfa.tf for the
per-account rationale). Exempt sign-ins are passed silently - master
authenticates on every outbound send and would otherwise flood the log.

Fails open on unexpected errors (e.g. an AdminGetUser throttle): a
broken trigger must degrade to "no gate", never to "nobody can use
their mailbox". The trigger also runs on refresh, so enforcement bounds
already-signed-in sessions too.
'''
import datetime
import json
import os
import boto3  # pylint: disable=import-error

enforce_admin = os.environ.get('ENFORCE_ADMIN_MFA', '').lower() == 'true'
enforce_user = os.environ.get('ENFORCE_USER_MFA', '').lower() == 'true'
admin_group = os.environ.get('ADMIN_GROUP', 'admin')
exempt_users = {
    name.strip()
    for name in os.environ.get('EXEMPT_USERS', '').split(',')
    if name.strip()
}
grace_hours = int(os.environ.get('GRACE_HOURS', '48'))

cognito = boto3.client('cognito-idp')


class AdminMfaRequired(Exception):
    '''Raised in enforce mode for a user with no MFA factor. Cognito
    fails token issuance and surfaces the message to the client.'''


def _log(action, event, gate='', detail=''):
    '''One structured line per decision, greppable in CloudWatch.'''
    print(json.dumps({
        'component': 'require_admin_mfa',
        'action': action,
        'gate': gate,
        'user': event.get('userName', ''),
        'triggerSource': event.get('triggerSource', ''),
        'enforce': enforce_admin if gate == 'admin' else enforce_user,
        'detail': detail,
    }))


def _within_grace(user):
    '''True while the account is younger than GRACE_HOURS - long enough
    for a new signup to sign in and enroll before the gate applies.'''
    created = user.get('UserCreateDate')
    if created is None:
        return False
    age = datetime.datetime.now(datetime.timezone.utc) - created
    return age < datetime.timedelta(hours=grace_hours)


def handler(event, _context):
    '''Pre-token-generation trigger: exempt service accounts pass
    silently; everyone else is looked up and blocked (enforce) or
    logged (audit) when no MFA factor is configured.'''
    username = event.get('userName', '')
    if username in exempt_users:
        return event
    request = event.get('request') or {}
    groups = (request.get('groupConfiguration') or {}).get('groupsToOverride') or []
    gate = 'admin' if admin_group in groups else 'user'
    try:
        user = cognito.admin_get_user(
            UserPoolId=event['userPoolId'],
            Username=username,
        )
        mfa_settings = user.get('UserMFASettingList') or []
    except Exception as err:  # pylint: disable=broad-exception-caught
        # Fail open: a lookup hiccup must not lock everyone out.
        _log('lookup_failed_open', event, gate, str(err))
        return event
    if mfa_settings:
        return event
    if gate == 'user' and _within_grace(user):
        _log('grace_pass', event, gate)
        return event
    enforced = enforce_admin if gate == 'admin' else enforce_user
    if enforced:
        _log('blocked', event, gate)
        raise AdminMfaRequired(
            'This account requires multi-factor authentication. '
            'Ask the operator to re-enable access, then enroll an '
            'authenticator app under Security.'
        )
    _log('would_block', event, gate)
    return event
