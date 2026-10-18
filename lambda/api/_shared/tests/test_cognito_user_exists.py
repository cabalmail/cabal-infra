'''Unit tests for admin_limits.cognito_user_exists, the Cognito
user-existence check the three admin handlers that need one now share.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_cognito_user_exists.py

admin_limits.py's only third-party import is boto3, faked in sys.modules
before import so the suite needs no AWS access; the fakes are guarded so
whichever suite `unittest discover` reaches first owns the module (#860).

What the cases pin: the two answers (True for a user the pool knows, False
for UserNotFoundException and nothing else), that the pool id reaching
admin_get_user is the caller's argument rather than anything read from the
environment here, and -- read off disk, so no handler import is needed --
that none of assign_address, new_address_admin or set_user_domain_access
has gone back to a private copy. The three copies were byte-identical apart
from one docstring's full stop, and each handler built its own
cognito-idp client to serve it.
'''
import os
import re
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_SHARED = os.path.dirname(_TESTS_DIR)
_API_DIR = os.path.dirname(_SHARED)
sys.path.insert(0, _SHARED)

# --- fake boto3 --------------------------------------------------------------


# Identical to the fake in the sibling suites on purpose; setdefault means
# whichever suite `unittest discover` reaches first owns the module (#860).
class _FakeSSMExceptions:
    class ParameterNotFound(Exception):
        pass


class _FakeSSM:
    exceptions = _FakeSSMExceptions

    def get_parameter(self, Name=None, **_kwargs):  # pylint: disable=invalid-name
        if Name == '/cabal/maintenance/imap':
            raise _FakeSSMExceptions.ParameterNotFound()
        return {"Parameter": {"Value": "fake-master-password"}}


class _FakeResource:
    def Table(self, _name):  # pylint: disable=invalid-name
        return types.SimpleNamespace()


_boto3 = types.ModuleType("boto3")
_boto3.resource = lambda _name, **_kw: _FakeResource()
_boto3.client = lambda name, **_kw: _FakeSSM() if name == 'ssm' else types.SimpleNamespace()
_boto3.session = types.SimpleNamespace(Config=lambda **_kw: None)
sys.modules.setdefault('boto3', _boto3)

import admin_limits  # noqa: E402  pylint: disable=wrong-import-position,import-error


class _UserNotFound(Exception):
    '''Stands in for the client-bound cognito-idp UserNotFoundException.'''


class _FakeCognito:
    '''Records every admin_get_user call and answers from a known-user set.'''

    exceptions = types.SimpleNamespace(UserNotFoundException=_UserNotFound)

    def __init__(self, known=(), raising=None):
        self.known = set(known)
        self.raising = raising
        self.calls = []

    def admin_get_user(self, UserPoolId=None, Username=None):  # pylint: disable=invalid-name
        self.calls.append((UserPoolId, Username))
        if self.raising is not None:
            raise self.raising
        if Username not in self.known:
            raise _UserNotFound(f'{Username} is not in the pool')
        return {'Username': Username}


class _CognitoCase(unittest.TestCase):
    '''Binds a fake cognito-idp client into admin_limits for the duration.'''

    def bind(self, client):
        saved = admin_limits._cognito  # pylint: disable=protected-access
        admin_limits._cognito = client  # pylint: disable=protected-access
        self.addCleanup(setattr, admin_limits, '_cognito', saved)
        return client


class CognitoUserExistsTest(_CognitoCase):
    '''The two answers, and what reaches Cognito to produce them.'''

    def test_a_known_user_exists(self):
        self.bind(_FakeCognito(known={'someone'}))
        self.assertIs(admin_limits.cognito_user_exists('pool-1', 'someone'), True)

    def test_an_unknown_user_does_not(self):
        self.bind(_FakeCognito(known={'someone'}))
        self.assertIs(admin_limits.cognito_user_exists('pool-1', 'nobody'), False)

    def test_the_callers_pool_id_is_the_one_queried(self):
        '''The pool id is an argument, not an env read in this module: a
        handler resolves USER_POOL_ID at import so a missing one fails the
        cold start, and the other admin_limits importers have none to read.'''
        client = self.bind(_FakeCognito(known={'someone'}))
        admin_limits.cognito_user_exists('pool-xyz', 'someone')
        self.assertEqual(client.calls, [('pool-xyz', 'someone')])

    def test_the_username_is_passed_through_unchanged(self):
        client = self.bind(_FakeCognito())
        admin_limits.cognito_user_exists('pool-1', 'Mixed.Case_user+tag')
        self.assertEqual(client.calls, [('pool-1', 'Mixed.Case_user+tag')])

    def test_only_user_not_found_is_absence(self):
        '''Any other client error propagates, so a handler's except-all turns
        it into its 500 rather than silently reporting "does not exist".'''
        boom = RuntimeError('throttled')
        self.bind(_FakeCognito(raising=boom))
        with self.assertRaises(RuntimeError):
            admin_limits.cognito_user_exists('pool-1', 'someone')

    def test_one_call_per_question(self):
        client = self.bind(_FakeCognito(known={'a'}))
        for name in ('a', 'b', 'a'):
            admin_limits.cognito_user_exists('pool-1', name)
        self.assertEqual([username for _pool, username in client.calls], ['a', 'b', 'a'])


# --- no handler keeps a private copy ----------------------------------------

_CALLERS = ('assign_address', 'new_address_admin', 'set_user_domain_access')
_LOCAL_DEF = re.compile(r'^def cognito_user_exists\(', re.MULTILINE)
_IMPORTS_IT = re.compile(r'^\s*cognito_user_exists,\s*$', re.MULTILINE)
_CALLS_IT = re.compile(r'\bcognito_user_exists\(\s*user_pool_id\s*,')
_OWN_CLIENT = re.compile(r"boto3\.client\(\s*'cognito-idp'\s*\)")


def _source(endpoint):
    with open(os.path.join(_API_DIR, endpoint, 'function.py'), encoding='utf-8') as handle:
        return handle.read()


class SharedCheckIsTheOnlyCopyTest(unittest.TestCase):
    '''Read off disk: no handler import, no third-party deps.'''

    def test_no_api_handler_defines_its_own(self):
        for name in sorted(os.listdir(_API_DIR)):
            path = os.path.join(_API_DIR, name, 'function.py')
            if not os.path.isfile(path):
                continue
            with self.subTest(handler=name):
                with open(path, encoding='utf-8') as handle:
                    self.assertIsNone(_LOCAL_DEF.search(handle.read()))

    def test_each_caller_imports_the_shared_one(self):
        for name in _CALLERS:
            with self.subTest(handler=name):
                self.assertRegex(_source(name), _IMPORTS_IT)

    def test_each_caller_passes_its_own_pool_id(self):
        for name in _CALLERS:
            with self.subTest(handler=name):
                self.assertRegex(_source(name), _CALLS_IT)

    def test_no_caller_still_builds_a_cognito_client(self):
        '''Each of the three built one solely to serve its own copy.'''
        for name in _CALLERS:
            with self.subTest(handler=name):
                self.assertIsNone(_OWN_CLIENT.search(_source(name)))


if __name__ == '__main__':
    unittest.main()
