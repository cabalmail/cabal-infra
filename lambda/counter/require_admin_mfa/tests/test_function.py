'''Unit tests for the require_admin_mfa pre-token-generation trigger.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/counter/require_admin_mfa/tests/test_function.py

boto3 is faked in sys.modules before import, so the suite needs no AWS
credentials and never touches the network. The module reads its flags
from the environment at import time, so each test reloads it with the
flag set it needs.
'''
import datetime
import importlib
import os
import sys
import types
import unittest

# function.py lives one directory up.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# --- fake boto3 ---------------------------------------------------------------

ENROLL_CLIENT_ID = 'enroll-client-123'
NORMAL_CLIENT_ID = 'admin-client-456'


class _FakeCognito:
    '''admin_get_user backed by a user dict set per test.'''

    def __init__(self):
        self.user = {}
        self.error = None

    def admin_get_user(self, **_kwargs):
        if self.error:
            raise self.error
        return self.user


class _FakeSsm:
    '''get_parameter returning a canned value or raising per test.'''

    def __init__(self):
        self.value = ENROLL_CLIENT_ID
        self.error = None
        self.calls = 0

    def get_parameter(self, **_kwargs):
        self.calls += 1
        if self.error:
            raise self.error
        return {'Parameter': {'Value': self.value}}


FAKE_COGNITO = _FakeCognito()
FAKE_SSM = _FakeSsm()

_boto3 = types.ModuleType('boto3')
_boto3.client = lambda name: FAKE_COGNITO if name == 'cognito-idp' else FAKE_SSM
sys.modules['boto3'] = _boto3

import function  # pylint: disable=wrong-import-position


def _reload(**env):
    '''Reload the module under a fresh environment (flags are read at
    import time) and reset the fakes.'''
    defaults = {
        'ENFORCE_ADMIN_MFA': 'true',
        'ENFORCE_USER_MFA': 'true',
        'EXEMPT_USERS': 'master,dmarc',
        'GRACE_HOURS': '48',
        'MFA_ENROLL_CLIENT_PARAM': '/cabal/mfa_enroll_client_id',
    }
    defaults.update(env)
    for key in list(defaults):
        if defaults[key] is None:
            os.environ.pop(key, None)
            del defaults[key]
    os.environ.update(defaults)
    FAKE_COGNITO.user = {}
    FAKE_COGNITO.error = None
    FAKE_SSM.value = ENROLL_CLIENT_ID
    FAKE_SSM.error = None
    FAKE_SSM.calls = 0
    importlib.reload(function)


def _event(username='claude', client_id=NORMAL_CLIENT_ID, groups=None,
           trigger='TokenGeneration_Authentication'):
    return {
        'userPoolId': 'us-east-1_test',
        'userName': username,
        'triggerSource': trigger,
        'callerContext': {'clientId': client_id},
        'request': {'groupConfiguration': {'groupsToOverride': groups or []}},
    }


def _user(mfa=None, created_hours_ago=100):
    created = (datetime.datetime.now(datetime.timezone.utc)
               - datetime.timedelta(hours=created_hours_ago))
    return {'UserMFASettingList': mfa or [], 'UserCreateDate': created}


class RequireAdminMfaTests(unittest.TestCase):
    '''Gate decisions across client, enrollment, and flag combinations.'''

    def test_enforced_unenrolled_normal_client_blocks(self):
        _reload()
        FAKE_COGNITO.user = _user()
        with self.assertRaises(Exception) as ctx:
            function.handler(_event(), None)
        # Cognito appends its own period when it wraps the message;
        # a trailing one here would render as "..".
        self.assertFalse(str(ctx.exception).endswith('.'))
        self.assertIn('multi-factor', str(ctx.exception))

    def test_enforced_unenrolled_enroll_client_passes(self):
        _reload()
        FAKE_COGNITO.user = _user()
        event = _event(client_id=ENROLL_CLIENT_ID)
        self.assertIs(function.handler(event, None), event)

    def test_enroll_client_pass_covers_admin_gate_too(self):
        _reload()
        FAKE_COGNITO.user = _user()
        event = _event(client_id=ENROLL_CLIENT_ID, groups=['admin'])
        self.assertIs(function.handler(event, None), event)

    def test_enrolled_user_passes_regardless_of_client(self):
        _reload()
        FAKE_COGNITO.user = _user(mfa=['SOFTWARE_TOKEN_MFA'])
        for client in (NORMAL_CLIENT_ID, ENROLL_CLIENT_ID):
            event = _event(client_id=client)
            self.assertIs(function.handler(event, None), event)

    def test_ssm_failure_keeps_blocking_then_recovers(self):
        _reload()
        FAKE_COGNITO.user = _user()
        FAKE_SSM.error = RuntimeError('throttled')
        with self.assertRaises(Exception):
            function.handler(_event(client_id=ENROLL_CLIENT_ID), None)
        # The failure must not be cached: once SSM answers, the same
        # container passes the enrollment client.
        FAKE_SSM.error = None
        event = _event(client_id=ENROLL_CLIENT_ID)
        self.assertIs(function.handler(event, None), event)

    def test_enroll_id_cached_after_success(self):
        _reload()
        FAKE_COGNITO.user = _user()
        for _ in range(3):
            with self.assertRaises(Exception):
                function.handler(_event(), None)
        self.assertEqual(FAKE_SSM.calls, 1)

    def test_param_unset_blocks_without_ssm_call(self):
        _reload(MFA_ENROLL_CLIENT_PARAM=None)
        FAKE_COGNITO.user = _user()
        with self.assertRaises(Exception):
            function.handler(_event(client_id=ENROLL_CLIENT_ID), None)
        self.assertEqual(FAKE_SSM.calls, 0)

    def test_audit_mode_still_passes_unenrolled(self):
        _reload(ENFORCE_USER_MFA='false')
        FAKE_COGNITO.user = _user()
        event = _event()
        self.assertIs(function.handler(event, None), event)

    def test_grace_window_passes_before_enroll_check(self):
        _reload()
        FAKE_COGNITO.user = _user(created_hours_ago=1)
        event = _event()
        self.assertIs(function.handler(event, None), event)
        self.assertEqual(FAKE_SSM.calls, 0)

    def test_exempt_user_passes_without_lookup(self):
        _reload()
        FAKE_COGNITO.error = AssertionError('must not be called')
        event = _event(username='master')
        self.assertIs(function.handler(event, None), event)

    def test_lookup_failure_fails_open(self):
        _reload()
        FAKE_COGNITO.error = RuntimeError('throttled')
        event = _event()
        self.assertIs(function.handler(event, None), event)


if __name__ == '__main__':
    unittest.main()
