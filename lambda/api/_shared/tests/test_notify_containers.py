'''Unit tests for notify_containers, the address-changed publish now shared out
of address_events.py.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_notify_containers.py

address_events.py's only third-party import is boto3, faked in sys.modules
before import so the suite needs no AWS access. The cases pin the outcomes the
five address-mutation handlers relied on when each carried its own copy: the
exact SNS argument shape (the message body reconfigure.sh's subscriber sees),
the no-op-with-a-log-line when ADDRESS_CHANGED_TOPIC_ARN is unset, and a
publish failure propagating rather than being swallowed -- every caller runs
this inside a broad `except` that turns it into that handler's 500.'''
import json
import os
import sys
import types
import unittest
from datetime import datetime

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('ADDRESS_CHANGED_TOPIC_ARN', 'arn:aws:sns:us-east-1:1:address-changed')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

# --- fake boto3 --------------------------------------------------------------


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

import address_events  # noqa: E402  pylint: disable=wrong-import-position,import-error


class _FakeSNS:
    '''Records publish calls; optionally fails the way SNS would.'''

    def __init__(self, error=None):
        self.calls = []
        self.error = error

    def publish(self, **kwargs):
        self.calls.append(kwargs)
        if self.error:
            raise self.error


class NotifyContainersTest(unittest.TestCase):
    '''The published event is a wire contract: docker/shared/reconfigure.sh
    reacts to it, so shape and topic are pinned, not just "something published".'''

    def setUp(self):
        self.sns = _FakeSNS()
        self._real_sns = address_events.sns
        self._real_arn = address_events.address_changed_topic_arn
        address_events.sns = self.sns
        address_events.address_changed_topic_arn = 'arn:aws:sns:us-east-1:1:address-changed'

    def tearDown(self):
        address_events.sns = self._real_sns
        address_events.address_changed_topic_arn = self._real_arn

    def test_publishes_the_address_changed_event_to_the_configured_topic(self):
        address_events.notify_containers()
        self.assertEqual(len(self.sns.calls), 1)
        call = self.sns.calls[0]
        self.assertEqual(set(call), {'TopicArn', 'Message'})
        self.assertEqual(call['TopicArn'], 'arn:aws:sns:us-east-1:1:address-changed')
        message = json.loads(call['Message'])
        self.assertEqual(message['event'], 'address_changed')
        self.assertEqual(set(message), {'event', 'timestamp'})

    def test_timestamp_is_an_iso_8601_utc_instant(self):
        address_events.notify_containers()
        stamp = json.loads(self.sns.calls[0]['Message'])['timestamp']
        self.assertTrue(stamp.endswith('+00:00'), stamp)
        self.assertIsNotNone(datetime.fromisoformat(stamp).tzinfo)

    def test_an_unset_topic_arn_logs_and_publishes_nothing(self):
        address_events.address_changed_topic_arn = ''
        self.assertIsNone(address_events.notify_containers())
        self.assertEqual(self.sns.calls, [])

    def test_a_publish_failure_propagates_to_the_caller(self):
        address_events.sns = _FakeSNS(error=RuntimeError('sns is down'))
        with self.assertRaises(RuntimeError):
            address_events.notify_containers()


class TopicArnSourceTest(unittest.TestCase):
    '''The ARN is read from the environment at import, as it was in each
    handler; terraform sets ADDRESS_CHANGED_TOPIC_ARN on all five functions.'''

    def test_the_arn_comes_from_the_environment(self):
        self.assertEqual(address_events.address_changed_topic_arn,
                         os.environ['ADDRESS_CHANGED_TOPIC_ARN'])


if __name__ == '__main__':
    unittest.main()
