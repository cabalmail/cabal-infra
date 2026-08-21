'''Unit tests for the admin user-management envelope shared out of
admin_limits.py.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_admin_user_action_envelope.py

The cases pin what disable_user and enable_user each answered when they carried
this envelope inline: the guard order (admin, then rate limit, then body, and
nothing downstream runs once one of them refuses), the audit line emitted on
every terminal path, and the 200/500 wire shapes. The callback's return value
being ignored is pinned too -- the handlers pass a plain function today, but the
envelope must keep ignoring it or a caller that returned its boto3 response
would start relaying it to the client.

admin_limits.py's only third-party import is boto3, faked in sys.modules before
import so the suite needs no AWS access. The rate-limit table is swapped per
test on the imported module rather than via the fake, so these cases behave the
same standalone and under `unittest discover` (where a sibling suite may have
installed the boto3 fake first -- #860).
'''
import io
import json
import os
import sys
import types
import unittest
import contextlib

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


class _RateTable:
    '''Stands in for cabal-rate-limits: returns `count`, or raises to exercise
    the fail-open path.'''

    def __init__(self, count=1, raises=False):
        self.count = count
        self.raises = raises

    def update_item(self, **_kwargs):  # pylint: disable=invalid-name
        if self.raises:
            raise RuntimeError('rate table unavailable')
        return {'Attributes': {'count': self.count}}


def _event(groups='admin', caller='rootadmin', body='{"username": "victim"}'):
    '''An API Gateway proxy event for an admin user-management call.'''
    return {
        'requestContext': {'authorizer': {'claims': {
            'cognito:username': caller,
            'cognito:groups': groups,
        }}},
        'body': body,
    }


class AdminUserActionEnvelopeTests(unittest.TestCase):
    '''Pins the envelope disable_user and enable_user now share.'''

    def setUp(self):
        self.seen = []
        self.raises = None
        self.original_table = admin_limits._rate_limit_table  # pylint: disable=protected-access
        self.set_rate_table(_RateTable())

    def tearDown(self):
        admin_limits._rate_limit_table = self.original_table  # pylint: disable=protected-access

    def set_rate_table(self, table):
        '''Swaps the module-level table these tests drive.'''
        admin_limits._rate_limit_table = table  # pylint: disable=protected-access

    def operate(self, username):
        '''The callback under test: records the call, optionally raises.'''
        self.seen.append(username)
        if self.raises:
            raise self.raises
        return {'ResponseMetadata': {'HTTPStatusCode': 200}}

    def run_envelope(self, event, action='disable_user', status='disabled'):
        '''Runs the envelope, returning (response, printed lines).'''
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            response = admin_limits.admin_user_action_response(
                event, action, status, self.operate)
        return response, out.getvalue().splitlines()

    def test_success_returns_status_and_username(self):
        '''The happy path echoes the status word and the target username.'''
        response, lines = self.run_envelope(_event())
        self.assertEqual(response, {
            'statusCode': 200,
            'body': json.dumps({'status': 'disabled', 'username': 'victim'})
        })
        self.assertEqual(self.seen, ['victim'])
        self.assertEqual(lines, ['AUDIT ' + json.dumps({
            'action': 'disable_user', 'caller': 'rootadmin',
            'outcome': 'success', 'target': 'victim'}, sort_keys=True)])

    def test_callback_return_value_is_ignored(self):
        '''operate() returning a boto3-shaped dict does not reach the client.'''
        response, _ = self.run_envelope(_event())
        self.assertEqual(json.loads(response['body']),
                         {'status': 'disabled', 'username': 'victim'})

    def test_non_admin_stops_before_everything(self):
        '''A 403 short-circuits the rate limit, the body parse and the call.'''
        self.set_rate_table(_RateTable(raises=True))
        response, lines = self.run_envelope(_event(groups='users'))
        self.assertEqual(response, {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        })
        self.assertEqual(self.seen, [])
        self.assertEqual(lines, [])

    def test_rate_limited_stops_before_the_body(self):
        '''Over the ceiling: 429, one rate_limited audit line, no API call.'''
        self.set_rate_table(_RateTable(count=admin_limits.RATE_LIMIT_MAX + 1))
        response, lines = self.run_envelope(_event(body='not json'))
        self.assertEqual(response['statusCode'], 429)
        self.assertEqual(self.seen, [])
        self.assertEqual(lines, ['AUDIT ' + json.dumps({
            'action': 'disable_user', 'caller': 'rootadmin',
            'outcome': 'rate_limited', 'target': ''}, sort_keys=True)])

    def test_at_the_ceiling_is_still_allowed(self):
        '''The limit is inclusive: the Nth call in a window still goes through.'''
        self.set_rate_table(_RateTable(count=admin_limits.RATE_LIMIT_MAX))
        response, _ = self.run_envelope(_event())
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(self.seen, ['victim'])

    def test_rate_limit_failure_fails_open(self):
        '''A broken rate-limit table cannot lock admins out of the endpoint.'''
        self.set_rate_table(_RateTable(raises=True))
        response, _ = self.run_envelope(_event())
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(self.seen, ['victim'])

    def test_invalid_body_is_a_400_with_no_audit_line(self):
        '''An unparseable body never reaches the API call and is not audited.'''
        for body in (None, '', 'not json', '[]', '"str"'):
            with self.subTest(body=body):
                self.seen = []
                response, lines = self.run_envelope(_event(body=body))
                self.assertEqual(response, {
                    'statusCode': 400,
                    'body': json.dumps(
                        {'status': 'Invalid input: request body is not valid JSON'})
                })
                self.assertEqual(self.seen, [])
                self.assertEqual(lines, [])

    def test_missing_username_is_a_500_with_an_empty_target(self):
        '''A JSON object with no username 500s from inside the try, as before,
        and audits a failure whose target is the empty seed.'''
        response, lines = self.run_envelope(_event(body='{}'))
        self.assertEqual(response['statusCode'], 500)
        self.assertEqual(json.loads(response['body']), {'Error': "'username'"})
        self.assertEqual(self.seen, [])
        self.assertEqual(lines, ['AUDIT ' + json.dumps({
            'action': 'disable_user', 'caller': 'rootadmin',
            'outcome': 'failure', 'target': ''}, sort_keys=True)])

    def test_api_failure_is_a_500_naming_the_target(self):
        '''When the API call raises, the failure audit carries the username.'''
        self.raises = RuntimeError('user not found')
        response, lines = self.run_envelope(_event())
        self.assertEqual(response, {
            'statusCode': 500,
            'body': json.dumps({'Error': 'user not found'})
        })
        self.assertEqual(lines, ['AUDIT ' + json.dumps({
            'action': 'disable_user', 'caller': 'rootadmin',
            'outcome': 'failure', 'target': 'victim'}, sort_keys=True)])

    def test_action_and_status_are_the_callers_to_vary(self):
        '''The enable_user wiring produces enable_user's wire and audit words.'''
        response, lines = self.run_envelope(
            _event(), action='enable_user', status='enabled')
        self.assertEqual(json.loads(response['body']),
                         {'status': 'enabled', 'username': 'victim'})
        self.assertIn('"action": "enable_user"', lines[0])


if __name__ == '__main__':
    unittest.main()
