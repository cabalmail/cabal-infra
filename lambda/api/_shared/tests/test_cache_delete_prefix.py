'''Unit tests for helper.delete_prefix's handling of a batch DeleteObjects
response that refuses individual keys.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_cache_delete_prefix.py

The batch API authorizes per key: a key the caller may not delete comes back
in the response's `Errors` array inside an HTTP 200, rather than raising
ClientError. empty_trash's cache hygiene therefore reported success while
every key was being denied (#1129).

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, so the suite needs no AWS access.'''
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')
os.environ.setdefault('ADDRESS_CHANGED_TOPIC_ARN',
                      'arn:aws:sns:us-east-1:123456789012:address-changed')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

# --- fake boto3 / botocore ---------------------------------------------------


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
sys.modules['boto3'] = _boto3

_botocore = types.ModuleType("botocore")
_botocore_exceptions = types.ModuleType("botocore.exceptions")


class _ClientError(Exception):
    pass


_botocore_exceptions.ClientError = _ClientError
_botocore.exceptions = _botocore_exceptions
sys.modules['botocore'] = _botocore
sys.modules['botocore.exceptions'] = _botocore_exceptions

_imap_session = types.ModuleType("imap_session")
_imap_session.open_imap_client = lambda *_a, **_kw: None
sys.modules['imap_session'] = _imap_session

import helper  # noqa: E402  pylint: disable=wrong-import-position

# --- fake s3 resource --------------------------------------------------------


class _FakeObjectCollection:
    '''Stands in for Bucket().objects.filter(...); `delete()` returns the list
    of per-batch response dicts the real boto3 collection returns.'''

    def __init__(self, responses):
        self._responses = responses
        self.filtered_prefix = None

    def filter(self, Prefix=None):  # pylint: disable=invalid-name
        self.filtered_prefix = Prefix
        return self

    def delete(self):
        return self._responses


class _FakeBucket:
    def __init__(self, responses):
        self.objects = _FakeObjectCollection(responses)


class _FakeS3Resource:
    def __init__(self, responses):
        self.bucket = _FakeBucket(responses)

    def Bucket(self, _name):  # pylint: disable=invalid-name
        return self.bucket


ACCESS_DENIED = {
    'Key': 'someuser/Trash/350/raw',
    'Code': 'AccessDenied',
    'Message': 'Access Denied',
}


class DeletePrefixTest(unittest.TestCase):
    '''delete_prefix must distinguish a clean batch from a refused one.'''

    def setUp(self):
        self._saved_s3r = helper.s3r
        self.addCleanup(lambda: setattr(helper, 's3r', self._saved_s3r))

    def _run(self, responses, prefix='someuser/Trash/'):
        fake = _FakeS3Resource(responses)
        helper.s3r = fake
        result = helper.delete_prefix('cache.test.example.com', prefix)
        return result, fake.bucket.objects.filtered_prefix

    def test_clean_batch_succeeds(self):
        '''Every key deleted: True, and the prefix is passed through.'''
        result, prefix = self._run([{'Deleted': [{'Key': 'someuser/Trash/350/raw'}]}])
        self.assertTrue(result)
        self.assertEqual(prefix, 'someuser/Trash/')

    def test_refused_key_fails(self):
        '''A 200 carrying Errors is a failure, not a success (#1129).'''
        result, _ = self._run([{'Deleted': [], 'Errors': [ACCESS_DENIED]}])
        self.assertFalse(result)

    def test_partial_batch_fails(self):
        '''One key refused among many deleted is still a failure.'''
        result, _ = self._run([{
            'Deleted': [{'Key': 'someuser/Trash/1/raw'}],
            'Errors': [ACCESS_DENIED],
        }])
        self.assertFalse(result)

    def test_errors_in_a_later_batch_fail(self):
        '''boto3 pages large deletes; a refusal in any page counts.'''
        result, _ = self._run([
            {'Deleted': [{'Key': 'someuser/Trash/1/raw'}]},
            {'Deleted': [], 'Errors': [ACCESS_DENIED]},
        ])
        self.assertFalse(result)

    def test_empty_response_list_succeeds(self):
        '''Nothing matched the prefix: boto3 returns an empty list.'''
        result, _ = self._run([])
        self.assertTrue(result)

    def test_none_response_succeeds(self):
        '''Defensive: a None return is treated as nothing-to-do, not a crash.'''
        result, _ = self._run(None)
        self.assertTrue(result)

    def test_client_error_still_fails(self):
        '''The pre-existing raise path is unchanged.

        Raises `helper.ClientError`, not this file's fake: under a
        directory-wide `discover` run `helper` is usually already imported and
        still bound to whichever sibling suite's fake botocore won the
        `sys.modules` slot first (#860).
        '''
        class _RaisingCollection(_FakeObjectCollection):
            def delete(self):
                raise helper.ClientError('boom')

        fake = _FakeS3Resource([])
        fake.bucket.objects = _RaisingCollection([])
        helper.s3r = fake
        self.assertFalse(helper.delete_prefix('cache.test.example.com', 'someuser/Trash/'))

    def test_prefix_guard_unchanged(self):
        '''A prefix that could match a sibling folder is still rejected.'''
        helper.s3r = _FakeS3Resource([])
        with self.assertRaises(ValueError):
            helper.delete_prefix('cache.test.example.com', 'someuser/Trash')
        with self.assertRaises(ValueError):
            helper.delete_prefix('cache.test.example.com', '')


if __name__ == '__main__':
    unittest.main()
