'''Unit tests for agent access grants: the shared module (agent_grants.py), the
/mcp REQUEST authorizer (authorize_agent), and the three grant-management
endpoints (new_agent_grant, list_agent_grants, revoke_agent_grant).

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_agent_grants.py

boto3 is faked in sys.modules before import and the grants table is an
in-memory fake, so the suite needs no AWS access. The properties pinned here
are the ones the plan calls load-bearing: only the token's hash is stored, the
plaintext is returned once, Phase A grants are read-only and INBOX-only, and a
revoked, expired or unknown token gets no Allow.'''
import importlib.util
import json
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_SHARED_DIR = os.path.dirname(_TESTS_DIR)
_API_DIR = os.path.dirname(_SHARED_DIR)
sys.path.insert(0, _SHARED_DIR)

# --- fake boto3 (only what agent_grants imports) -----------------------------

if 'boto3' not in sys.modules:
    _boto3 = types.ModuleType('boto3')
    _boto3.resource = lambda _name, **_kw: types.SimpleNamespace(
        Table=lambda _n: types.SimpleNamespace())
    _boto3.client = lambda _name, **_kw: types.SimpleNamespace()
    _boto3.session = types.SimpleNamespace(Config=lambda **_kw: None)
    sys.modules['boto3'] = _boto3


class _Key:
    def __init__(self, name):
        self.name = name

    def eq(self, value):
        return (self.name, value)


_conditions = types.ModuleType('boto3.dynamodb.conditions')
_conditions.Key = _Key
_dynamodb = types.ModuleType('boto3.dynamodb')
_dynamodb.conditions = _conditions
sys.modules.setdefault('boto3.dynamodb', _dynamodb)
sys.modules.setdefault('boto3.dynamodb.conditions', _conditions)

import agent_grants  # noqa: E402  pylint: disable=wrong-import-position


def _load(name):
    spec = importlib.util.spec_from_file_location(
        f'{name}_function', os.path.join(_API_DIR, name, 'function.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


authorize_agent = _load('authorize_agent')
new_agent_grant = _load('new_agent_grant')
list_agent_grants = _load('list_agent_grants')
revoke_agent_grant = _load('revoke_agent_grant')

NOW = 1_800_000_000


class ConditionalCheckFailed(Exception):
    '''Stand-in for DynamoDB's ConditionalCheckFailedException.'''


class FakeTable:
    '''In-memory cabal-agent-grants. Enforces the two conditions the code
    relies on (mint never overwrites; revoke only touches the caller's row);
    the last_used_at throttle is pinned by asserting on the call instead.'''

    def __init__(self):
        self.rows = {}
        self.gets = []
        self.updates = []
        self.fail_updates = False

    def get_item(self, Key):  # pylint: disable=invalid-name
        self.gets.append(Key)
        item = self.rows.get(Key['token_hash'])
        return {'Item': dict(item)} if item else {}

    def put_item(self, Item, ConditionExpression=None):  # pylint: disable=invalid-name
        if ConditionExpression and Item['token_hash'] in self.rows:
            raise ConditionalCheckFailed()
        self.rows[Item['token_hash']] = dict(Item)

    def query(self, IndexName, KeyConditionExpression, **_kw):  # pylint: disable=invalid-name
        assert IndexName == 'user-index'
        _, user = KeyConditionExpression
        return {'Items': [dict(r) for r in self.rows.values() if r['user'] == user]}

    def update_item(self, **kwargs):
        self.updates.append(kwargs)
        if self.fail_updates:
            raise ConditionalCheckFailed()
        row = self.rows[kwargs['Key']['token_hash']]
        values = kwargs.get('ExpressionAttributeValues', {})
        if ':user' in values and row['user'] != values[':user']:
            raise ConditionalCheckFailed()
        if 'revoked_at' in kwargs['UpdateExpression']:
            row['revoked_at'] = values[':now']
        if 'last_used_at' in kwargs['UpdateExpression']:
            row['last_used_at'] = values[':now']


def _cognito_event(user, body=None):
    return {
        'body': json.dumps(body) if body is not None else None,
        'requestContext': {
            'authorizer': {'claims': {'cognito:username': user}},
            'domainName': 'abc123.execute-api.us-east-1.amazonaws.com',
            'stage': 'prod',
        },
    }


def _authorizer_event(header_value, header_name='Authorization'):
    return {
        'type': 'REQUEST',
        'methodArn': 'arn:aws:execute-api:us-east-1:111111111111:abc123/prod/POST/mcp',
        'headers': {header_name: header_value} if header_value is not None else {},
    }


class _GrantCase(unittest.TestCase):
    def setUp(self):
        self.table = FakeTable()
        agent_grants._TABLE_CACHE['table'] = self.table  # pylint: disable=protected-access
        self.addCleanup(agent_grants._TABLE_CACHE.clear)  # pylint: disable=protected-access
        for module in (agent_grants, authorize_agent, new_agent_grant,
                       list_agent_grants, revoke_agent_grant):
            if hasattr(module, 'time'):
                saved = module.time
                module.time = types.SimpleNamespace(time=lambda: NOW)
                self.addCleanup(setattr, module, 'time', saved)
        agent_grants.Key = _Key
        self.lines = []
        for module in (authorize_agent, new_agent_grant, revoke_agent_grant):
            module.print = self.lines.append
            self.addCleanup(delattr, module, 'print')

    def mint(self, user='alice', **body):
        body.setdefault('label', 'Claude on my laptop')
        response = new_agent_grant.handler(_cognito_event(user, body), None)
        return response['statusCode'], json.loads(response['body'])


# --- the shared module -------------------------------------------------------


class TokenTests(unittest.TestCase):
    def test_token_shape_and_hash(self):
        token = agent_grants.new_token()
        self.assertTrue(token.startswith('cbl_agt_'))
        self.assertTrue(agent_grants.is_token_shaped(token))
        hashed = agent_grants.token_hash(token)
        self.assertEqual(len(hashed), 64)
        self.assertEqual(agent_grants.grant_id_for(hashed), hashed[:16])
        self.assertNotEqual(agent_grants.new_token(), token)

    def test_other_credentials_are_not_token_shaped(self):
        for value in ('eyJhbGciOiJSUzI1NiJ9.e30.sig', 'cbl_agt_short', '', None,
                      'cbl_agt_' + 'a' * 42 + '!', ' cbl_agt_' + 'a' * 43):
            self.assertFalse(agent_grants.is_token_shaped(value), value)

    def test_scope_is_read_only_by_default_and_inbox_only(self):
        self.assertEqual(agent_grants.validate_access(None), 'read_only')
        self.assertEqual(agent_grants.validate_access('read_flag'), 'read_flag')
        self.assertEqual(agent_grants.validate_folders(None), ['INBOX'])
        for access in ('read_write', 'READ_FLAG', 'admin', ''):
            with self.assertRaises(ValueError):
                agent_grants.validate_access(access)
        for folders in (['Archive'], ['INBOX', 'Sent'], [], 'INBOX'):
            with self.assertRaises(ValueError):
                agent_grants.validate_folders(folders)

    def test_expiry_bounds(self):
        self.assertEqual(agent_grants.validate_expiry_days(None), 90)
        self.assertEqual(agent_grants.validate_expiry_days(365), 365)
        for days in (0, 366, -1, 1.5, '30', True):
            with self.assertRaises(ValueError):
                agent_grants.validate_expiry_days(days)

    def test_label(self):
        self.assertEqual(agent_grants.validate_label('  Laptop  '), 'Laptop')
        for label in (None, '', '   ', 'x' * 65, 'a\nb'):
            with self.assertRaises(ValueError):
                agent_grants.validate_label(label)

    def test_liveness(self):
        self.assertTrue(agent_grants.is_live({'expires_at': NOW + 1}, NOW))
        self.assertFalse(agent_grants.is_live({'expires_at': NOW}, NOW))
        self.assertFalse(agent_grants.is_live({'expires_at': NOW + 1, 'revoked_at': NOW}, NOW))
        self.assertFalse(agent_grants.is_live(None, NOW))
        self.assertFalse(agent_grants.is_live({}, NOW))


# --- minting, listing, revoking ---------------------------------------------


class GrantEndpointTests(_GrantCase):
    def test_mint_stores_only_the_hash_and_returns_the_token_once(self):
        status, body = self.mint()
        self.assertEqual(status, 201)
        token = body['token']
        self.assertTrue(agent_grants.is_token_shaped(token))
        self.assertEqual(body['mcp_url'],
                         'https://abc123.execute-api.us-east-1.amazonaws.com/prod/mcp')
        self.assertEqual(body['folders'], ['INBOX'])
        self.assertEqual(body['access'], 'read_only')
        self.assertEqual(body['expires_at'], NOW + 90 * 86400)
        (row,) = self.table.rows.values()
        self.assertEqual(row['token_hash'], agent_grants.token_hash(token))
        self.assertNotIn(token, json.dumps({k: str(v) for k, v in row.items()}))
        self.assertFalse(any(token in line for line in self.lines))

        listed = json.loads(list_agent_grants.handler(_cognito_event('alice'), None)['body'])
        self.assertEqual(len(listed['grants']), 1)
        listed_text = json.dumps(listed)
        self.assertNotIn(token, listed_text)
        self.assertNotIn(row['token_hash'], listed_text)
        self.assertEqual(listed['grants'][0]['grant_id'], body['grant_id'])
        self.assertTrue(listed['grants'][0]['live'])

    def test_a_read_flag_grant_reaches_the_mcp_lambda_as_read_flag(self):
        status, body = self.mint(access='read_flag')
        self.assertEqual(status, 201)
        self.assertEqual(body['access'], 'read_flag')
        policy = authorize_agent.handler(_authorizer_event(f'Bearer {body["token"]}'), None)
        self.assertEqual(policy['context']['access'], 'read_flag')

    def test_mint_refuses_wider_scope(self):
        for body in ({'access': 'read_write'}, {'folders': ['Archive']},
                     {'expires_in_days': 400}, {'label': ''}):
            status, _ = self.mint(**body)
            self.assertEqual(status, 400, body)
        self.assertEqual(self.table.rows, {})

    def test_mint_rejects_a_non_object_body(self):
        event = _cognito_event('alice')
        event['body'] = '[1, 2]'
        self.assertEqual(new_agent_grant.handler(event, None)['statusCode'], 400)

    def test_active_grant_cap(self):
        for _ in range(agent_grants.MAX_ACTIVE_GRANTS):
            self.assertEqual(self.mint()[0], 201)
        self.assertEqual(self.mint()[0], 409)
        # Another user is not affected by alice's grants.
        self.assertEqual(self.mint(user='sam')[0], 201)

    def test_revoke_own_grant(self):
        _, body = self.mint()
        response = revoke_agent_grant.handler(
            _cognito_event('alice', {'grant_id': body['grant_id']}), None)
        self.assertEqual(response['statusCode'], 200)
        listed = json.loads(list_agent_grants.handler(_cognito_event('alice'), None)['body'])
        self.assertTrue(listed['grants'][0]['revoked'])
        self.assertFalse(listed['grants'][0]['live'])
        # Revoking twice is harmless.
        self.assertEqual(revoke_agent_grant.handler(
            _cognito_event('alice', {'grant_id': body['grant_id']}), None)['statusCode'], 200)

    def test_cannot_revoke_someone_elses_grant(self):
        _, body = self.mint(user='alice')
        response = revoke_agent_grant.handler(
            _cognito_event('sam', {'grant_id': body['grant_id']}), None)
        self.assertEqual(response['statusCode'], 404)
        (row,) = self.table.rows.values()
        self.assertNotIn('revoked_at', row)

    def test_revoke_validates_the_id(self):
        for grant_id in (None, 'ABC', 'zz' * 8, '0' * 15):
            response = revoke_agent_grant.handler(
                _cognito_event('alice', {'grant_id': grant_id}), None)
            self.assertEqual(response['statusCode'], 400, grant_id)


# --- the authorizer ---------------------------------------------------------


class AuthorizerTests(_GrantCase):
    def _refused(self, event):
        with self.assertRaises(Exception) as raised:
            authorize_agent.handler(event, None)
        self.assertEqual(str(raised.exception), 'Unauthorized')

    def test_live_grant_is_allowed_with_its_scope(self):
        _, body = self.mint()
        policy = authorize_agent.handler(_authorizer_event(f'Bearer {body["token"]}'), None)
        self.assertEqual(policy['principalId'], 'alice')
        (statement,) = policy['policyDocument']['Statement']
        self.assertEqual(statement['Effect'], 'Allow')
        self.assertEqual(statement['Resource'],
                         'arn:aws:execute-api:us-east-1:111111111111:abc123/prod/POST/mcp')
        self.assertEqual(policy['context'], {
            'user': 'alice', 'grant_id': body['grant_id'],
            'access': 'read_only', 'folders': 'INBOX'})
        for value in policy['context'].values():
            self.assertIsInstance(value, str)

    def test_header_name_and_scheme_are_case_insensitive(self):
        _, body = self.mint()
        policy = authorize_agent.handler(
            _authorizer_event(f'bearer {body["token"]}', header_name='authorization'), None)
        self.assertEqual(policy['principalId'], 'alice')

    def test_missing_or_foreign_credentials_are_refused_without_a_lookup(self):
        for value in (None, '', 'Bearer', 'Basic dXNlcjpwYXNz',
                      'Bearer eyJhbGciOiJSUzI1NiJ9.e30.sig', 'cbl_agt_' + 'a' * 43):
            self._refused(_authorizer_event(value))
        self.assertEqual(self.table.gets, [])

    def test_unknown_token_is_refused(self):
        self._refused(_authorizer_event(f'Bearer {agent_grants.new_token()}'))
        self.assertEqual(len(self.table.gets), 1)

    def test_revoked_token_is_refused(self):
        _, body = self.mint()
        revoke_agent_grant.handler(_cognito_event('alice', {'grant_id': body['grant_id']}), None)
        self._refused(_authorizer_event(f'Bearer {body["token"]}'))

    def test_expired_token_is_refused_before_the_ttl_sweep(self):
        _, body = self.mint(expires_in_days=1)
        (row,) = self.table.rows.values()
        row['expires_at'] = NOW - 1
        self._refused(_authorizer_event(f'Bearer {body["token"]}'))

    def test_refusal_log_names_no_token(self):
        token = agent_grants.new_token()
        self._refused(_authorizer_event(f'Bearer {token}'))
        self.assertTrue(self.lines)
        self.assertFalse(any(token in line for line in self.lines))

    def test_last_used_is_throttled_and_never_blocks(self):
        _, body = self.mint()
        authorize_agent.handler(_authorizer_event(f'Bearer {body["token"]}'), None)
        update = self.table.updates[-1]
        self.assertIn('last_used_at < :cutoff', update['ConditionExpression'])
        self.assertEqual(update['ExpressionAttributeValues'][':cutoff'], NOW - 60)
        self.table.fail_updates = True
        policy = authorize_agent.handler(_authorizer_event(f'Bearer {body["token"]}'), None)
        self.assertEqual(policy['principalId'], 'alice')


if __name__ == '__main__':
    unittest.main()
