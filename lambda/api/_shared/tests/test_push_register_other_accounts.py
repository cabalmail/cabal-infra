'''Unit tests for push_register's removal of other accounts' rows (#1883).

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_push_register_other_accounts.py

boto3 is faked in sys.modules before import, so the suite needs no AWS
access. Most tests use a table that records every call in order and answers
the device-token index query from a script; the race tests swap in a small
stateful table that keeps rows and evaluates the delete's sign-in condition.
The handler is loaded under a unique module name (#860/#863).

What these cover: one app install is signed in to one account at a time, so
registering a device token removes other accounts' rows for it. A sign-out
whose /push_deregister failed used to leave the old account's row behind,
and that account's pushes kept reaching the device after the next account
signed in. Only a row registered by an older sign-in is removed, so a late
request from the previous account can't remove the newer account's row. The
removal is best-effort: the caller's own row is written first, and a failed
lookup or delete never fails the registration. A last test reads Terraform,
so the index the handler queries and the one the table and role declare
can't drift apart unnoticed (the handler would swallow the error).
'''
import importlib.util
import json
import os
import re
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')

# --- fake boto3 --------------------------------------------------------------

CALLS = []


class _ConditionFailed(Exception):
    '''Stands in for botocore's ConditionalCheckFailedException.'''


class _ScriptedTable:
    '''Records calls in order. `pages` answers successive index queries;
    `fail_on` names operations that raise, and `fail_deletes_for` the row
    owners whose delete raises.'''

    def __init__(self):
        self.pages = []
        self.fail_on = set()
        self.fail_deletes_for = set()

    def update_item(self, **kwargs):  # pylint: disable=invalid-name
        CALLS.append(('update', kwargs))
        if 'update' in self.fail_on:
            raise RuntimeError('update failed')

    def query(self, **kwargs):  # pylint: disable=invalid-name
        CALLS.append(('query', kwargs))
        if 'query' in self.fail_on:
            raise RuntimeError('index is backfilling')
        return self.pages.pop(0) if self.pages else {'Items': []}

    def delete_item(self, **kwargs):  # pylint: disable=invalid-name
        CALLS.append(('delete', kwargs))
        if kwargs['Key']['user'] in self.fail_deletes_for:
            raise RuntimeError('throttled')


class _StatefulTable:
    '''Keeps rows by (user, device_token) and applies exactly the update,
    index query and conditional delete push_register issues.'''

    def __init__(self):
        self.rows = {}

    def update_item(self, Key=None, ExpressionAttributeValues=None, **_kwargs):  # pylint: disable=invalid-name
        row = self.rows.setdefault((Key['user'], Key['device_token']), dict(Key))
        if ':at' in ExpressionAttributeValues:
            row['auth_time'] = ExpressionAttributeValues[':at']

    def query(self, ExpressionAttributeValues=None, **_kwargs):  # pylint: disable=invalid-name
        token = ExpressionAttributeValues[':t']
        return {'Items': [{'user': user, 'device_token': tok}
                          for (user, tok) in self.rows if tok == token]}

    def delete_item(self, Key=None, ExpressionAttributeValues=None, **_kwargs):  # pylint: disable=invalid-name
        row = self.rows.get((Key['user'], Key['device_token']))
        if row is None:
            return
        if 'auth_time' in row and not row['auth_time'] < ExpressionAttributeValues[':at']:
            raise _ConditionFailed('ConditionalCheckFailedException')
        del self.rows[(Key['user'], Key['device_token'])]

    def users(self, token):
        '''The accounts registered for `token`, sorted.'''
        return sorted(user for (user, tok) in self.rows if tok == token)


_TABLE = _ScriptedTable()

_boto3 = types.ModuleType('boto3')
_boto3.resource = lambda _name, **_kw: types.SimpleNamespace(Table=lambda _n: _TABLE)
_boto3.client = lambda _name, **_kw: types.SimpleNamespace()
sys.modules['boto3'] = _boto3

# --- load the handler under a unique name ------------------------------------

_API = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_REPO = os.path.dirname(os.path.dirname(_API))
_PATH = os.path.join(_API, 'push_register', 'function.py')
_SPEC = importlib.util.spec_from_file_location('function_push_register_other_accounts', _PATH)
push_register = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = push_register
_SPEC.loader.exec_module(push_register)

# --- helpers -----------------------------------------------------------------

TOKEN = 'ab12' * 16
FCM_TOKEN = 'dXvQ9zRk4:APA91bFakeToken_-abcDEF1234567890'


def _register(user, token=TOKEN.upper(), auth_time='200', bundle_id='com.cabalmail.Cabalmail'):
    claims = {'cognito:username': user}
    if auth_time is not None:
        claims['auth_time'] = auth_time
    event = {
        'requestContext': {'authorizer': {'claims': claims}},
        'body': json.dumps({'bundle_id': bundle_id, 'device_token': token}),
    }
    return push_register.handler(event, None)


def _row(user, token=TOKEN):
    return {'user': user, 'device_token': token}


def _calls(kind):
    return [args for name, args in CALLS if name == kind]


def _deleted(token=TOKEN):
    return [call['Key']['user'] for call in _calls('delete') if call['Key']['device_token'] == token]


class PushRegisterOtherAccountsTests(unittest.TestCase):

    def setUp(self):
        CALLS.clear()
        _TABLE.pages = []
        _TABLE.fail_on = set()
        _TABLE.fail_deletes_for = set()
        push_register.table = _TABLE

    def test_registering_a_token_removes_another_accounts_row_for_it(self):
        _TABLE.pages = [{'Items': [_row('alice'), _row('bob')]}]

        response = _register('bob')

        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(_deleted(), ['alice'])
        query = _calls('query')[0]
        self.assertEqual(query['IndexName'], 'by_device_token')
        self.assertEqual(query['KeyConditionExpression'], '#t = :t')
        self.assertEqual(query['ExpressionAttributeNames'], {'#t': 'device_token'})
        self.assertEqual(query['ExpressionAttributeValues'], {':t': TOKEN},
                         'looked up by the normalized token the row is stored under')

    def test_only_an_older_sign_ins_row_is_removed(self):
        _TABLE.pages = [{'Items': [_row('alice')]}]

        _register('bob', auth_time='200')

        delete = _calls('delete')[0]
        self.assertEqual(delete['Key'], {'user': 'alice', 'device_token': TOKEN})
        self.assertEqual(delete['ConditionExpression'], 'attribute_not_exists(#at) OR #at < :at')
        self.assertEqual(delete['ExpressionAttributeNames'], {'#at': 'auth_time'})
        self.assertEqual(delete['ExpressionAttributeValues'], {':at': 200})

    def test_the_row_records_the_sign_in_that_registered_it(self):
        _register('bob', auth_time='200')

        update = _calls('update')[0]
        self.assertEqual(update['ExpressionAttributeNames']['#at'], 'auth_time')
        self.assertIn('#at = :at', update['UpdateExpression'])
        self.assertEqual(update['ExpressionAttributeValues'][':at'], 200)

    def test_a_token_without_a_sign_in_time_removes_only_unstamped_rows(self):
        _TABLE.pages = [{'Items': [_row('alice')]}]

        response = _register('bob', auth_time=None)

        self.assertEqual(response['statusCode'], 200)
        update = _calls('update')[0]
        self.assertNotIn('#at', update['ExpressionAttributeNames'])
        self.assertNotIn(':at', update['ExpressionAttributeValues'])
        self.assertEqual(_calls('delete')[0]['ExpressionAttributeValues'], {':at': 0})

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

        self.assertEqual(_deleted(), ['alice', 'carol'])
        self.assertEqual(_calls('query')[1]['ExclusiveStartKey'],
                         {'device_token': TOKEN, 'user': 'alice'})

    def test_an_android_token_is_looked_up_and_removed_case_preserved(self):
        _TABLE.pages = [{'Items': [_row('alice', FCM_TOKEN)]}]

        _register('bob', token=FCM_TOKEN, bundle_id='com.cabalmail.android')

        self.assertEqual(_calls('query')[0]['ExpressionAttributeValues'], {':t': FCM_TOKEN})
        self.assertEqual(_deleted(FCM_TOKEN), ['alice'])

    def test_a_failed_lookup_still_registers(self):
        _TABLE.fail_on = {'query'}

        response = _register('bob')

        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(len(_calls('update')), 1)
        self.assertEqual(_calls('delete'), [])

    def test_a_failed_removal_moves_on_and_still_registers(self):
        _TABLE.pages = [{'Items': [_row('alice'), _row('carol')]}]
        _TABLE.fail_deletes_for = {'alice'}

        response = _register('bob')

        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(json.loads(response['body']), {'status': 'registered'},
                         'the response is unchanged for older clients')
        self.assertEqual(_deleted(), ['alice', 'carol'], "alice's failure doesn't stop carol's")

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


class PushRegisterSignInOrderTests(unittest.TestCase):
    '''The same device across a sign-out whose deregistration failed, on a
    table that keeps rows and applies the delete's condition.'''

    def setUp(self):
        self.table = _StatefulTable()
        push_register.table = self.table

    def tearDown(self):
        push_register.table = _TABLE

    def test_the_next_account_replaces_the_one_whose_deregistration_failed(self):
        _register('alice', auth_time='100')

        _register('bob', auth_time='200')

        self.assertEqual(self.table.users(TOKEN), ['bob'])

    def test_a_late_request_from_the_previous_account_keeps_the_newer_row(self):
        _register('alice', auth_time='100')
        _register('bob', auth_time='200')

        _register('alice', auth_time='100')

        self.assertIn('bob', self.table.users(TOKEN), "alice's late request leaves bob registered")
        _register('bob', auth_time='200')
        self.assertEqual(self.table.users(TOKEN), ['bob'], "bob's next launch removes alice's row again")

    def test_a_row_from_before_sign_in_times_were_recorded_is_removed(self):
        self.table.rows[('alice', TOKEN)] = _row('alice')

        _register('bob', auth_time='200')

        self.assertEqual(self.table.users(TOKEN), ['bob'])


class PushRegisterIndexMatchesTerraformTests(unittest.TestCase):
    '''The handler swallows a query on an index that doesn't exist or isn't
    granted, so a rename on either side would quietly bring #1883 back.'''

    def _read(self, *parts):
        with open(os.path.join(_REPO, *parts), encoding='utf-8') as handle:
            return handle.read()

    def test_the_push_tokens_table_declares_the_index_on_device_token(self):
        source = self._read('terraform', 'infra', 'modules', 'table', 'main.tf')
        start = source.index('resource "aws_dynamodb_table" "push_tokens"')
        block = source[start:source.index('\nresource ', start + 1)]
        index = re.search(
            r'global_secondary_index\s*\{\s*name\s*=\s*"'
            + re.escape(push_register.DEVICE_TOKEN_INDEX)
            + r'"(.*?)projection_type\s*=\s*"(\w+)"',
            block, re.DOTALL)
        self.assertIsNotNone(index, 'cabal-push-tokens has no index the handler names')
        self.assertRegex(index.group(1),
                         r'attribute_name\s*=\s*"device_token"\s*key_type\s*=\s*"HASH"')
        self.assertNotIn('RANGE', index.group(1))
        self.assertEqual(index.group(2), 'KEYS_ONLY', 'carries the table keys the delete needs')

    def test_the_api_role_may_query_that_index(self):
        source = self._read('terraform', 'infra', 'modules', 'app', 'modules', 'call', 'lambda.tf')
        self.assertIn(f'table/cabal-push-tokens/index/{push_register.DEVICE_TOKEN_INDEX}"', source)


if __name__ == '__main__':
    unittest.main()
