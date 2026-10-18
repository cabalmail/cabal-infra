'''Unit tests for the two create endpoints, /new and /new_address_admin, when
the address they are asked for already has a row.

No pytest harness in this repo; run under the stdlib:

    python3 -m unittest lambda/api/_shared/tests/test_address_create_existing.py

The cabal-addresses table is keyed on the address, case-sensitively, while the
mail tier folds addresses to lower case. Both endpoints fold the address they
create and find a stored row in any case through the one shared lookup,
helper.stored_address_row_or_none. /new answers a create that matches a stored
row without writing: 201 when the row is the caller's own and spelled the same,
409 otherwise. The admin route answers any stored row with a 409 that points
the admin to Assign, whoever owns it. Both puts are conditional as well, for a
create of the same address, in any case, that lands between the read and the
write.
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

# Whichever suite ran first owns the fake; raise with the class the handler
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
new_admin = _load_handler('new_address_admin')
helper = sys.modules['helper']

ADDRESS = 'someone@sales.mail.example.net'


class _FakeTable:
    '''Stands in for the cabal-addresses Table: a case-sensitive key, a put
    that honors `attribute_not_exists(address)`, and a scan that pages.'''

    def __init__(self, page_size=100):
        self.rows = {}
        self.page_size = page_size
        self.puts = []
        self.scans = 0
        # Rows that land after the handler's read and before its put, standing
        # in for a concurrent create.
        self.landing = []

    def put_item(self, Item=None, **kwargs):  # pylint: disable=invalid-name
        for row in self.landing:
            self.rows[row['address']] = row
        self.landing = []
        if kwargs.get('ConditionExpression') == 'attribute_not_exists(address)' \
                and Item['address'] in self.rows:
            raise _conditional_check_failed()
        self.puts.append(Item)
        self.rows[Item['address']] = Item

    def scan(self, ExclusiveStartKey=None, **_kwargs):  # pylint: disable=invalid-name
        self.scans += 1
        keys = sorted(self.rows)
        start = keys.index(ExclusiveStartKey['address']) + 1 if ExclusiveStartKey else 0
        page = keys[start:start + self.page_size]
        response = {'Items': [
            {'address': key, 'user': self.rows[key]['user']} for key in page
        ]}
        if start + self.page_size < len(keys):
            response['LastEvaluatedKey'] = {'address': page[-1]}
        return response


def _row(address=ADDRESS, user='bob', **extra):
    row = {'address': address, 'tld': 'mail.example.net', 'user': user,
           'username': address.split('@')[0], 'subdomain': 'sales',
           'comment': 'stored', 'RequestTime': '2026-01-01T00:00:00+00:00'}
    row.update(extra)
    return row


def _create(user='alice', username='someone', subdomain='sales', **extra):
    body = {'username': username, 'subdomain': subdomain,
            'tld': 'mail.example.net'}
    body.update(extra)
    return new.handler({
        'requestContext': {'authorizer': {'claims': {
            'cognito:username': user,
        }}},
        'body': json.dumps(body)
    }, None)


class _Case(unittest.TestCase):
    '''Rebinds the fakes on the handler module, which imports its helpers by
    name at load (#913).'''

    def setUp(self):
        self.table = _FakeTable()
        self.published = []
        self.notified = []
        self._saved = {}
        for attr, value in {
            'table': self.table,
            'notify_containers': lambda: self.notified.append(True),
            'user_authorized_for_domain': lambda *_a: True,
            'publish_address_dns_records': lambda *a: self.published.append(a),
        }.items():
            self._saved[attr] = getattr(new, attr)
            setattr(new, attr, value)

    def tearDown(self):
        for attr, value in self._saved.items():
            setattr(new, attr, value)

    def assert_nothing_written(self):
        self.assertEqual(self.table.puts, [])
        self.assertEqual(self.published, [])
        self.assertEqual(self.notified, [])

    def assert_conflict(self, response):
        self.assertEqual(response['statusCode'], 409)
        body = json.loads(response['body'])
        self.assertEqual(body['Error'], body['message'])
        return body['message']


class NewAddressTests(_Case):
    '''An address nobody has is created as before.'''

    def test_a_new_address_is_created(self):
        response = _create()
        self.assertEqual(response['statusCode'], 201)
        self.assertEqual(json.loads(response['body']), {'address': ADDRESS})
        self.assertEqual(self.table.rows[ADDRESS]['user'], 'alice')
        self.assertEqual(len(self.published), 1)
        self.assertEqual(self.notified, [True])

    def test_the_address_is_created_in_lower_case(self):
        response = _create(username='SomeOne', subdomain='Sales')
        self.assertEqual(response['statusCode'], 201)
        self.assertEqual(json.loads(response['body']), {'address': ADDRESS})
        self.assertEqual(list(self.table.rows), [ADDRESS])
        self.assertEqual(self.table.rows[ADDRESS]['username'], 'someone')
        self.assertEqual(self.table.rows[ADDRESS]['subdomain'], 'sales')
        self.assertEqual(self.published[0][1], 'sales')

    def test_a_failed_read_creates_nothing(self):
        def _fail(**_kwargs):
            raise ClientError('ProvisionedThroughputExceededException')
        self.table.scan = _fail
        response = _create()
        self.assertEqual(response['statusCode'], 500)
        self.assert_nothing_written()


class AnotherAccountsAddressTests(_Case):
    '''An address that belongs to someone else is refused and left alone.'''

    def test_it_is_refused_and_the_row_is_unchanged(self):
        stored = _row()
        self.table.rows[ADDRESS] = dict(stored)
        message = self.assert_conflict(_create())
        self.assertIn(ADDRESS, message)
        self.assertEqual(self.table.rows[ADDRESS], stored)
        self.assert_nothing_written()

    def test_a_case_variant_is_refused(self):
        self.table.rows[ADDRESS] = _row()
        self.assert_conflict(_create(username='Someone', subdomain='SALES'))
        self.assertEqual(list(self.table.rows), [ADDRESS])
        self.assert_nothing_written()

    def test_a_stored_case_variant_is_refused(self):
        stored = 'Someone@Sales.mail.example.net'
        self.table.rows[stored] = _row(address=stored)
        self.assert_conflict(_create())
        self.assertEqual(list(self.table.rows), [stored])
        self.assert_nothing_written()

    def test_owner_match_is_exact_membership(self):
        '''"alice" is not an owner of a row stored for "alicia".'''
        self.table.rows[ADDRESS] = _row(user='alicia/bob')
        self.assert_conflict(_create())
        self.assertEqual(self.table.rows[ADDRESS]['user'], 'alicia/bob')

    def test_a_row_on_a_later_scan_page_is_found(self):
        self.table.page_size = 1
        for name in ('a', 'b', 'c'):
            address = f'{name}@sales.mail.example.net'
            self.table.rows[address] = _row(address=address)
        self.table.rows[ADDRESS] = _row()
        self.assert_conflict(_create())
        self.assertEqual(self.table.scans, 4)
        self.assert_nothing_written()

    def test_a_create_that_lands_first_is_kept(self):
        '''Bob's create lands between Alice's read and her put.'''
        self.table.landing = [_row()]
        self.assert_conflict(_create())
        self.assertEqual(self.table.rows[ADDRESS]['user'], 'bob')
        self.assertEqual(self.table.puts, [])
        self.assertEqual(self.notified, [])

    def test_a_case_variant_that_lands_first_is_kept(self):
        '''Bob creates 'someone' while Alice creates 'Someone'.'''
        self.table.landing = [_row()]
        self.assert_conflict(_create(username='Someone', subdomain='SALES'))
        self.assertEqual(list(self.table.rows), [ADDRESS])
        self.assertEqual(self.table.rows[ADDRESS]['user'], 'bob')
        self.assertEqual(self.table.puts, [])
        self.assertEqual(self.notified, [])


class OwnAddressTests(_Case):
    '''Repeating a create of one's own address changes nothing.'''

    def test_a_repeat_create_writes_nothing(self):
        stored = _row(user='alice', favorites={'alice'}, suspended=True)
        self.table.rows[ADDRESS] = dict(stored)
        response = _create(comment='changed', pending=True)
        self.assertEqual(response['statusCode'], 201)
        self.assertEqual(json.loads(response['body']), {'address': ADDRESS})
        self.assertEqual(self.table.rows[ADDRESS], stored)
        self.assert_nothing_written()

    def test_a_co_owner_keeps_the_other_owners(self):
        self.table.rows[ADDRESS] = _row(user='bob/alice')
        response = _create()
        self.assertEqual(response['statusCode'], 201)
        self.assertEqual(self.table.rows[ADDRESS]['user'], 'bob/alice')
        self.assert_nothing_written()

    def test_a_case_variant_names_the_stored_address(self):
        stored = 'Someone@sales.mail.example.net'
        self.table.rows[stored] = _row(address=stored, user='alice')
        message = self.assert_conflict(_create())
        self.assertIn(stored, message)
        self.assertEqual(list(self.table.rows), [stored])
        self.assert_nothing_written()

    def test_ones_own_create_that_lands_first_is_success(self):
        '''A repeat of the same create lands between the read and the put.'''
        self.table.landing = [_row(user='alice')]
        response = _create()
        self.assertEqual(response['statusCode'], 201)
        self.assertEqual(self.table.puts, [])
        self.assertEqual(self.notified, [])


def _admin_create(usernames=('alice',), username='someone', subdomain='sales', **extra):
    body = {'username': username, 'subdomain': subdomain,
            'tld': 'mail.example.net', 'usernames': list(usernames)}
    body.update(extra)
    return new_admin.handler({
        'requestContext': {'authorizer': {'claims': {
            'cognito:username': 'admin',
            'cognito:groups': 'admin',
        }}},
        'body': json.dumps(body)
    }, None)


class _AdminCase(_Case):
    '''Binds the same fakes into the admin route, plus its admin guards.'''

    def setUp(self):
        super().setUp()
        self.audits = []
        self._admin_saved = {}
        for attr, value in {
            'table': self.table,
            'notify_containers': lambda: self.notified.append(True),
            'user_authorized_for_domain': lambda *_a: True,
            'publish_address_dns_records': lambda *a: self.published.append(a),
            'cognito_user_exists': lambda _u: True,
            'admin_response_or_none': lambda _e: None,
            'rate_limit_response_or_none': lambda *_a: None,
            'audit_log': lambda *a: self.audits.append(a[3]),
        }.items():
            self._admin_saved[attr] = getattr(new_admin, attr)
            setattr(new_admin, attr, value)

    def tearDown(self):
        for attr, value in self._admin_saved.items():
            setattr(new_admin, attr, value)
        super().tearDown()

    def assert_refused(self, response, named=ADDRESS):
        message = self.assert_conflict(response)
        self.assertIn(named, message)
        self.assertIn('Assign', message)
        self.assertEqual(self.audits, ['refused'])
        return message


class AdminNewAddressTests(_AdminCase):
    '''An address nobody has is created for the named users, in lower case.'''

    def test_a_new_address_is_created(self):
        response = _admin_create()
        self.assertEqual(response['statusCode'], 201)
        self.assertEqual(json.loads(response['body']), {'address': ADDRESS, 'user': 'alice'})
        self.assertEqual(self.table.rows[ADDRESS]['user'], 'alice')
        self.assertEqual(len(self.published), 1)
        self.assertEqual(self.notified, [True])
        self.assertEqual(self.audits, ['success'])

    def test_a_shared_address_is_created_for_every_user(self):
        response = _admin_create(usernames=('alice', 'bob'))
        self.assertEqual(response['statusCode'], 201)
        self.assertEqual(self.table.rows[ADDRESS]['user'], 'alice/bob')

    def test_the_address_is_created_in_lower_case(self):
        response = _admin_create(username='SomeOne', subdomain='Sales')
        self.assertEqual(response['statusCode'], 201)
        self.assertEqual(json.loads(response['body'])['address'], ADDRESS)
        self.assertEqual(list(self.table.rows), [ADDRESS])
        self.assertEqual(self.table.rows[ADDRESS]['username'], 'someone')
        self.assertEqual(self.table.rows[ADDRESS]['subdomain'], 'sales')
        self.assertEqual(self.published[0][1], 'sales')

    def test_a_failed_read_creates_nothing(self):
        def _fail(**_kwargs):
            raise ClientError('ProvisionedThroughputExceededException')
        self.table.scan = _fail
        response = _admin_create()
        self.assertEqual(response['statusCode'], 500)
        self.assert_nothing_written()
        self.assertEqual(self.audits, ['failure'])


class AdminExistingAddressTests(_AdminCase):
    '''An address that already has a row is refused and left alone, whoever
    owns it: changing who may use an address is Assign's job.'''

    def test_another_users_address_is_refused_and_unchanged(self):
        stored = _row(favorites={'bob'}, pending=True)
        self.table.rows[ADDRESS] = dict(stored)
        self.assert_refused(_admin_create())
        self.assertEqual(self.table.rows[ADDRESS], stored)
        self.assert_nothing_written()

    def test_a_named_users_own_address_is_refused_too(self):
        stored = _row(user='alice')
        self.table.rows[ADDRESS] = dict(stored)
        self.assert_refused(_admin_create(usernames=('alice', 'bob'), comment='changed'))
        self.assertEqual(self.table.rows[ADDRESS], stored)
        self.assert_nothing_written()

    def test_a_case_variant_is_refused(self):
        self.table.rows[ADDRESS] = _row()
        self.assert_refused(_admin_create(username='Someone', subdomain='SALES'))
        self.assertEqual(list(self.table.rows), [ADDRESS])
        self.assert_nothing_written()

    def test_a_stored_case_variant_is_refused_and_named(self):
        stored = 'Someone@Sales.mail.example.net'
        self.table.rows[stored] = _row(address=stored)
        self.assert_refused(_admin_create(), named=stored)
        self.assertEqual(list(self.table.rows), [stored])
        self.assert_nothing_written()

    def test_a_row_on_a_later_scan_page_is_found(self):
        self.table.page_size = 1
        for name in ('a', 'b', 'c'):
            address = f'{name}@sales.mail.example.net'
            self.table.rows[address] = _row(address=address)
        self.table.rows[ADDRESS] = _row()
        self.assert_refused(_admin_create())
        self.assertEqual(self.table.scans, 4)
        self.assert_nothing_written()

    def test_a_create_that_lands_first_is_kept(self):
        '''A user's create lands between the admin's read and put.'''
        self.table.landing = [_row()]
        self.assert_refused(_admin_create(username='Someone'))
        self.assertEqual(list(self.table.rows), [ADDRESS])
        self.assertEqual(self.table.rows[ADDRESS]['user'], 'bob')
        self.assertEqual(self.table.puts, [])
        self.assertEqual(self.notified, [])


class StoredAddressLookupTests(unittest.TestCase):
    '''helper.stored_address_row_or_none, the one lookup both endpoints use.'''

    def setUp(self):
        self.table = _FakeTable(page_size=2)

    def test_nothing_stored_is_none(self):
        self.assertIsNone(helper.stored_address_row_or_none(self.table, ADDRESS))

    def test_a_match_in_any_case_returns_the_stored_row(self):
        stored = 'SomeOne@SALES.mail.example.net'
        self.table.rows[stored] = _row(address=stored, user='bob/carol')
        row = helper.stored_address_row_or_none(self.table, ADDRESS)
        self.assertEqual(row, {'address': stored, 'user': 'bob/carol'})

    def test_a_different_address_is_not_a_match(self):
        self.table.rows['someone@sales2.mail.example.net'] = _row(
            address='someone@sales2.mail.example.net')
        self.assertIsNone(helper.stored_address_row_or_none(self.table, ADDRESS))

    def test_the_scan_stops_at_the_first_match(self):
        for name in ('a', 'b', 'c', 'd', 'e'):
            address = f'{name}@sales.mail.example.net'
            self.table.rows[address] = _row(address=address)
        helper.stored_address_row_or_none(self.table, 'b@sales.mail.example.net')
        self.assertEqual(self.table.scans, 1)


if __name__ == '__main__':
    unittest.main()
