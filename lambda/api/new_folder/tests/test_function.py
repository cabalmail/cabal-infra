'''Unit tests for the new_folder handler.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/new_folder/tests/test_function.py

function.py's helper and imapclient imports are faked in sys.modules before
import, so the suite needs no boto3 / AWS and never dials an IMAP server.'''
import json
import os
import sys
import types
import unittest

# function.py lives one directory up.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# --- fake imapclient ---------------------------------------------------------


class IMAPClientError(Exception):
    '''Stand-in for imapclient's own error type.'''


_exceptions = types.ModuleType('imapclient.exceptions')
_exceptions.IMAPClientError = IMAPClientError
_imapclient = types.ModuleType('imapclient')
_imapclient.exceptions = _exceptions
sys.modules['imapclient'] = _imapclient
sys.modules['imapclient.exceptions'] = _exceptions

# --- fake helper -------------------------------------------------------------


class _FakeImapClient:
    def __init__(self):
        self.ops = []
        self.create_error = None
        self.logged_out = False

    def create_folder(self, name):
        if self.create_error is not None:
            raise self.create_error
        self.ops.append(f'create:{name}')

    def logout(self):
        self.logged_out = True


CLIENT = _FakeImapClient()
FOLDER_LIST = {'folders': ['INBOX'], 'sub_folders': ['INBOX']}


def _parse_json_body(event):
    return json.loads(event['body']), None


def _validate_folder_name(name):
    if not name:
        raise ValueError('missing folder name')
    return name


_helper = types.ModuleType("helper")
_helper.get_imap_client = lambda _host, _user, _folder: CLIENT
_helper.get_folder_list = lambda _client: FOLDER_LIST
_helper.parse_json_body = _parse_json_body
_helper.validate_folder_name = _validate_folder_name
_helper.maintenance_guard = lambda handler: handler
sys.modules['helper'] = _helper

import function  # noqa: E402  pylint: disable=wrong-import-position

# The real server's rejection, verbatim from CloudWatch (#790).
ALREADY_EXISTS = IMAPClientError(
    'create failed: [ALREADYEXISTS] Mailbox already exists '
    '(0.058 + 0.000 + 0.057 secs).'
)


def _event(name, parent=''):
    return {
        'body': json.dumps({'name': name, 'parent': parent}),
        'requestContext': {
            'authorizer': {'claims': {'cognito:username': 'testuser'}}
        },
    }


class NewFolderTest(unittest.TestCase):

    def setUp(self):
        CLIENT.ops.clear()
        CLIENT.create_error = None
        CLIENT.logged_out = False

    def test_creates_a_top_level_folder(self):
        response = function.handler(_event('qa0726'), None)
        self.assertEqual(response['statusCode'], 201)
        self.assertEqual(CLIENT.ops, ['create:qa0726'])
        self.assertTrue(CLIENT.logged_out)

    def test_creates_a_child_folder_under_its_parent(self):
        response = function.handler(_event('qa0726', parent='Archive/2026'), None)
        self.assertEqual(response['statusCode'], 201)
        self.assertEqual(CLIENT.ops, ['create:Archive.2026.qa0726'])

    def test_existing_folder_returns_409_naming_the_folder(self):
        CLIENT.create_error = ALREADY_EXISTS
        response = function.handler(_event('qa0726'), None)
        self.assertEqual(response['statusCode'], 409)
        self.assertEqual(
            json.loads(response['body'])['status'],
            'A folder called qa0726 already exists'
        )
        self.assertTrue(CLIENT.logged_out)

    def test_existing_child_folder_names_the_leaf_not_the_path(self):
        CLIENT.create_error = ALREADY_EXISTS
        response = function.handler(_event('qa0726', parent='Archive'), None)
        self.assertEqual(response['statusCode'], 409)
        self.assertEqual(
            json.loads(response['body'])['status'],
            'A folder called qa0726 already exists'
        )

    def test_other_imap_failures_return_a_describable_500(self):
        # Anything unhandled here escapes the handler and API Gateway turns it
        # into a 502 the client can't describe.
        CLIENT.create_error = IMAPClientError('create failed: [SERVERBUG] oops')
        response = function.handler(_event('qa0726'), None)
        self.assertEqual(response['statusCode'], 500)
        self.assertEqual(
            json.loads(response['body'])['status'], 'Unable to create folder'
        )
        self.assertTrue(CLIENT.logged_out)

    def test_invalid_name_still_returns_400(self):
        response = function.handler(_event(''), None)
        self.assertEqual(response['statusCode'], 400)
        self.assertEqual(CLIENT.ops, [])


if __name__ == '__main__':
    unittest.main()
