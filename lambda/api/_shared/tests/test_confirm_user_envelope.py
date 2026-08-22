'''Unit tests pinning the confirm_user handler to the shared admin
user-management envelope.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_confirm_user_envelope.py

confirm_user carried its own copy of that envelope from #1200 until #1231: the
admin guard, the rate limit, the JSON-object body parse, the username lookup
inside the try, both audit lines and both wire shapes, differing from
disable_user only in which Cognito call it makes. Folding it in leaves the
handler as one delegation plus a four-line callback, and that delegation is
what these cases pin -- the three tokens it passes (`confirm_user` for the rate
limit and the audit line, `confirmed` for the status word, a callback reaching
admin_confirm_sign_up) and the exits they produce.

admin_user_action_response's own semantics are pinned next door in
test_admin_user_action_envelope.py; the point here is that this handler is
wired to it correctly, since a mis-wired fold is silent -- a copied `disabled`
status word or a callback left pointing at the wrong Cognito API answers 200
either way.

admin_limits.py's only third-party import is boto3, faked in sys.modules before
import so the suite needs no AWS access. The handler's own `cognito` client is
replaced on the loaded module rather than through the fake, so this suite
behaves the same standalone and under `unittest discover`, where a sibling may
have installed the boto3 fake first (#860).
'''
import importlib.util
import io
import json
import os
import pathlib
import sys
import types
import unittest
import contextlib

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('USER_POOL_ID', 'us-east-1_test')

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


def _load_handler(name):
    '''Loads lambda/api/<name>/function.py under a unique module name.

    Every deployed zip names its handler module `function`, so a plain
    `import function` lets whichever suite runs first win the `sys.modules`
    slot and hands every later suite the wrong handler (#860).
    '''
    path = os.path.join(os.path.dirname(_SHARED), name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'function_{name}', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


confirm = _load_handler('confirm_user')


class _FakeCognito:
    '''Records the Cognito calls the handler makes, by name and arguments.'''

    def __init__(self, raises=None):
        self.calls = []
        self.raises = raises

    def _record(self, api, kwargs):
        self.calls.append((api, kwargs))
        if self.raises:
            raise self.raises
        return {'ResponseMetadata': {'HTTPStatusCode': 200}}

    def admin_confirm_sign_up(self, **kwargs):  # pylint: disable=invalid-name
        return self._record('admin_confirm_sign_up', kwargs)

    def admin_disable_user(self, **kwargs):  # pylint: disable=invalid-name
        return self._record('admin_disable_user', kwargs)

    def admin_enable_user(self, **kwargs):  # pylint: disable=invalid-name
        return self._record('admin_enable_user', kwargs)


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


def _event(groups='admin', caller='rootadmin', body='{"username": "pending-user"}'):
    '''An API Gateway proxy event for an admin confirm call.'''
    return {
        'requestContext': {'authorizer': {'claims': {
            'cognito:username': caller,
            'cognito:groups': groups,
        }}},
        'body': body,
    }


class ConfirmUserEnvelopeTests(unittest.TestCase):
    '''Pins the delegation, not the envelope: the three tokens and the call.'''

    def setUp(self):
        self.cognito = _FakeCognito()
        self.original_cognito = confirm.cognito
        confirm.cognito = self.cognito
        self.original_table = admin_limits._rate_limit_table  # pylint: disable=protected-access
        self.set_rate_table(_RateTable())

    def tearDown(self):
        confirm.cognito = self.original_cognito
        admin_limits._rate_limit_table = self.original_table  # pylint: disable=protected-access

    def set_rate_table(self, table):
        '''Swaps the module-level table these tests drive.'''
        admin_limits._rate_limit_table = table  # pylint: disable=protected-access

    def run_handler(self, event):
        '''Runs the handler, returning (response, printed lines).'''
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            response = confirm.handler(event, None)
        return response, out.getvalue().splitlines()

    def test_success_confirms_the_named_signup(self):
        '''The happy path calls admin_confirm_sign_up and echoes `confirmed`.'''
        response, lines = self.run_handler(_event())
        self.assertEqual(response, {
            'statusCode': 200,
            'body': json.dumps({'status': 'confirmed', 'username': 'pending-user'})
        })
        self.assertEqual(self.cognito.calls, [('admin_confirm_sign_up', {
            'UserPoolId': 'us-east-1_test', 'Username': 'pending-user'})])
        self.assertEqual(lines, ['AUDIT ' + json.dumps({
            'action': 'confirm_user', 'caller': 'rootadmin',
            'outcome': 'success', 'target': 'pending-user'}, sort_keys=True)])

    def test_the_cognito_response_does_not_reach_the_client(self):
        '''The callback's return value is the envelope's to ignore.'''
        response, _ = self.run_handler(_event())
        self.assertEqual(json.loads(response['body']),
                         {'status': 'confirmed', 'username': 'pending-user'})

    def test_non_admin_is_refused_before_anything_runs(self):
        '''A 403 short-circuits the rate limit, the body parse and the call.'''
        self.set_rate_table(_RateTable(raises=True))
        response, lines = self.run_handler(_event(groups='users'))
        self.assertEqual(response, {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        })
        self.assertEqual(self.cognito.calls, [])
        self.assertEqual(lines, [])

    def test_rate_limited_audits_under_this_endpoints_own_action(self):
        '''Over the ceiling: 429, no Cognito call, and the audit line names
        confirm_user -- the token a fold is most likely to copy wrong.'''
        self.set_rate_table(_RateTable(count=admin_limits.RATE_LIMIT_MAX + 1))
        response, lines = self.run_handler(_event())
        self.assertEqual(response['statusCode'], 429)
        self.assertEqual(self.cognito.calls, [])
        self.assertEqual(lines, ['AUDIT ' + json.dumps({
            'action': 'confirm_user', 'caller': 'rootadmin',
            'outcome': 'rate_limited', 'target': ''}, sort_keys=True)])

    def test_invalid_body_is_a_400_with_no_audit_line(self):
        '''An unparseable body never reaches Cognito and is not audited.'''
        response, lines = self.run_handler(_event(body='not json'))
        self.assertEqual(response, {
            'statusCode': 400,
            'body': json.dumps(
                {'status': 'Invalid input: request body is not valid JSON'})
        })
        self.assertEqual(self.cognito.calls, [])
        self.assertEqual(lines, [])

    def test_missing_username_is_a_500_with_an_empty_target(self):
        '''A JSON object with no username 500s from inside the try, as it did
        when this handler carried the envelope itself.'''
        response, lines = self.run_handler(_event(body='{}'))
        self.assertEqual(response['statusCode'], 500)
        self.assertEqual(json.loads(response['body']), {'Error': "'username'"})
        self.assertEqual(self.cognito.calls, [])
        self.assertEqual(lines, ['AUDIT ' + json.dumps({
            'action': 'confirm_user', 'caller': 'rootadmin',
            'outcome': 'failure', 'target': ''}, sort_keys=True)])

    def test_cognito_failure_is_a_500_naming_the_target(self):
        '''When the Cognito call raises, the failure audit carries the username.'''
        self.cognito.raises = RuntimeError('User cannot be confirmed')
        response, lines = self.run_handler(_event())
        self.assertEqual(response, {
            'statusCode': 500,
            'body': json.dumps({'Error': 'User cannot be confirmed'})
        })
        self.assertEqual(lines, ['AUDIT ' + json.dumps({
            'action': 'confirm_user', 'caller': 'rootadmin',
            'outcome': 'failure', 'target': 'pending-user'}, sort_keys=True)])

    def test_the_handler_is_one_delegation(self):
        '''The point of the fold: the handler holds no envelope of its own, so
        a control cannot be dropped from this endpoint without dropping it from
        disable_user and enable_user too.'''
        source = pathlib.Path(
            os.path.dirname(_SHARED), 'confirm_user', 'function.py'
        ).read_text(encoding='utf-8')
        self.assertIn('admin_user_action_response(event, \'confirm_user\', \'confirmed\'',
                      source)
        for copied in ('admin_response_or_none', 'rate_limit_response_or_none',
                       'parse_json_object_body', 'audit_log', 'statusCode'):
            self.assertNotIn(copied, source, f'{copied} is the envelope\'s to run')


if __name__ == '__main__':
    unittest.main()
