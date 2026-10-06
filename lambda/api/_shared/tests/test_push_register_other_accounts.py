'''Unit tests for push_register's removal of other accounts' rows (#1883).

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_push_register_other_accounts.py

boto3 is faked in sys.modules before import, so the suite needs no AWS
access; the table records every call in order and answers the device-token
index query from a script. The handler is loaded under a unique module name
(#860/#863).

What these cover: one app install is signed in to one account at a time, so
registering a device token removes every other account's row for it. A
sign-out whose /push_deregister failed used to leave the old account's row
behind, and that account's pushes kept reaching the device after the next
account signed in. The removal is best-effort: the caller's own row is
written first, and a failed lookup or delete never fails the registration.
'''
import importlib.util
import json
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')

# --- fake boto3 --------------------------------------------------------------

CALLS = []


class _ScriptedTable:
    '''Records calls in order. `pages` answers successive index queries;
    `fail_on` names an operation that raises instead.'''

    def __init__(self):
        self.pages = []
        self.fail_on = set()

    def update_item(self, **kwargs):  # pylint: disable=invalid-name
        CALLS.append(('update', kwargs))
        if 'update' in self.fail_on:
            raise RuntimeError('update failed')

    def query(self, **kwargs):  # pylint: disable=invalid-name
        CALLS.append(('query', kwargs))
        if 'query' in self.fail_on:
            raise RuntimeError('index is backfilling')
        return self.pages.pop(0) if self.pages else {'Items': []}

    def delete_item(self, Key=None, **_kwargs):  # pylint: disable=invalid-name
        CALLS.append(('delete', Key))
        if 'delete' in self.fail_on:
            raise RuntimeError('delete failed')


_TABLE = _ScriptedTable()

_boto3 = types.ModuleType('boto3')
_boto3.resource = lambda _name, **_kw: types.SimpleNamespace(Table=lambda _n: _TABLE)
_boto3.client = lambda _name, **_kw: types.SimpleNamespace()
sys.modules['boto3'] = _boto3

# --- load the handler under a unique name ------------------------------------

_API = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_PATH = os.path.join(_API, 'push_register', 'function.py')
_SPEC = importlib.util.spec_from_file_location('function_push_register_other_accounts', _PATH)
push_register = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = push_register
_SPEC.loader.exec_module(push_register)

# --- helpers -----------------------------------------------------------------

TOKEN = 'ab12' * 16


def _register(user, token=TOKEN.upper()):
    event = {
        'requestContext': {'authorizer': {'claims': {'cognito:username': user}}},
        'body': json.dumps({'bundle_id': 'com.cabalmail.Cabalmail', 'device_token': token}),
    }
    return push_register.handler(event, None)


def _row(user, token=TOKEN):
    return {'user': user, 'device_token': token}


def _calls(kind):
    return [args for name, args in CALLS if name == kind]


class PushRegisterOtherAccountsTests(unittest.TestCase):

    def setUp(self):
        CALLS.clear()
        _TABLE.pages = []
        _TABLE.fail_on = set()

    def test_registering_a_token_removes_another_accounts_row_for_it(self):
        _TABLE.pages = [{'Items': [_row('alice'), _row('bob')]}]

        response = _register('bob')

        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(_calls('delete'), [{'user': 'alice', 'device_token': TOKEN}])
        query = _calls('query')[0]
        self.assertEqual(query['IndexName'], 'by_device_token')
        self.assertEqual(query['ExpressionAttributeValues'], {':t': TOKEN},
                         'looked up by the normalized token the row is stored under')

    def test_the_callers_own_row_is_kept(self):
        _TABLE.pages = [{'Items': [_row('bob')]}]

        response = _register('bob')

        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(_calls('delete'), [])

    def test_the_callers_row_is_written_before_any_removal(self):
        _TABLE.pages = [{'Items': [_row('alice')]}]

        _register('bob')

        self.assertEqual([name for name, _ in CALLS], ['update', 'query', 'delete'])
        self.assertEqual(_calls('update')[0]['Key'], {'user': 'bob', 'device_token': TOKEN})

    def test_every_page_of_the_index_is_read(self):
        _TABLE.pages = [
            {'Items': [_row('alice')], 'LastEvaluatedKey': {'device_token': TOKEN, 'user': 'alice'}},
            {'Items': [_row('carol')]},
        ]

        _register('bob')

        self.assertEqual([key['user'] for key in _calls('delete')], ['alice', 'carol'])
        self.assertEqual(_calls('query')[1]['ExclusiveStartKey'],
                         {'device_token': TOKEN, 'user': 'alice'})

    def test_a_failed_lookup_still_registers(self):
        _TABLE.fail_on = {'query'}

        response = _register('bob')

        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(len(_calls('update')), 1)
        self.assertEqual(_calls('delete'), [])

    def test_a_failed_removal_still_registers(self):
        _TABLE.pages = [{'Items': [_row('alice')]}]
        _TABLE.fail_on = {'delete'}

        response = _register('bob')

        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(json.loads(response['body']), {'status': 'registered'},
                         'the response is unchanged for older clients')

    def test_a_failed_registration_removes_nothing(self):
        _TABLE.pages = [{'Items': [_row('alice')]}]
        _TABLE.fail_on = {'update'}

        response = _register('bob')

        self.assertEqual(response['statusCode'], 500)
        self.assertEqual(_calls('query'), [])
        self.assertEqual(_calls('delete'), [])

    def test_an_invalid_request_removes_nothing(self):
        _TABLE.pages = [{'Items': [_row('alice')]}]

        response = _register('bob', token='not a token')

        self.assertEqual(response['statusCode'], 400)
        self.assertEqual(CALLS, [])


if __name__ == '__main__':
    unittest.main()
