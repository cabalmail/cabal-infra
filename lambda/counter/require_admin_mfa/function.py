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
issues tokens); enrollment requires a signed-in session, so an
enforced, un-enrolled user cannot sign in through the normal app
client. The self-service escape hatch is a dedicated enrollment app
client (user_pool module, `mfa_enroll`): sign-ins through it are
passed for users with NO factor - short-lived tokens whose only
intended use is AssociateSoftwareToken / VerifySoftwareToken /
SetUserMFAPreference from the web app's locked-out setup flow. Users
who already hold a factor never reach the pass (they return early
above it), and Cognito itself still demands their TOTP during the auth
flow, so the enrollment client cannot be used to sidestep an enrolled
second factor. The client's id is read from SSM (MFA_ENROLL_CLIENT_PARAM)
rather than the environment because the pool -> trigger -> client ->
pool reference chain would otherwise be a Terraform cycle.

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
enroll_client_param = os.environ.get('MFA_ENROLL_CLIENT_PARAM', '')

cognito = boto3.client('cognito-idp')
ssm = boto3.client('ssm')

# Lazily resolved id of the enrollment app client. Only successful
# lookups are cached (for the container lifetime); a transient SSM
# failure is retried on the next invocation instead of pinning the
# escape hatch shut.
_enroll_client = {'id': None}


def _enroll_client_id():
    '''Id of the enrollment app client, or '' when unconfigured or the
    SSM read fails (the sign-in then blocks exactly as before).'''
    if _enroll_client['id'] is not None:
        return _enroll_client['id']
    if not enroll_client_param:
        return ''
    try:
        value = ssm.get_parameter(
            Name=enroll_client_param
        )['Parameter']['Value']
    except Exception:  # pylint: disable=broad-exception-caught
        return ''
    _enroll_client['id'] = value
    return value


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
        # Self-service escape hatch: a factorless sign-in through the
        # dedicated enrollment client passes, so the web app's
        # locked-out setup flow can associate and verify a TOTP.
        # Enrolled users returned above and never reach this pass.
        client_id = (event.get('callerContext') or {}).get('clientId', '')
        if client_id and client_id == _enroll_client_id():
            _log('enroll_pass', event, gate)
            return event
        _log('blocked', event, gate)
        # No trailing period: Cognito appends its own when it wraps
        # this in "PreTokenGeneration failed with error ...".
        raise AdminMfaRequired(
            'This account requires multi-factor authentication. '
            'Sign in on the web app to set up an authenticator, '
            'then try again'
        )
    _log('would_block', event, gate)
    return event
