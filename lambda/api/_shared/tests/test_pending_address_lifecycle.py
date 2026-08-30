'''Unit tests for the eager-create pending-address lifecycle
(docs/1.x/browser-extension-plan.md, Phase 3.1): /new storing the pending
marker, /confirm_address's owner check and idempotent already-confirmed path,
and the reap_pending_addresses TTL reaper's conditional delete.

No pytest harness in this repo; run under the stdlib:

    python3 -m unittest lambda/api/_shared/tests/test_pending_address_lifecycle.py
'''
import importlib.util
import json
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'control.example.com')
os.environ.setdefault('DOMAINS', json.dumps({
    'control.example.com': 'ZCONTROL',
    'mail.example.net': 'ZMAIL',
}))
os.environ.setdefault('USER_POOL_ID', 'us-east-1_test')
os.environ.setdefault('ADDRESS_CHANGED_TOPIC_ARN',
                      'arn:aws:sns:us-east-1:1:address-changed')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

# --- fake boto3 / botocore ---------------------------------------------------


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

_botocore = types.ModuleType("botocore")
_botocore_exceptions = types.ModuleType("botocore.exceptions")


class _ClientError(Exception):
    pass


_botocore_exceptions.ClientError = _ClientError
_botocore.exceptions = _botocore_exceptions
sys.modules.setdefault('botocore', _botocore)
sys.modules.setdefault('botocore.exceptions', _botocore_exceptions)

_imap_session = types.ModuleType("imap_session")
_imap_session.open_imap_client = lambda *_a, **_kw: None
sys.modules.setdefault('imap_session', _imap_session)

import helper  # noqa: E402  pylint: disable=wrong-import-position

# Whichever suite ran first owns the fake; raise with the class the handlers
# actually caught at import time.
ClientError = sys.modules['botocore.exceptions'].ClientError


def _conditional_check_failed():
    err = ClientError('ConditionalCheckFailedException')
    err.response = {'Error': {'Code': 'ConditionalCheckFailedException'}}
    return err


def _load_handler(name):
    '''Loads lambda/api/<name>/function.py under a unique module name (#860).'''
    path = os.path.join(os.path.dirname(_SHARED), name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'function_{name}', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


new = _load_handler('new')
confirm = _load_handler('confirm_address')
reaper = _load_handler('reap_pending_addresses')


class _FakeTable:
    '''Stands in for the cabal-addresses Table, recording every mutation and
    honoring the pending-only ConditionExpression the handlers use.'''

    def __init__(self, rows=None):
        self.rows = dict(rows or {})
        self.put_items = []
        self.update_calls = []
        self.delete_calls = []
        self.scan_pages = []

    def put_item(self, Item=None, **_kwargs):  # pylint: disable=invalid-name
        self.put_items.append(Item)
        self.rows[Item['address']] = Item

    def update_item(self, Key=None, **kwargs):  # pylint: disable=invalid-name
        self.update_calls.append((Key, kwargs))
        row = self.rows.get(Key['address'])
        if not row or not row.get('pending'):
            raise _conditional_check_failed()
        row.pop('pending', None)
        row.pop('pending_since', None)

    def delete_item(self, Key=None, **kwargs):  # pylint: disable=invalid-name
        self.delete_calls.append((Key, kwargs))
        row = self.rows.get(Key['address'])
        if kwargs.get('ConditionExpression') and (not row or not row.get('pending')):
            raise _conditional_check_failed()
        self.rows.pop(Key['address'], None)

    def scan(self, **_kwargs):
        return {'Items': self.scan_pages.pop(0) if self.scan_pages else []}


def _event(address, user='alice'):
    return {
        'requestContext': {'authorizer': {'claims': {
            'cognito:username': user,
        }}},
        'body': json.dumps({'address': address})
    }


class _Case(unittest.TestCase):
    '''Rebinds fakes on the handler modules (not on helper): the handlers
    import their helpers by name at module load (#913). The exception is
    helper.ddb_table -- authorized_address_request reads the ownership row
    through it per invocation -- which gets a read-only view of the same
    rows the handler-module fake mutates.'''

    def setUp(self):
        self.table = _FakeTable()
        self.notified = []
        self._saved_ddb = helper.ddb_table
        helper.ddb_table = types.SimpleNamespace(
            get_item=lambda Key=None, **_kw: (
                {'Item': self.table.rows[Key['address']]}
                if Key['address'] in self.table.rows else {}
            )
        )
        self._saved = {}
        for module, attrs in (
            (new, {
                'table': self.table,
                'notify_containers': lambda: self.notified.append('new'),
                'user_authorized_for_domain': lambda *_a: True,
                'publish_address_dns_records': lambda *_a: None,
            }),
            (confirm, {
                'table': self.table,
                'notify_containers': lambda: self.notified.append('confirm'),
            }),
            (reaper, {
                'table': self.table,
                'notify_containers': lambda: self.notified.append('reap'),
                'teardown_address_dns_if_unused': lambda *_a: None,
                'emit_metric': lambda _n: None,
            }),
        ):
            for attr, value in attrs.items():
                self._saved[(module, attr)] = getattr(module, attr)
                setattr(module, attr, value)

    def tearDown(self):
        helper.ddb_table = self._saved_ddb
        for (module, attr), value in self._saved.items():
            setattr(module, attr, value)


class NewPendingTests(_Case):
    '''/new stores the pending marker only when asked (Phase 3.1.a).'''

    def _create(self, extra=None):
        body = {'username': 'someone', 'subdomain': 'sales',
                'tld': 'mail.example.net'}
        body.update(extra or {})
        return new.handler({
            'requestContext': {'authorizer': {'claims': {
                'cognito:username': 'alice',
            }}},
            'body': json.dumps(body)
        }, None)

    def test_default_create_is_not_pending(self):
        response = self._create()
        self.assertEqual(response['statusCode'], 201)
        item = self.table.put_items[0]
        self.assertNotIn('pending', item)
        self.assertNotIn('pending_since', item)

    def test_pending_create_stores_marker_and_timestamp(self):
        response = self._create({'pending': True})
        self.assertEqual(response['statusCode'], 201)
        item = self.table.put_items[0]
        self.assertIs(item['pending'], True)
        self.assertEqual(item['pending_since'], item['RequestTime'])

    def test_non_boolean_pending_is_ignored(self):
        '''Only a JSON true opts in; a truthy string is not an opt-in.'''
        self._create({'pending': 'yes'})
        self.assertNotIn('pending', self.table.put_items[0])


class ConfirmAddressTests(_Case):
    '''/confirm_address: owner check, idempotent 409, reconfigure fan-out
    (Phase 3.1.b).'''

    ADDRESS = 'someone@sales.mail.example.net'

    def _row(self, pending=True, user='alice'):
        row = {'address': self.ADDRESS, 'subdomain': 'sales',
               'tld': 'mail.example.net', 'user': user}
        if pending:
            row['pending'] = True
            row['pending_since'] = '2026-08-29T00:00:00+00:00'
        self.table.rows[self.ADDRESS] = row
        return row

    def test_confirm_clears_pending_and_notifies(self):
        self._row()
        response = confirm.handler(_event(self.ADDRESS), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertNotIn('pending', self.table.rows[self.ADDRESS])
        self.assertNotIn('pending_since', self.table.rows[self.ADDRESS])
        self.assertEqual(self.notified, ['confirm'])

    def test_already_confirmed_is_409(self):
        self._row(pending=False)
        response = confirm.handler(_event(self.ADDRESS), None)
        self.assertEqual(response['statusCode'], 409)
        self.assertEqual(self.notified, [])

    def test_unowned_address_is_refused(self):
        self._row(user='mallory')
        response = confirm.handler(_event(self.ADDRESS), None)
        self.assertEqual(response['statusCode'], 403)
        self.assertIn('pending', self.table.rows[self.ADDRESS])

    def test_owner_check_is_exact_membership(self):
        '''"alice" must not pass as a member of "alicia/bob".'''
        self._row(user='alicia/bob')
        response = confirm.handler(_event(self.ADDRESS), None)
        self.assertEqual(response['statusCode'], 403)

    def test_co_assigned_owner_may_confirm(self):
        self._row(user='bob/alice')
        response = confirm.handler(_event(self.ADDRESS), None)
        self.assertEqual(response['statusCode'], 200)

    def test_concurrent_confirmation_is_success(self):
        '''The row flips to confirmed between the ownership read and the
        update (procmail hook winning the race): the conditional no-op must
        surface as success, not a 500.'''
        row = self._row()

        original = self.table.update_item

        def _flip_then_update(Key=None, **kwargs):  # pylint: disable=invalid-name
            row.pop('pending', None)
            return original(Key=Key, **kwargs)

        self.table.update_item = _flip_then_update
        response = confirm.handler(_event(self.ADDRESS), None)
        self.assertEqual(response['statusCode'], 200)


class ReaperTests(_Case):
    '''reap_pending_addresses: conditional delete, mid-scan confirmation,
    single reconfigure fan-out (Phase 3.1.c).'''

    def _expired(self, address):
        row = {'address': address, 'subdomain': address.split('@')[1].split('.')[0],
               'tld': 'mail.example.net', 'user': 'alice', 'pending': True,
               'pending_since': '2000-01-01T00:00:00+00:00'}
        self.table.rows[address] = row
        return row

    def test_reaps_expired_rows_and_notifies_once(self):
        first = self._expired('a@one.mail.example.net')
        second = self._expired('b@two.mail.example.net')
        self.table.scan_pages = [[dict(first), dict(second)]]
        response = reaper.handler(None, None)
        self.assertEqual(json.loads(response['body']),
                         {'scanned': 2, 'reaped': 2})
        self.assertEqual(self.table.rows, {})
        self.assertEqual(self.notified, ['reap'])

    def test_mid_scan_confirmation_is_skipped(self):
        row = self._expired('a@one.mail.example.net')
        scanned_copy = dict(row)
        row.pop('pending')  # confirmed between scan page and delete
        self.table.scan_pages = [[scanned_copy]]
        response = reaper.handler(None, None)
        self.assertEqual(json.loads(response['body']),
                         {'scanned': 1, 'reaped': 0})
        self.assertIn(row['address'], self.table.rows)
        self.assertEqual(self.notified, [])

    def test_quiet_run_notifies_nobody(self):
        response = reaper.handler(None, None)
        self.assertEqual(json.loads(response['body']),
                         {'scanned': 0, 'reaped': 0})
        self.assertEqual(self.notified, [])


if __name__ == '__main__':
    unittest.main()
