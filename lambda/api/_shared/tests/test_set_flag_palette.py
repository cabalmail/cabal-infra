'''Unit tests for set_flag's keyword narrowing (rules-composition plan,
Phase 4 / decisions 4 and 6): system flags pass through as before; slot
atoms are validated against the user's palette on set (and only for
well-formedness on unset, so retired slots can be untagged); anything
else is rejected; a palette read failure fails closed.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_set_flag_palette.py

boto3 / botocore / imap_session are faked in sys.modules before import
(same arrangement as test_get_message_gone.py), so the suite needs no
AWS access and never dials an IMAP server.'''
import importlib.util
import json
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

# --- fake boto3 / botocore ---------------------------------------------------

# Scripted per-test: the preferences row's Item, or an exception to raise.
PREFS_ITEM = {}
PREFS_ERROR = None


class _FakeSSMExceptions:
    class ParameterNotFound(Exception):
        pass


class _FakeSSM:
    exceptions = _FakeSSMExceptions

    def get_parameter(self, Name=None, **_kwargs):  # pylint: disable=invalid-name
        if Name == '/cabal/maintenance/imap':
            raise _FakeSSMExceptions.ParameterNotFound()
        return {"Parameter": {"Value": "fake-master-password"}}


class _FakeTable:
    def get_item(self, Key=None, **_kwargs):  # pylint: disable=invalid-name
        if PREFS_ERROR is not None:
            raise PREFS_ERROR
        assert Key == {'user': 'tester'}
        return {'Item': PREFS_ITEM} if PREFS_ITEM else {}


class _FakeResource:
    def Table(self, _name):  # pylint: disable=invalid-name
        return _FakeTable()


_boto3 = types.ModuleType("boto3")
_boto3.resource = lambda _name, **_kw: _FakeResource()
_boto3.client = lambda name, **_kw: _FakeSSM() if name == 'ssm' else types.SimpleNamespace()
_boto3.session = types.SimpleNamespace(Config=lambda **_kw: None)
sys.modules['boto3'] = _boto3

_botocore = types.ModuleType("botocore")
_botocore_exceptions = types.ModuleType("botocore.exceptions")


class _ClientError(Exception):
    pass


_botocore_exceptions.ClientError = _ClientError
_botocore.exceptions = _botocore_exceptions
sys.modules['botocore'] = _botocore
sys.modules['botocore.exceptions'] = _botocore_exceptions

# --- fake imap_session -------------------------------------------------------

STORES = []


class _FakeImapClient:
    def add_flags(self, batch, flag, _silent):
        STORES.append(('add', tuple(batch), flag))
        return {}

    def remove_flags(self, batch, flag, _silent):
        STORES.append(('remove', tuple(batch), flag))
        return {}

    def logout(self):
        pass


def _open_imap_client(_host, _user, _folder, _read_only, _mpw):
    return _FakeImapClient()


_imap_session = types.ModuleType("imap_session")
_imap_session.open_imap_client = _open_imap_client
sys.modules['imap_session'] = _imap_session

import helper  # noqa: E402  pylint: disable=wrong-import-position


def _load_handler(name):
    '''Imports lambda/api/<name>/function.py under a unique module name
    (see test_get_message_gone.py for why a bare `import function` is a
    trap under discover).'''
    path = os.path.join(os.path.dirname(_SHARED), name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'function_{name}', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


set_flag = _load_handler('set_flag')

_SAVED = {}


def setUpModule():
    '''Rebinds the fakes into `helper` regardless of suite import order
    (#860), and into the handler's own module-scope table.'''
    _SAVED['open_imap_client'] = helper.open_imap_client
    helper.open_imap_client = _open_imap_client
    _SAVED['table'] = set_flag._preferences_table  # pylint: disable=protected-access
    set_flag._preferences_table = _FakeTable()  # pylint: disable=protected-access


def tearDownModule():
    helper.open_imap_client = _SAVED['open_imap_client']
    set_flag._preferences_table = _SAVED['table']  # pylint: disable=protected-access


def _event(flag, op='set'):
    return {
        'requestContext': {'authorizer': {'claims': {'cognito:username': 'tester'}}},
        'body': json.dumps({
            'host': 'imap.test.example.com', 'folder': 'INBOX',
            'ids': [1, 2], 'flag': flag, 'op': op,
        }),
    }


def _palette_item(entries):
    return {'user': 'tester', 'app': {'flag_palette': json.dumps(entries)}}


class SetFlagPaletteTest(unittest.TestCase):
    '''The keyword gate in front of the UID STORE.'''

    def setUp(self):
        global PREFS_ITEM, PREFS_ERROR  # pylint: disable=global-statement
        PREFS_ITEM = _palette_item([
            {'slot': 'cabal-flag-01', 'label': 'Urgent', 'color': 'red'},
            {'slot': 'cabal-flag-02', 'label': 'Off', 'color': 'gray',
             'enabled': False},
        ])
        PREFS_ERROR = None
        STORES.clear()

    def test_system_flags_pass_without_a_palette_read(self):
        global PREFS_ERROR  # pylint: disable=global-statement
        # Even a broken preferences table must not affect system flags.
        PREFS_ERROR = _ClientError('down')
        response = set_flag.handler(_event('\\Flagged'), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(STORES, [('add', (1, 2), '\\Flagged')])

    def test_palette_slot_sets(self):
        response = set_flag.handler(_event('cabal-flag-01'), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(STORES, [('add', (1, 2), 'cabal-flag-01')])

    def test_slot_not_in_palette_is_rejected(self):
        response = set_flag.handler(_event('cabal-flag-03'), None)
        self.assertEqual(response['statusCode'], 400)
        self.assertIn('flag not in palette', json.loads(response['body'])['status'])
        self.assertEqual(STORES, [])

    def test_disabled_slot_is_rejected_for_set(self):
        response = set_flag.handler(_event('cabal-flag-02'), None)
        self.assertEqual(response['statusCode'], 400)
        self.assertEqual(STORES, [])

    def test_unset_skips_the_palette_check(self):
        # Untagging a retired (or disabled) slot must stay possible, and
        # must not even need the palette read to succeed.
        global PREFS_ERROR  # pylint: disable=global-statement
        PREFS_ERROR = _ClientError('down')
        response = set_flag.handler(_event('cabal-flag-19', op='unset'), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(STORES, [('remove', (1, 2), 'cabal-flag-19')])

    def test_non_slot_keywords_are_rejected(self):
        for keyword in ('myflag', 'cabal-flag-21', 'cabal-flag-00',
                        'cabal-flag-1', 'CABAL-FLAG-01'):
            with self.subTest(keyword=keyword):
                response = set_flag.handler(_event(keyword), None)
                self.assertEqual(response['statusCode'], 400)
                self.assertIn('unknown keyword',
                              json.loads(response['body'])['status'])
        self.assertEqual(STORES, [])

    def test_palette_read_failure_fails_closed(self):
        global PREFS_ERROR  # pylint: disable=global-statement
        PREFS_ERROR = _ClientError('down')
        response = set_flag.handler(_event('cabal-flag-01'), None)
        self.assertEqual(response['statusCode'], 500)
        self.assertEqual(STORES, [])

    def test_missing_or_malformed_palette_rejects_the_slot(self):
        global PREFS_ITEM  # pylint: disable=global-statement
        for item in ({}, {'user': 'tester', 'app': {}},
                     {'user': 'tester', 'app': {'flag_palette': 'not json'}},
                     {'user': 'tester', 'app': {'flag_palette': '{}'}}):
            with self.subTest(item=item):
                PREFS_ITEM = item
                response = set_flag.handler(_event('cabal-flag-01'), None)
                self.assertEqual(response['statusCode'], 400)
        self.assertEqual(STORES, [])


if __name__ == '__main__':
    unittest.main()
