'''Unit tests for the admin-group guard now shared out of admin_limits.py.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_shared_admin_guard.py

admin_limits.py's only third-party import is boto3, faked in sys.modules
before import so the suite needs no AWS access. The cases pin the outcomes the
fifteen admin handlers relied on when each carried its own copy of the check:
the exact 403 wire shape, whole-element matching of the `cognito:groups` claim
in all three renderings API Gateway produces, and None (fall through to the
handler) for an admin caller.'''
import json
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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


def _event(groups_claim, include=True):
    '''An API Gateway proxy event carrying (or omitting) a cognito:groups claim.'''
    claims = {'cognito:username': 'someone'}
    if include:
        claims['cognito:groups'] = groups_claim
    return {'requestContext': {'authorizer': {'claims': claims}}}


class AdminGuardTests(unittest.TestCase):
    '''Pins the guard the admin handlers run before anything else.'''

    def test_admin_claim_falls_through(self):
        '''An admin caller gets None, i.e. the handler proceeds.'''
        for claim in ('admin', 'admin,users', '[admin users]', 'users,admin'):
            with self.subTest(claim=claim):
                self.assertIsNone(admin_limits.admin_response_or_none(_event(claim)))

    def test_non_admin_claim_is_denied(self):
        '''A caller without the group gets the 403 the handlers used to build.'''
        response = admin_limits.admin_response_or_none(_event('users'))
        self.assertEqual(response, {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        })

    def test_missing_claim_is_denied(self):
        '''No cognito:groups claim at all is a denial, not a KeyError.'''
        self.assertIsNotNone(admin_limits.admin_response_or_none(_event(None, include=False)))

    def test_substring_groups_are_not_admin(self):
        '''Whole-element matching: a group merely containing "admin" is denied.'''
        for claim in ('admin-readonly', 'nonadmin', '[nonadmin admin-readonly]', 'superadmin'):
            with self.subTest(claim=claim):
                self.assertIsNotNone(admin_limits.admin_response_or_none(_event(claim)))

    def test_is_admin_renderings(self):
        '''is_admin parses every claim rendering API Gateway emits.'''
        self.assertTrue(admin_limits.is_admin('admin'))
        self.assertTrue(admin_limits.is_admin('[admin]'))
        self.assertTrue(admin_limits.is_admin('users,admin,other'))
        self.assertFalse(admin_limits.is_admin(''))
        self.assertFalse(admin_limits.is_admin(None))


_INVALID_BODY = {
    'statusCode': 400,
    'body': json.dumps({'status': 'Invalid input: request body is not valid JSON'})
}


class ParseJsonObjectBodyTests(unittest.TestCase):
    '''Pins the body guard the six admin handlers each used to inline.

    Every rejection answers with one wording regardless of cause -- that is the
    pre-existing wire contract, and the reason this is not
    helper.parse_json_body (which distinguishes three causes).
    '''

    def test_json_object_is_returned(self):
        '''A JSON object decodes and reports no error.'''
        body, error = admin_limits.parse_json_object_body({'body': '{"username": "bob"}'})
        self.assertEqual(body, {'username': 'bob'})
        self.assertIsNone(error)

    def test_empty_object_is_valid(self):
        '''`{}` is a JSON object, so it passes -- key access fails later, as before.'''
        body, error = admin_limits.parse_json_object_body({'body': '{}'})
        self.assertEqual(body, {})
        self.assertIsNone(error)

    def test_bytes_body_decodes(self):
        '''json.loads accepts bytes; the guard must not reject them.'''
        body, error = admin_limits.parse_json_object_body({'body': b'{"username": "bob"}'})
        self.assertEqual(body, {'username': 'bob'})
        self.assertIsNone(error)

    def test_missing_empty_and_malformed_bodies_are_rejected(self):
        '''Absent, empty, and unparseable bodies all get the one 400.'''
        for event in ({}, {'body': None}, {'body': ''}, {'body': '   x'},
                      {'body': 'not json at all'}, {'body': '{'}, {'body': 123}):
            with self.subTest(event=event):
                body, error = admin_limits.parse_json_object_body(event)
                self.assertIsNone(body)
                self.assertEqual(error, _INVALID_BODY)

    def test_non_object_json_is_rejected(self):
        '''Valid JSON that is not an object is still a 400, not a later TypeError.'''
        for raw in ('null', '[]', '[1, 2]', '"a string"', '3', 'true', 'false'):
            with self.subTest(raw=raw):
                body, error = admin_limits.parse_json_object_body({'body': raw})
                self.assertIsNone(body)
                self.assertEqual(error, _INVALID_BODY)


if __name__ == '__main__':
    unittest.main()
