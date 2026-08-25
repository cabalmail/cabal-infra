'''Unit tests for the Bcc handling of the /send Sent copy.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_send_sent_copy_keeps_bcc.py

The Sent copy staged for the append_sent consumer keeps the Bcc header on
purpose: it is the sender's only record of who they blind-copied, and only
the mailbox owner can read Sent. /send used to strip it, which destroyed
that record irrecoverably at the moment of sending. Blindness is a wire
property, not a mailbox one - smtplib strips Bcc from the transmitted DATA
and the handler passes the RCPT TO list explicitly - so these pin both
halves of the contract: the staged copy carries Bcc, and the blind address
still receives the mail via the explicit recipient list.

Reuses the import-time fakes, the loaded handler, and the request builders
from test_send_dedupe_claim; setUp rebinds the module-level collaborators
the same way that suite does so the pair is order-independent under a
directory-wide `discover` run.
'''
import email
import types
import unittest

import test_send_dedupe_claim as harness

send = harness.send

TEST_BLIND = 'blind@qa.example.com'


class SentCopyKeepsBccTest(unittest.TestCase):
    '''Drives the real handler and captures what gets staged for Sent.'''

    def setUp(self):
        table = harness._FakeTable()  # pylint: disable=protected-access
        self.smtp = harness._FakeSMTP()  # pylint: disable=protected-access
        self.staged = []
        # pylint: disable=protected-access
        self._saved = (harness.compose._preferences_table, harness.helper.ddb_table,
                       send._dedupe_table, send.smtp_session,
                       send.upload_object, send.sqs)
        harness.compose._preferences_table = table
        harness.helper.ddb_table = table
        send._dedupe_table = harness._FakeDedupeTable()
        send.smtp_session = types.SimpleNamespace(dial_smtp=lambda _host: self.smtp)
        send.upload_object = (
            lambda _bucket, _key, _ctype, data: self.staged.append(data))
        send.sqs = types.SimpleNamespace(
            get_queue_url=lambda QueueName: {'QueueUrl': 'fake-queue-url'},
            send_message=lambda **_kw: None)

    def tearDown(self):
        # pylint: disable=protected-access
        (harness.compose._preferences_table, harness.helper.ddb_table,
         send._dedupe_table, send.smtp_session,
         send.upload_object, send.sqs) = self._saved

    def _deliver(self, **overrides):
        body = harness._body(**overrides)  # pylint: disable=protected-access
        event = harness._event(body)  # pylint: disable=protected-access
        response = send.handler(event, None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(len(self.staged), 1)
        return email.message_from_string(self.staged[0].decode())

    def test_sent_copy_keeps_the_bcc_header(self):
        staged = self._deliver(bcc_list=[TEST_BLIND])
        self.assertEqual(staged['Bcc'], TEST_BLIND,
                         'the Sent copy lost the sender\'s Bcc record')

    def test_blind_recipient_is_still_on_the_wire_recipient_list(self):
        # Keeping Bcc in the mailbox copy must not be the thing that
        # delivers it: the blind address rides the explicit RCPT TO list,
        # never the headers of the transmitted copy (smtplib strips those).
        self._deliver(bcc_list=[TEST_BLIND])
        self.assertEqual(len(self.smtp.sent), 1)
        _message_id, _from_addr, to_addrs = self.smtp.sent[0]
        self.assertIn(TEST_BLIND, to_addrs)

    def test_a_send_without_bcc_stages_no_bcc_header(self):
        staged = self._deliver()
        self.assertIsNone(staged['Bcc'])


if __name__ == '__main__':
    unittest.main()
