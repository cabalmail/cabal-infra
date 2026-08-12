'''Unit tests for the /send Message-Id dedupe claim lifecycle.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_send_dedupe_claim.py

/send claims the Message-Id in the dedupe table before SMTP so a retried
send cannot deliver twice, and releases the claim when delivery fails. It
used to release only when `send()` RETURNED a non-200 -- anything that
raised between the claim and the handoff (a relay refusing the connection,
dialed outside `send()`'s try; a socket timeout mid-DATA; the bad `to_list`
shape the report hit, now rejected upstream as a 400) left the claim
behind. The client's retry then matched the orphaned claim and got 200
"submitted" for a message nobody ever sent (#909).

These cover both directions of that: a raise under the claim must release
it (so the retry really sends), and a completed handoff must keep it (so
the retry does not deliver twice) even if closing the connection throws.

They also cover when the claim stops holding. The TTL is the escape hatch
from an orphaned claim, but DynamoDB reaps expired rows best-effort, so the
row is routinely still there after `expires_at` and an existence-only
condition kept honouring it - measured 192 s past expiry on stage (#1018).
The claim now compares `expires_at`, so the window is the 600 s the
constant advertises rather than however long the row survives.

Third-party imports are faked in sys.modules before import as in the
sibling suites; `helper` and `compose` are the real modules, and the
handler is loaded under a unique module name (#860/#863).
'''
import importlib.util
import json
import os
import smtplib
import sys
import time
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_API = os.path.dirname(_SHARED)
sys.path.insert(0, _SHARED)

TEST_USER = 'testuser'
TEST_SENDER = 'daily@qa.example.com'
TEST_MESSAGE_ID = '<claimprobe0804-1@qa.example.com>'

# --- fake boto3 / botocore ---------------------------------------------------


class _FakeTable:
    '''cabal-addresses / cabal-user-preferences stand-in, authorizing
    TEST_USER for TEST_SENDER so the handler reaches the delivery path.'''

    def get_item(self, Key=None, **_kwargs):  # pylint: disable=invalid-name
        if Key and Key.get('address') == TEST_SENDER:
            return {"Item": {"address": TEST_SENDER, "user": TEST_USER}}
        return {}


class _FakeResource:
    def Table(self, _name):  # pylint: disable=invalid-name
        return _FakeTable()


class _FakeSSMExceptions:
    class ParameterNotFound(Exception):
        pass


class _FakeSSM:
    exceptions = _FakeSSMExceptions

    def get_parameter(self, Name=None, **_kwargs):  # pylint: disable=invalid-name
        if Name == '/cabal/maintenance/imap':
            raise _FakeSSMExceptions.ParameterNotFound()
        return {"Parameter": {"Value": "fake-master-password"}}


if 'boto3' not in sys.modules:
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

if 'imap_session' not in sys.modules:
    _imap_session = types.ModuleType("imap_session")
    _imap_session.open_imap_client = lambda *_a, **_kw: None
    sys.modules['imap_session'] = _imap_session

if 'smtp_session' not in sys.modules:
    _smtp_session = types.ModuleType("smtp_session")
    _smtp_session.open_smtp_client = lambda *_a, **_kw: None
    sys.modules['smtp_session'] = _smtp_session

if 'imapclient' not in sys.modules:
    _imapclient = types.ModuleType("imapclient")
    _imapclient_exceptions = types.ModuleType("imapclient.exceptions")

    class _IMAPClientError(Exception):
        pass

    _imapclient_exceptions.IMAPClientError = _IMAPClientError
    _imapclient.exceptions = _imapclient_exceptions
    sys.modules['imapclient'] = _imapclient
    sys.modules['imapclient.exceptions'] = _imapclient_exceptions

import compose  # noqa: E402  pylint: disable=wrong-import-position
import helper  # noqa: E402  pylint: disable=wrong-import-position


def _load_handler(name):
    '''Imports lambda/api/<name>/function.py under a unique module name.'''
    path = os.path.join(_API, name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'function_{name}', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


send = _load_handler('send')


class _FakeDedupeTable:
    '''cabal-rate-limits stand-in implementing the one conditional write
    and the one delete the claim lifecycle uses.

    `claims` maps pk -> the stored `expires_at`, because a row outliving its
    TTL is exactly the state #1018 is about: DynamoDB reaps best-effort, so
    an expired row is still physically there to be conditioned on. The
    condition is EVALUATED rather than assumed - the handler only gets past
    a stale row if the expression it passes actually says so.'''

    def __init__(self):
        self.claims = {}

    def _condition_holds(self, key, expression, names, values):
        '''Evaluates the `A OR B` condition shapes this handler writes,
        resolving `#name` placeholders the way DynamoDB does.'''
        expression = expression or 'attribute_not_exists(pk)'
        for placeholder, attribute in (names or {}).items():
            expression = expression.replace(placeholder, attribute)
        for term in expression.split(' OR '):
            term = term.strip()
            if term == 'attribute_not_exists(pk)':
                if key not in self.claims:
                    return True
            elif term == 'expires_at < :now':
                assert ':now' in values, 'condition references :now but none was passed'
                stored = self.claims.get(key)
                if stored is not None and stored < values[':now']:
                    return True
            else:
                raise AssertionError(f'unmodelled condition term: {term!r}')
        return False

    # pylint: disable=invalid-name
    def put_item(self, Item=None, ConditionExpression=None,
                 ExpressionAttributeNames=None, ExpressionAttributeValues=None,
                 **_kwargs):
        key = Item['pk']
        if not self._condition_holds(key, ConditionExpression,
                                     ExpressionAttributeNames or {},
                                     ExpressionAttributeValues or {}):
            # The module bound whichever ClientError its botocore import
            # resolved to, so raise that class rather than this file's fake.
            err = send.ClientError(
                {'Error': {'Code': 'ConditionalCheckFailedException'}}, 'PutItem')
            err.response = {'Error': {'Code': 'ConditionalCheckFailedException'}}
            raise err
        self.claims[key] = Item.get('expires_at')

    def delete_item(self, Key=None, **_kwargs):  # pylint: disable=invalid-name
        self.claims.pop(Key['pk'], None)


class _FakeSMTP:
    '''Minimal smtplib.SMTP_SSL stand-in. `on_send` and `on_quit` let a
    case make either step throw the way a real relay can.'''

    def __init__(self, on_send=None, on_quit=None):
        self.on_send = on_send
        self.on_quit = on_quit
        self.sent = []
        self.quit_calls = 0

    def login(self, _user, _password):
        return None

    def send_message(self, msg, from_addr=None, to_addrs=None):
        if self.on_send:
            raise self.on_send
        self.sent.append((msg['Message-Id'], from_addr, tuple(to_addrs or ())))

    def quit(self):
        self.quit_calls += 1
        if self.on_quit:
            raise self.on_quit


def _body(**overrides):
    '''A complete, valid /send body carrying a fixed Message-Id.'''
    body = {
        'host': 'imap.qa.example.com',
        'smtp_host': 'smtp.qa.example.com',
        'sender': TEST_SENDER,
        'to_list': [TEST_SENDER],
        'cc_list': [],
        'bcc_list': [],
        'subject': 'claimprobe0804',
        'html': '<p>probe</p>',
        'text': 'probe',
        'draft': False,
        'attachments': [],
        'other_headers': {
            'message_id': [TEST_MESSAGE_ID],
            'in_reply_to': [],
            'references': [],
        },
    }
    body.update(overrides)
    return body


def _event(body):
    '''Wraps a body in the API Gateway event shape the handler reads.'''
    return {
        "body": json.dumps(body),
        "requestContext": {"authorizer": {"claims": {"cognito:username": TEST_USER}}},
    }


class SendClaimLifecycleTest(unittest.TestCase):
    '''Rebinds the module-level tables and the SMTP dialer the handler
    resolved at import time, so the suite is correct under a directory-wide
    `discover` run where a sibling suite's fake may have won the import.'''

    def setUp(self):
        table = _FakeTable()
        self.dedupe = _FakeDedupeTable()
        self.smtp = _FakeSMTP()
        self.dial_error = None
        # pylint: disable=protected-access
        self._saved = (compose._preferences_table, helper.ddb_table,
                       send._dedupe_table, send.smtp_session)
        compose._preferences_table = table
        helper.ddb_table = table
        send._dedupe_table = self.dedupe
        send.smtp_session = types.SimpleNamespace(dial_smtp=self._dial)

    def tearDown(self):
        # pylint: disable=protected-access
        (compose._preferences_table, helper.ddb_table,
         send._dedupe_table, send.smtp_session) = self._saved

    def _dial(self, _host):
        if self.dial_error:
            raise self.dial_error
        return self.smtp

    @property
    def _claim_key(self):
        return f'senddedupe#{TEST_MESSAGE_ID}'

    def _failed_attempt(self, body):
        '''Runs a send that is expected to fail, tolerating the pre-fix
        shape of that failure (an exception out of the handler) so the
        assertions can be about what the RETRY gets.'''
        try:
            send.handler(_event(body), None)
        except Exception:  # pylint: disable=broad-except
            pass

    def _assert_claimed(self, claimed):
        self.assertEqual(self._claim_key in self.dedupe.claims, claimed)

    def test_valid_send_delivers_and_holds_the_claim(self):
        response = send.handler(_event(_body()), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(len(self.smtp.sent), 1)
        self._assert_claimed(True)

    def test_retry_of_a_delivered_message_does_not_deliver_twice(self):
        send.handler(_event(_body()), None)
        response = send.handler(_event(_body()), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(json.loads(response['body'])['status'], 'submitted')
        self.assertEqual(len(self.smtp.sent), 1)

    def test_raise_under_the_claim_releases_it_and_answers(self):
        # A raise the named smtplib handlers do not cover: a socket timeout
        # mid-DATA is an OSError, so before the wrap it went straight out of
        # the handler with the claim still held (#909). The tester's own
        # trigger - `to_list` as a bare string - is now rejected upstream as
        # a 400 (see test_compose_required_fields.HandlerListShapeTest), so
        # it no longer reaches the claim; the wrap still has to hold for
        # everything else that can raise in here.
        self.smtp.on_send = TimeoutError('timed out')
        response = send.handler(_event(_body()), None)
        self.assertEqual(response['statusCode'], 500)
        self.assertIn('not delivered', json.loads(response['body'])['status'])
        self.assertEqual(self.smtp.sent, [])
        self._assert_claimed(False)

    def test_retry_after_a_raise_under_the_claim_actually_sends(self):
        # The bug as the user meets it. The first attempt is swallowed here
        # because before the fix it did not answer at all - it died, and API
        # Gateway turned that into a bodiless 502 - so the assertion that
        # matters is on the retry, which was answered 200 "submitted" while
        # nothing went out.
        self.smtp.on_send = TimeoutError('timed out')
        self._failed_attempt(_body())
        self.smtp.on_send = None
        response = send.handler(_event(_body()), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(len(self.smtp.sent), 1,
                         'the retry was told "submitted" without sending')

    def test_relay_refusing_the_connection_releases_the_claim(self):
        # The production trigger: dial_smtp is what a relay outage breaks.
        self.dial_error = ConnectionRefusedError('connection refused')
        response = send.handler(_event(_body()), None)
        self.assertEqual(response['statusCode'], 500)
        self.assertIn('SMTP relay', json.loads(response['body'])['status'])
        self._assert_claimed(False)

    def test_retry_after_a_relay_outage_actually_sends(self):
        self.dial_error = ConnectionRefusedError('connection refused')
        self._failed_attempt(_body())
        self.dial_error = None
        response = send.handler(_event(_body()), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(len(self.smtp.sent), 1,
                         'the retry was told "submitted" without sending')

    def test_a_failed_quit_after_delivery_keeps_the_claim(self):
        # The message is already on the relay; releasing here would let the
        # retry deliver a second copy.
        self.smtp.on_quit = smtplib.SMTPServerDisconnected('connection lost')
        response = send.handler(_event(_body()), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(len(self.smtp.sent), 1)
        self._assert_claimed(True)
        send.handler(_event(_body()), None)
        self.assertEqual(len(self.smtp.sent), 1)

    def test_a_handled_smtp_failure_still_releases_the_claim(self):
        # Unchanged behavior, guarded: send() returns a non-200 of its own
        # for the errors it names, and the claim goes with it.
        self.smtp.on_send = smtplib.SMTPSenderRefused(550, b'no', TEST_SENDER)
        response = send.handler(_event(_body()), None)
        self.assertEqual(response['statusCode'], 401)
        self._assert_claimed(False)

    def _seed_claim(self, offset):
        '''Plants a surviving claim whose expires_at is `offset` seconds away.'''
        self.dedupe.claims[self._claim_key] = int(time.time()) + offset

    def test_a_claim_past_its_ttl_no_longer_blocks(self):
        # The defect (#1018): TTL deletion is best-effort, so the row outlives
        # its own expires_at - measured at 192 s past on stage - and an
        # existence-only condition kept refusing the send. The refusal is the
        # silent one (200 "submitted"), so nothing upstream notices.
        self._seed_claim(-1)
        response = send.handler(_event(_body()), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(len(self.smtp.sent), 1,
                         'a claim past its own TTL still blocked the send')
        self.assertGreater(self.dedupe.claims[self._claim_key], int(time.time()),
                           'the expired claim was not replaced with a fresh one')

    def test_a_live_claim_still_blocks(self):
        # The other direction: expiry must not become a hole in the dedupe
        # the whole claim exists for.
        self._seed_claim(send.SEND_DEDUPE_TTL // 2)
        expires_at = self.dedupe.claims[self._claim_key]
        response = send.handler(_event(_body()), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(json.loads(response['body'])['status'], 'submitted')
        self.assertEqual(self.smtp.sent, [])
        self.assertEqual(self.dedupe.claims[self._claim_key], expires_at,
                         'a refused claim must not have its window extended')

    def test_only_unexpired_claims_block(self):
        # The invariant rather than the two cases: blocked iff the surviving
        # row is still live, at any age on either side. Offset 0 is left out
        # as a coin flip - the handler truncates its clock to whole seconds.
        for offset in (-86400, -600, -60, -1, 1, 60, 600, 86400):
            with self.subTest(offset=offset):
                self.smtp.sent.clear()
                self._seed_claim(offset)
                send.handler(_event(_body()), None)
                delivered = len(self.smtp.sent) == 1
                self.assertEqual(
                    delivered, offset < 0,
                    f'claim expiring {offset:+d}s from now: delivered={delivered}')


if __name__ == '__main__':
    unittest.main()
