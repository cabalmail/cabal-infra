'''Unit tests for authorized_address_request, the shared preamble behind the
address-lifecycle endpoints (revoke, suspend_address, reinstate_address), and
for the user_authorized_for_sender wrapper that now sits on the same lookup.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_authorized_address_request.py

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, so the suite needs no AWS access. The cases pin the
outcomes the three handlers relied on before the preamble was shared: the 403
wire shape, a failed lookup reported as unauthorized rather than raised, the
relayed 400 from parse_json_body, the KeyError a body with no `address` has
always raised -- and that an authorized request costs exactly one read, since
the handlers no longer re-fetch the row the check already loaded.'''
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

# --- fake boto3 / botocore ---------------------------------------------------


# Identical to the fake in the sibling suites on purpose. This file sorts first
# under `unittest discover`, so its fakes are usually the ones every later suite
# inherits (#860); a leaner fake here fails them, not this one.
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


class _LookupFailure(Exception):
    '''Carries the `.response` shape helper reads off a botocore ClientError.'''

    def __init__(self):
        super().__init__('throttled')
        self.response = {'Error': {'Message': 'throttled'}}


class _FakeTable:
    '''Stands in for the cabal-addresses Table, counting reads.'''

    def __init__(self):
        self.rows = {}
        self.raise_on_get = False
        self.get_calls = 0

    def get_item(self, Key=None, **_kwargs):  # pylint: disable=invalid-name
        self.get_calls += 1
        if self.raise_on_get:
            raise _LookupFailure()
        address = Key['address']
        if address in self.rows:
            return {'Item': self.rows[address]}
        return {}


class _TableCase(unittest.TestCase):
    '''Binds the fake table, and points helper's `except ClientError` at the
    fake table's failure. Rebinding rather than relying on the sys.modules fake
    keeps this correct under a directory-wide `discover` run, where a sibling
    suite's fake may already have won the import (#860).'''

    def setUp(self):
        self.table = _FakeTable()
        self._saved = (helper.ddb_table, helper.ClientError)
        helper.ddb_table = self.table
        helper.ClientError = _LookupFailure

    def tearDown(self):
        helper.ddb_table, helper.ClientError = self._saved


def _event(address='user@sub.example.com', user='alice', body=...):
    '''Builds an API Gateway event; `body` overrides the JSON body wholesale.'''
    import json  # pylint: disable=import-outside-toplevel
    if body is ...:
        body = json.dumps({'address': address})
    return {
        'body': body,
        'requestContext': {'authorizer': {'claims': {'cognito:username': user}}}
    }


class AuthorizedAddressRequestTest(_TableCase):
    def test_authorized_returns_the_stored_row_in_one_read(self):
        row = {'address': 'user@sub.example.com', 'user': 'alice',
               'subdomain': 'sub', 'tld': 'example.com', 'suspended': True}
        self.table.rows['user@sub.example.com'] = row
        address, item, error = helper.authorized_address_request(_event())
        self.assertIsNone(error)
        self.assertEqual(address, 'user@sub.example.com')
        self.assertEqual(item, row)
        # The handlers read subdomain/tld/suspended off this row instead of
        # issuing a second get_item for it.
        self.assertEqual(self.table.get_calls, 1)

    def test_row_owned_by_another_user_is_403(self):
        self.table.rows['user@sub.example.com'] = {'user': 'bob'}
        address, item, error = helper.authorized_address_request(_event())
        self.assertIsNone(address)
        self.assertIsNone(item)
        self.assertEqual(error['statusCode'], 403)
        self.assertIn('not associated with authenticated user', error['body'])

    def test_missing_row_is_403(self):
        _, _, error = helper.authorized_address_request(_event())
        self.assertEqual(error['statusCode'], 403)

    def test_row_without_a_user_attribute_is_403(self):
        self.table.rows['user@sub.example.com'] = {'subdomain': 'sub'}
        _, _, error = helper.authorized_address_request(_event())
        self.assertEqual(error['statusCode'], 403)

    def test_lookup_failure_is_403_not_a_traceback(self):
        self.table.raise_on_get = True
        _, _, error = helper.authorized_address_request(_event())
        self.assertEqual(error['statusCode'], 403)

    def test_malformed_body_relays_the_parse_error(self):
        for body in (None, '', '{not json', '[1, 2]'):
            with self.subTest(body=body):
                address, item, error = helper.authorized_address_request(
                    _event(body=body))
                self.assertIsNone(address)
                self.assertIsNone(item)
                self.assertEqual(error['statusCode'], 400)
        self.assertEqual(self.table.get_calls, 0)

    def test_body_without_an_address_still_raises_key_error(self):
        # Pre-existing contract: the handlers never guarded this, and a caller
        # that omits `address` gets a Lambda error rather than a 4xx.
        with self.assertRaises(KeyError):
            helper.authorized_address_request(_event(body='{"nothing": 1}'))


class MultiUserAddressTest(_TableCase):
    '''#913: `user` is slash-delimited once an address is co-assigned, so the
    check has to test membership. Under the old `==` a multi-user row
    authorized nobody -- not the co-assignee, and not the original owner
    either -- while /list and set_favorite (which split on `/`) went on
    treating every assignee as an owner.'''

    def setUp(self):
        super().setUp()
        self.table.rows['shared@x.example'] = {'user': 'alice/bob/carol'}

    def test_every_assignee_is_authorized(self):
        for user in ('alice', 'bob', 'carol'):
            with self.subTest(user=user):
                self.assertTrue(
                    helper.user_authorized_for_sender(user, 'shared@x.example'))

    def test_an_unassigned_user_is_still_refused(self):
        self.assertFalse(helper.user_authorized_for_sender('dave', 'shared@x.example'))

    def test_a_partial_name_is_not_a_match(self):
        # Membership on the split parts, not a substring test: "ali" and
        # "alice/bob" are both non-assignees of this row.
        self.assertFalse(helper.user_authorized_for_sender('ali', 'shared@x.example'))
        self.assertFalse(helper.user_authorized_for_sender('alice/bob', 'shared@x.example'))

    def test_the_lifecycle_preamble_admits_a_co_assignee(self):
        address, item, error = helper.authorized_address_request(
            _event(address='shared@x.example', user='bob'))
        self.assertIsNone(error)
        self.assertEqual(address, 'shared@x.example')
        self.assertEqual(item, self.table.rows['shared@x.example'])


class UserAuthorizedForSenderTest(_TableCase):
    '''The wrapper still answers for its other callers (compose.py, /send,
    /save_draft), which want the boolean and not the row.'''

    def test_owner_is_authorized(self):
        self.table.rows['a@x.example'] = {'user': 'alice'}
        self.assertTrue(helper.user_authorized_for_sender('alice', 'a@x.example'))

    def test_non_owner_missing_row_missing_attr_and_failure_are_all_false(self):
        self.table.rows['a@x.example'] = {'user': 'bob'}
        self.table.rows['b@x.example'] = {'subdomain': 'x'}
        self.assertFalse(helper.user_authorized_for_sender('alice', 'a@x.example'))
        self.assertFalse(helper.user_authorized_for_sender('alice', 'b@x.example'))
        self.assertFalse(helper.user_authorized_for_sender('alice', 'gone@x.example'))
        self.table.raise_on_get = True
        self.assertFalse(helper.user_authorized_for_sender('alice', 'a@x.example'))


if __name__ == '__main__':
    unittest.main()
