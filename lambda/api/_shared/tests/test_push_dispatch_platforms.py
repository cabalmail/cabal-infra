'''Unit tests for push_dispatch's per-platform sender routing.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_push_dispatch_platforms.py

Third-party imports (boto3, ecdsa, h2, rsa) are faked in sys.modules before
import, so the suite needs no AWS access, no wheels, and no network. apns.py
and fcm.py are the real modules — their error classes are what the dispatch
loop's except clauses match on — but the client classes themselves are
replaced with recording fakes on the loaded handler module, so no socket is
ever opened. The handler is loaded under a unique module name (#860/#863).

What these cover: the two-sender unconfigured matrix (an Android-only
environment must skip Apple rows cleanly and vice versa, with neither DLQ
noise nor a raise), the FCM data payload shape, the prune/retry/transport
split for FCM verdicts, isolation of one row's failure from its siblings,
and the Platform-dimensioned EMF metric lines.
'''
import contextlib
import importlib.util
import io
import json
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')

# --- fake boto3 (with dynamodb.conditions), ecdsa, h2, rsa -------------------

PARAMS = {}       # SSM path -> {leaf: value}
ROWS = []         # cabal-push-tokens rows returned by query
UPDATES = []      # recorded update_item kwargs
DELETES = []      # recorded delete_item Keys


class _FakeTable:
    def query(self, **_kwargs):  # pylint: disable=invalid-name
        return {'Items': [dict(row) for row in ROWS]}

    def update_item(self, **kwargs):  # pylint: disable=invalid-name
        UPDATES.append(kwargs)

    def delete_item(self, Key=None, **_kwargs):  # pylint: disable=invalid-name
        DELETES.append(Key)


_TABLE = _FakeTable()


class _FakeSSM:
    def get_parameters_by_path(self, Path=None, **_kwargs):  # pylint: disable=invalid-name
        leaves = PARAMS.get(Path, {})
        return {'Parameters': [
            {'Name': f'{Path}/{name}', 'Value': value}
            for name, value in leaves.items()
        ]}


class _Key:
    def __init__(self, name):
        self.name = name

    def eq(self, value):
        return (self.name, value)


_boto3 = types.ModuleType('boto3')
_boto3.resource = lambda _name, **_kw: types.SimpleNamespace(Table=lambda _n: _TABLE)
_boto3.client = lambda name, **_kw: _FakeSSM() if name == 'ssm' else types.SimpleNamespace()
_conditions = types.ModuleType('boto3.dynamodb.conditions')
_conditions.Key = _Key
_dynamodb = types.ModuleType('boto3.dynamodb')
_dynamodb.conditions = _conditions
_boto3.dynamodb = _dynamodb
sys.modules['boto3'] = _boto3
sys.modules['boto3.dynamodb'] = _dynamodb
sys.modules['boto3.dynamodb.conditions'] = _conditions

for _name in ('ecdsa', 'ecdsa.util', 'h2', 'h2.connection', 'h2.events',
              'h2.exceptions', 'rsa'):
    sys.modules[_name] = types.ModuleType(_name)
sys.modules['ecdsa'].util = sys.modules['ecdsa.util']
sys.modules['h2'].connection = sys.modules['h2.connection']
sys.modules['h2'].events = sys.modules['h2.events']
sys.modules['h2'].exceptions = sys.modules['h2.exceptions']
sys.modules['h2.exceptions'].ProtocolError = type('ProtocolError', (Exception,), {})
sys.modules['rsa'].PrivateKey = types.SimpleNamespace(load_pkcs1=lambda *a, **k: 'k')
sys.modules['rsa'].sign = lambda *args: b'sig'

# --- load the handler (apns.py / fcm.py resolve from its directory) ----------

_API = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_PUSH_DIR = os.path.join(_API, 'push_dispatch')
sys.path.insert(0, _PUSH_DIR)

_SPEC = importlib.util.spec_from_file_location(
    'function_push_dispatch', os.path.join(_PUSH_DIR, 'function.py'))
dispatch = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = dispatch
_SPEC.loader.exec_module(dispatch)

apns = sys.modules['apns']
fcm = sys.modules['fcm']

# --- recording sender fakes --------------------------------------------------

APNS_ERRORS = {}  # device_token -> exception to raise
FCM_ERRORS = {}


class _FakeApns:
    instances = []

    def __init__(self, endpoint, team_id, key_id, private_key):
        self.config = (endpoint, team_id, key_id, private_key)
        self.sends = []
        _FakeApns.instances.append(self)

    def send(self, device_token, topic, payload, collapse_id, *, background=False):
        error = APNS_ERRORS.get(device_token)
        if error:
            raise error
        self.sends.append((device_token, topic, payload, collapse_id, background))


class _FakeFcm:
    instances = []
    init_raises = None

    def __init__(self, service_account):
        if _FakeFcm.init_raises:
            raise _FakeFcm.init_raises
        self.service_account = service_account
        self.sends = []
        _FakeFcm.instances.append(self)

    def send(self, device_token, data):
        error = FCM_ERRORS.get(device_token)
        if error:
            raise error
        self.sends.append((device_token, data))


# --- helpers -----------------------------------------------------------------

IOS_ROW = {'user': 'u', 'device_token': 'a' * 64,
           'bundle_id': 'com.cabalmail.Cabalmail', 'platform': 'ios'}
MAC_ROW = {'user': 'u', 'device_token': 'b' * 64,
           'bundle_id': 'com.cabalmail.CabalmailMac', 'platform': 'macos'}
ANDROID_ROW = {'user': 'u', 'device_token': 'droid-1:AbC_-xyz1234567890',
               'bundle_id': 'com.cabalmail.android', 'platform': 'android'}

SIGNAL = {'user': 'u', 'folder': 'INBOX', 'uid': 7, 'msg_id': '<m@x>'}


def _configure_apns():
    PARAMS['/cabal/apns'] = {
        'team_id': 'T', 'key_id': 'K', 'private_key': 'PEM',
        'endpoint': 'https://api.push.example',
    }


def _configure_fcm():
    PARAMS['/cabal/fcm'] = {'service_account': '{"fake": "sa"}'}


def _event(signal=None):
    return {'Records': [{
        'body': json.dumps(signal or SIGNAL),
        'attributes': {'SentTimestamp': '1000'},
    }]}


def _run_handler(signal=None):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        result = dispatch.handler(_event(signal), None)
    return result, output.getvalue()


class DispatchPlatformTests(unittest.TestCase):

    def setUp(self):
        PARAMS.clear()
        ROWS.clear()
        UPDATES.clear()
        DELETES.clear()
        APNS_ERRORS.clear()
        FCM_ERRORS.clear()
        _FakeApns.instances.clear()
        _FakeFcm.instances.clear()
        _FakeFcm.init_raises = None
        dispatch.ApnsClient = _FakeApns
        dispatch.FcmClient = _FakeFcm
        dispatch._APNS_CLIENT = None  # pylint: disable=protected-access
        dispatch._APNS_RECHECK_AT = 0.0  # pylint: disable=protected-access
        dispatch._FCM_CLIENT = None  # pylint: disable=protected-access
        dispatch._FCM_RECHECK_AT = 0.0  # pylint: disable=protected-access

    # -- unconfigured matrix --

    def test_neither_sender_configured_drops_cleanly(self):
        ROWS.extend([IOS_ROW, ANDROID_ROW])
        result, _ = _run_handler()
        self.assertEqual(result['statusCode'], 200)
        self.assertEqual(_FakeApns.instances, [])
        self.assertEqual(_FakeFcm.instances, [])
        self.assertEqual(DELETES, [])

    def test_fcm_only_environment_skips_apple_rows(self):
        _configure_fcm()
        ROWS.extend([IOS_ROW, MAC_ROW, ANDROID_ROW])
        result, _ = _run_handler()
        self.assertEqual(result['statusCode'], 200)
        self.assertEqual(_FakeApns.instances, [])
        self.assertEqual(len(_FakeFcm.instances), 1)
        self.assertEqual(len(_FakeFcm.instances[0].sends), 1)
        self.assertEqual(_FakeFcm.instances[0].service_account, '{"fake": "sa"}')

    def test_apns_only_environment_skips_android_rows(self):
        _configure_apns()
        ROWS.extend([IOS_ROW, ANDROID_ROW])
        result, _ = _run_handler()
        self.assertEqual(result['statusCode'], 200)
        self.assertEqual(_FakeFcm.instances, [])
        self.assertEqual(len(_FakeApns.instances[0].sends), 1)

    def test_unusable_service_account_is_treated_as_unconfigured(self):
        _configure_apns()
        _configure_fcm()
        _FakeFcm.init_raises = ValueError('service account is not JSON')
        ROWS.extend([IOS_ROW, ANDROID_ROW])
        result, _ = _run_handler()
        self.assertEqual(result['statusCode'], 200)
        # Apple delivery is unaffected by the broken FCM credential.
        self.assertEqual(len(_FakeApns.instances[0].sends), 1)

    # -- routing and payloads --

    def test_both_configured_routes_each_row_to_its_sender(self):
        _configure_apns()
        _configure_fcm()
        ROWS.extend([IOS_ROW, MAC_ROW, ANDROID_ROW])
        _run_handler()
        apple_sends = _FakeApns.instances[0].sends
        self.assertEqual(len(apple_sends), 2)
        # iOS row: alert form; mac row: background (silent) form.
        by_token = {send[0]: send for send in apple_sends}
        self.assertFalse(by_token[IOS_ROW['device_token']][4])
        self.assertTrue(by_token[MAC_ROW['device_token']][4])
        self.assertEqual(len(_FakeFcm.instances[0].sends), 1)

    def test_fcm_data_values_are_all_strings(self):
        _configure_fcm()
        ROWS.append(ANDROID_ROW)
        _run_handler()
        _token, data = _FakeFcm.instances[0].sends[0]
        self.assertEqual(data, {'folder': 'INBOX', 'uid': '7', 'msg_id': '<m@x>'})
        for value in data.values():
            self.assertIsInstance(value, str)

    def test_fcm_uid_absent_becomes_zero_string(self):
        _configure_fcm()
        ROWS.append(ANDROID_ROW)
        _run_handler({'user': 'u', 'folder': 'INBOX'})
        _token, data = _FakeFcm.instances[0].sends[0]
        self.assertEqual(data['uid'], '0')
        self.assertEqual(data['msg_id'], '')

    def test_folder_opt_in_applies_to_android_rows(self):
        _configure_fcm()
        ROWS.append(dict(ANDROID_ROW, enabled_folders={'Receipts'}))
        _run_handler()
        self.assertEqual(_FakeFcm.instances, [])

    # -- failure handling --

    def test_fcm_unregistered_prunes_the_row(self):
        _configure_fcm()
        ROWS.append(ANDROID_ROW)
        FCM_ERRORS[ANDROID_ROW['device_token']] = fcm.FcmError(404, 'UNREGISTERED')
        result, _ = _run_handler()
        self.assertEqual(result['statusCode'], 200)  # resolved, not retryable
        self.assertEqual(DELETES, [{
            'user': 'u', 'device_token': ANDROID_ROW['device_token']}])

    def test_fcm_retryable_error_with_no_deliveries_raises(self):
        _configure_fcm()
        ROWS.append(ANDROID_ROW)
        FCM_ERRORS[ANDROID_ROW['device_token']] = fcm.FcmError(503, 'UNAVAILABLE')
        with self.assertRaises(RuntimeError):
            _run_handler()
        self.assertEqual(DELETES, [])
        # last_failure bookkeeping recorded the reason.
        reasons = [update['ExpressionAttributeValues'][':v'] for update in UPDATES]
        self.assertIn('UNAVAILABLE', reasons)

    def test_fcm_transport_error_does_not_strand_apple_sends(self):
        _configure_apns()
        _configure_fcm()
        ROWS.extend([ANDROID_ROW, IOS_ROW])
        FCM_ERRORS[ANDROID_ROW['device_token']] = fcm.FcmTransportError('timeout')
        result, _ = _run_handler()
        # Something was delivered, so the signal is not retried (that would
        # double-notify the iPhone).
        self.assertEqual(result['statusCode'], 200)
        self.assertEqual(len(_FakeApns.instances[0].sends), 1)

    def test_apns_permanent_error_still_prunes_alongside_fcm(self):
        _configure_apns()
        _configure_fcm()
        ROWS.extend([IOS_ROW, ANDROID_ROW])
        APNS_ERRORS[IOS_ROW['device_token']] = apns.ApnsError(410, 'Unregistered')
        result, _ = _run_handler()
        self.assertEqual(result['statusCode'], 200)
        self.assertEqual(DELETES, [{'user': 'u', 'device_token': IOS_ROW['device_token']}])
        self.assertEqual(len(_FakeFcm.instances[0].sends), 1)

    # -- metrics --

    def test_platform_dimensioned_metric_lines(self):
        _configure_apns()
        _configure_fcm()
        ROWS.extend([IOS_ROW, ANDROID_ROW])
        FCM_ERRORS[ANDROID_ROW['device_token']] = fcm.FcmError(404, 'UNREGISTERED')
        _result, output = _run_handler()
        platform_lines = {}
        for line in output.splitlines():
            try:
                parsed = json.loads(line)
            except ValueError:
                continue
            if isinstance(parsed, dict) and 'Platform' in parsed:
                platform_lines[parsed['Platform']] = parsed
        self.assertEqual(platform_lines['ios']['Sent'], 1)
        self.assertEqual(platform_lines['ios']['Failed'], 0)
        self.assertEqual(platform_lines['android']['Sent'], 0)
        self.assertEqual(platform_lines['android']['Failed'], 1)
        dimensions = platform_lines['ios']['_aws']['CloudWatchMetrics'][0]['Dimensions']
        self.assertEqual(dimensions, [['Platform']])


if __name__ == '__main__':
    unittest.main()
