'''Unit tests for push_register / push_deregister token validation.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_push_token_validation.py

boto3 is faked in sys.modules before import, so the suite needs no AWS
access; the DynamoDB writes are recorded for assertions. The handlers are
loaded under unique module names (#860/#863).

What these cover: the per-platform token grammar split introduced with FCM
support. APNs tokens are hex and normalized to lowercase; FCM tokens carry
colons/underscores, are case-significant, and must never be lowercased. The
register endpoint keys the grammar off the (validated) bundle id; deregister
has no bundle id in its contract, so it tries the two grammars in turn.
'''
import importlib.util
import json
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')

# --- fake boto3 --------------------------------------------------------------

UPDATES = []
DELETES = []


class _RecordingTable:
    def update_item(self, **kwargs):  # pylint: disable=invalid-name
        UPDATES.append(kwargs)

    def delete_item(self, Key=None, **_kwargs):  # pylint: disable=invalid-name
        DELETES.append(Key)


_TABLE = _RecordingTable()

_boto3 = types.ModuleType('boto3')
_boto3.resource = lambda _name, **_kw: types.SimpleNamespace(Table=lambda _n: _TABLE)
_boto3.client = lambda _name, **_kw: types.SimpleNamespace()
sys.modules['boto3'] = _boto3

# --- load the handlers under unique names ------------------------------------

_API = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load_handler(name):
    path = os.path.join(_API, name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'function_{name}_tokens', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


push_register = _load_handler('push_register')
push_deregister = _load_handler('push_deregister')

# --- helpers -----------------------------------------------------------------

APNS_TOKEN_UPPER = 'AB12' * 16                     # 64 hex chars, uppercased
FCM_TOKEN = 'dXvQ9zRk4:APA91bFakeToken_-abcDEF1234567890'


def _event(body):
    return {
        'requestContext': {'authorizer': {'claims': {'cognito:username': 'testuser'}}},
        'body': json.dumps(body),
    }


def _register(body):
    return push_register.handler(_event(body), None)


def _deregister(body):
    return push_deregister.handler(_event(body), None)


class PushRegisterTests(unittest.TestCase):

    def setUp(self):
        UPDATES.clear()
        DELETES.clear()

    def test_android_bundle_accepts_fcm_token_case_preserved(self):
        response = _register({'bundle_id': 'com.cabalmail.android',
                              'device_token': FCM_TOKEN})
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(UPDATES[0]['Key']['device_token'], FCM_TOKEN)
        values = UPDATES[0]['ExpressionAttributeValues']
        self.assertEqual(values[':b'], 'com.cabalmail.android')
        self.assertEqual(values[':p'], 'android')

    def test_android_bundle_rejects_out_of_charset_token(self):
        response = _register({'bundle_id': 'com.cabalmail.android',
                              'device_token': 'has spaces and+plus='})
        self.assertEqual(response['statusCode'], 400)
        self.assertEqual(UPDATES, [])

    def test_android_bundle_rejects_short_token(self):
        response = _register({'bundle_id': 'com.cabalmail.android',
                              'device_token': 'short'})
        self.assertEqual(response['statusCode'], 400)

    def test_apple_bundle_lowercases_hex_token(self):
        response = _register({'bundle_id': 'com.cabalmail.Cabalmail',
                              'device_token': APNS_TOKEN_UPPER})
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(UPDATES[0]['Key']['device_token'], APNS_TOKEN_UPPER.lower())
        self.assertEqual(UPDATES[0]['ExpressionAttributeValues'][':p'], 'ios')

    def test_apple_bundle_rejects_fcm_shaped_token(self):
        response = _register({'bundle_id': 'com.cabalmail.Cabalmail',
                              'device_token': FCM_TOKEN})
        self.assertEqual(response['statusCode'], 400)

    def test_unknown_bundle_rejected_before_token_grammar(self):
        response = _register({'bundle_id': 'com.example.other',
                              'device_token': FCM_TOKEN})
        self.assertEqual(response['statusCode'], 400)
        self.assertIn('bundle_id', json.loads(response['body'])['Error'])

    def test_android_row_carries_enabled_folders(self):
        response = _register({'bundle_id': 'com.cabalmail.android',
                              'device_token': FCM_TOKEN,
                              'enabled_folders': ['INBOX', 'Receipts']})
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(UPDATES[0]['ExpressionAttributeValues'][':f'],
                         {'INBOX', 'Receipts'})


class PushDeregisterTests(unittest.TestCase):

    def setUp(self):
        UPDATES.clear()
        DELETES.clear()

    def test_hex_token_normalized_to_lowercase(self):
        response = _deregister({'device_token': APNS_TOKEN_UPPER})
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(DELETES[0]['device_token'], APNS_TOKEN_UPPER.lower())

    def test_fcm_token_passes_through_case_preserved(self):
        response = _deregister({'device_token': FCM_TOKEN})
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(DELETES[0]['device_token'], FCM_TOKEN)

    def test_out_of_charset_token_rejected(self):
        response = _deregister({'device_token': 'nope nope nope nope'})
        self.assertEqual(response['statusCode'], 400)
        self.assertEqual(DELETES, [])

    def test_short_token_rejected(self):
        response = _deregister({'device_token': 'abc123'})
        self.assertEqual(response['statusCode'], 400)


if __name__ == '__main__':
    unittest.main()
