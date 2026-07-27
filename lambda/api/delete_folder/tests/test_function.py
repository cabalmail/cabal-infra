'''Unit tests for the delete_folder handler.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/delete_folder/tests/test_function.py

function.py's helper import is faked in sys.modules before import, so the
suite needs no boto3 / AWS and never dials an IMAP server. The fake client
records operations in order, which is what the assertions inspect.'''
import json
import os
import sys
import types
import unittest

# function.py lives one directory up.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# --- fake helper -------------------------------------------------------------


class _FakeIMAPClientError(Exception):
    pass


# imapclient isn't vendored into the test environment; function.py only needs
# the exception type, so a stub module pair is enough (both `imapclient` and
# `imapclient.exceptions` must be present for the `from ... import` to work).
_imapclient = types.ModuleType("imapclient")
_exceptions = types.ModuleType("imapclient.exceptions")
_exceptions.IMAPClientError = _FakeIMAPClientError
_imapclient.exceptions = _exceptions
sys.modules['imapclient'] = _imapclient
sys.modules['imapclient.exceptions'] = _exceptions


class _FakeImapClient:
    def __init__(self):
        self.ops = []
        self.delete_error = None
        self.unsubscribe_error = None
        self.logged_out = False

    def delete_folder(self, name):
        if self.delete_error is not None:
            raise self.delete_error
        self.ops.append(f'delete:{name}')

    def unsubscribe_folder(self, name):
        if self.unsubscribe_error is not None:
            raise self.unsubscribe_error
        self.ops.append(f'unsubscribe:{name}')

    def list_folders(self):
        return []

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


def _event(name):
    return {
        'body': json.dumps({'name': name}),
        'requestContext': {
            'authorizer': {'claims': {'cognito:username': 'testuser'}}
        },
    }


class DeleteFolderTest(unittest.TestCase):

    def setUp(self):
        CLIENT.ops.clear()
        CLIENT.delete_error = None
        CLIENT.unsubscribe_error = None
        CLIENT.logged_out = False

    def test_delete_also_unsubscribes(self):
        # Dovecot keeps LSUB entries for deleted mailboxes, so the handler
        # must drop the subscription right after the delete.
        response = function.handler(_event('QA0723'), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(CLIENT.ops, ['delete:QA0723', 'unsubscribe:QA0723'])
        self.assertTrue(CLIENT.logged_out)

    def test_unsubscribe_failure_does_not_fail_the_delete(self):
        CLIENT.unsubscribe_error = RuntimeError('UNSUBSCRIBE rejected')
        response = function.handler(_event('QA0723'), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(CLIENT.ops, ['delete:QA0723'])
        self.assertTrue(CLIENT.logged_out)

    def test_deleting_a_missing_folder_is_a_404_not_a_502(self):
        # Dovecot answers [NONEXISTENT] when the mailbox is already gone.
        # Unhandled, that escaped the handler and API Gateway rendered it as
        # a bodiless 502 the client could say nothing about (#796).
        CLIENT.delete_error = _FakeIMAPClientError(
            "delete failed: [NONEXISTENT] Mailbox doesn't exist: QA0723 "
            "(0.047 + 0.000 + 0.046 secs)."
        )
        response = function.handler(_event('QA0723'), None)
        self.assertEqual(response['statusCode'], 404)
        self.assertIn('QA0723', json.loads(response['body'])['status'])
        self.assertEqual(CLIENT.ops, [])
        self.assertTrue(CLIENT.logged_out)

    def test_nested_folder_404_names_only_the_leaf(self):
        CLIENT.delete_error = _FakeIMAPClientError('[NONEXISTENT] Mailbox doesn\'t exist')
        response = function.handler(_event('Archive/QA0723'), None)
        self.assertEqual(response['statusCode'], 404)
        self.assertEqual(
            json.loads(response['body'])['status'],
            'There is no folder called QA0723'
        )

    def test_other_imap_failures_are_a_describable_500(self):
        CLIENT.delete_error = _FakeIMAPClientError('delete failed: [SERVERBUG] oh no')
        response = function.handler(_event('QA0723'), None)
        self.assertEqual(response['statusCode'], 500)
        self.assertEqual(
            json.loads(response['body'])['status'],
            'Unable to delete folder'
        )
        self.assertTrue(CLIENT.logged_out)


if __name__ == '__main__':
    unittest.main()
