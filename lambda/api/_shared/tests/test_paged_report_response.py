'''Unit tests for paged_report_response, the shared page-scan behind the two
report-listing endpoints (list_caa_reports, list_dmarc_reports).

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_paged_report_response.py

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, so the suite needs no AWS access. The cases pin the
wire contract both handlers had before the scan was shared: the 50-item page
limit, the descending in-page sort with its `'0'` fallback for a record missing
the sort attribute, the opaque base64 round-trip between `next_token` and
`NextToken`, the omission of `NextToken` when the scan reports no further page,
and the 500 shape for any failure -- including one raised by the caller's own
projection, which has always been inside the guarded block.'''
import base64
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


# Identical to the fake in the sibling suites on purpose: under a directory-wide
# `discover` the alphabetically-first suite's fakes win the import (#860), so
# every file still needs its own `setdefault` to run standalone.
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


class _FakeReportTable:
    '''Stands in for a report Table, recording the kwargs of each scan.'''

    def __init__(self, response=None, error=None):
        self.response = response if response is not None else {'Items': []}
        self.error = error
        self.scan_kwargs = []

    def scan(self, **kwargs):
        self.scan_kwargs.append(kwargs)
        if self.error:
            raise self.error
        return self.response


def _event(params=None):
    return {'queryStringParameters': params}


def _identity(item):
    return dict(item)


def _body(response):
    return json.loads(response['body'])


class PagedReportResponseTest(unittest.TestCase):
    '''Pins the contract the two report handlers inherited.'''

    def test_scans_one_capped_page_and_projects_each_item(self):
        table = _FakeReportTable({'Items': [{'k': 'a'}, {'k': 'b'}]})
        response = helper.paged_report_response(_event({}), table, 'k', _identity)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(table.scan_kwargs, [{'Limit': 50}])
        self.assertEqual(_body(response), {'Reports': [{'k': 'b'}, {'k': 'a'}]})

    def test_sorts_descending_on_the_sort_key_within_the_page(self):
        table = _FakeReportTable({'Items': [
            {'when': '1', 'id': 'a'}, {'when': '3', 'id': 'c'}, {'when': '2', 'id': 'b'},
        ]})
        response = helper.paged_report_response(_event({}), table, 'when', _identity)
        self.assertEqual([r['id'] for r in _body(response)['Reports']], ['c', 'b', 'a'])

    def test_record_missing_the_sort_attribute_sorts_as_zero(self):
        table = _FakeReportTable({'Items': [{'when': '!low', 'id': 'has'}, {'id': 'none'}]})
        response = helper.paged_report_response(_event({}), table, 'when', _identity)
        self.assertEqual([r['id'] for r in _body(response)['Reports']], ['none', 'has'])

    def test_absent_query_parameters_are_treated_as_no_token(self):
        for event in ({}, {'queryStringParameters': None}, _event({})):
            table = _FakeReportTable({'Items': []})
            response = helper.paged_report_response(event, table, 'when', _identity)
            self.assertEqual(response['statusCode'], 200)
            self.assertEqual(table.scan_kwargs, [{'Limit': 50}])

    def test_next_token_becomes_the_exclusive_start_key(self):
        key = {'pk': 'report#1'}
        token = base64.b64encode(json.dumps(key).encode('utf-8')).decode('utf-8')
        table = _FakeReportTable({'Items': []})
        helper.paged_report_response(_event({'next_token': token}), table, 'when', _identity)
        self.assertEqual(table.scan_kwargs, [{'Limit': 50, 'ExclusiveStartKey': key}])

    def test_empty_next_token_does_not_start_a_page(self):
        table = _FakeReportTable({'Items': []})
        helper.paged_report_response(_event({'next_token': ''}), table, 'when', _identity)
        self.assertEqual(table.scan_kwargs, [{'Limit': 50}])

    def test_last_evaluated_key_round_trips_as_next_token(self):
        key = {'pk': 'report#2'}
        table = _FakeReportTable({'Items': [], 'LastEvaluatedKey': key})
        response = helper.paged_report_response(_event({}), table, 'when', _identity)
        body = _body(response)
        decoded = json.loads(base64.b64decode(body['NextToken']).decode('utf-8'))
        self.assertEqual(decoded, key)

    def test_no_further_page_omits_next_token(self):
        table = _FakeReportTable({'Items': []})
        response = helper.paged_report_response(_event({}), table, 'when', _identity)
        self.assertEqual(_body(response), {'Reports': []})

    def test_scan_failure_becomes_a_500_carrying_the_message(self):
        table = _FakeReportTable(error=_ClientError('throttled'))
        response = helper.paged_report_response(_event({}), table, 'when', _identity)
        self.assertEqual(response['statusCode'], 500)
        self.assertEqual(_body(response), {'Error': 'throttled'})

    def test_malformed_next_token_becomes_a_500(self):
        table = _FakeReportTable({'Items': []})
        response = helper.paged_report_response(
            _event({'next_token': '!!! not base64 !!!'}), table, 'when', _identity)
        self.assertEqual(response['statusCode'], 500)
        self.assertEqual(table.scan_kwargs, [])

    def test_projection_failure_is_caught_too(self):
        table = _FakeReportTable({'Items': [{'when': '1'}]})

        def _explode(_item):
            raise RuntimeError('cannot sign')

        response = helper.paged_report_response(_event({}), table, 'when', _explode)
        self.assertEqual(response['statusCode'], 500)
        self.assertEqual(_body(response), {'Error': 'cannot sign'})


if __name__ == '__main__':
    unittest.main()
