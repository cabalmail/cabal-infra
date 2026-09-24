#!/usr/bin/env python3
"""Unit tests for the pure helpers in .github/scripts/mail-probe.py.

    python3 -m unittest discover -s scripts/tests -p "test_*.py"

No network: the Cognito, API, SMTP and SSM paths are exercised by the
mail-probe job itself against a live environment (docs/mail-probe.md).
"""

import importlib.util
import os
import unittest
from email.parser import HeaderParser

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPT = os.path.join(_HERE, "..", "..", ".github", "scripts", "mail-probe.py")
_spec = importlib.util.spec_from_file_location("mail_probe", _SCRIPT)
probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(probe)


class TotpTests(unittest.TestCase):
    # RFC 6238 appendix B: the ASCII secret "12345678901234567890", SHA-1.
    SECRET = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    def test_rfc6238_vectors(self):
        self.assertEqual(probe.totp_code(self.SECRET, now=59), "287082")
        self.assertEqual(probe.totp_code(self.SECRET, now=1111111109), "081804")
        self.assertEqual(probe.totp_code(self.SECRET, now=1234567890), "005924")

    def test_tolerates_spaces_lowercase_and_missing_padding(self):
        spaced = "gezd gnbv gy3t qojq gezd gnbv gy3t qojq"
        self.assertEqual(probe.totp_code(spaced, now=59), "287082")


class ParseMxTests(unittest.TestCase):
    def test_orders_by_preference_and_normalizes_hosts(self):
        out = "20 backup.example.net.\n10 SMTP-IN.example.net.\n"
        self.assertEqual(probe.parse_mx(out), ["smtp-in.example.net", "backup.example.net"])

    def test_ignores_noise(self):
        self.assertEqual(probe.parse_mx(";; connection timed out; no servers could be reached\n"), [])
        self.assertEqual(probe.parse_mx(""), [])


class ProbeUidsTests(unittest.TestCase):
    ENVELOPES = {
        7: {"subject": "[ci-probe] api 123.1"},
        8: {"subject": "[ci-probe] mx 123.1"},
        9: {"subject": "Re: [ci-probe] api 123.1"},
        10: {"subject": "Weekly digest"},
        11: {},
    }

    def test_exact_subjects(self):
        self.assertEqual(probe.probe_uids(self.ENVELOPES, {"[ci-probe] api 123.1"}),
                         {7: "[ci-probe] api 123.1"})

    def test_prefix_sweep_never_matches_replies_or_other_mail(self):
        self.assertEqual(set(probe.probe_uids(self.ENVELOPES)), {7, 8})


class ChooseAddressTests(unittest.TestCase):
    ITEMS = [
        {"address": "old@mail-admin.example.com", "suspended": True},
        {"address": "new@mail-admin.example.com", "pending": True},
        {"address": "ci-probe@mail-admin.example.com"},
        {"address": "second@mail-admin.example.com"},
    ]

    def test_first_active_by_default(self):
        self.assertEqual(probe.choose_address(self.ITEMS), "ci-probe@mail-admin.example.com")

    def test_wanted_must_be_active(self):
        self.assertEqual(probe.choose_address(self.ITEMS, "second@mail-admin.example.com"),
                         "second@mail-admin.example.com")
        with self.assertRaises(probe.ProbeError):
            probe.choose_address(self.ITEMS, "old@mail-admin.example.com")
        with self.assertRaises(probe.ProbeError):
            probe.choose_address(self.ITEMS, "nobody@mail-admin.example.com")

    def test_no_addresses(self):
        with self.assertRaises(probe.ProbeError):
            probe.choose_address([])


class DkimDomainTests(unittest.TestCase):
    def test_extracts_d_tag_across_folds(self):
        headers = HeaderParser().parsestr(
            "DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed;\n"
            "\td=example.net; s=cabal; h=from:to:subject;\n"
            "\tbh=abc=; b=def=\n"
            "Subject: x\n\n")
        self.assertEqual(probe.dkim_domain(headers), "example.net")

    def test_missing_header_and_missing_tag(self):
        self.assertIsNone(probe.dkim_domain(HeaderParser().parsestr("Subject: x\n\n")))
        self.assertEqual(probe.dkim_domain(HeaderParser().parsestr(
            "DKIM-Signature: v=1; a=rsa-sha256\n\n")), "?")


class ExistingFoldersTests(unittest.TestCase):
    def test_reads_the_folders_list(self):
        payload = {"folders": ["INBOX", "Sent", "Trash", "Work/Receipts"],
                   "sub_folders": ["INBOX"]}
        self.assertEqual(probe.existing_folders(payload),
                         {"INBOX", "Sent", "Trash", "Work/Receipts"})

    def test_fresh_mailbox_and_odd_payloads(self):
        self.assertEqual(probe.existing_folders({"folders": ["INBOX"]}), {"INBOX"})
        self.assertEqual(probe.existing_folders({}), set())
        self.assertEqual(probe.existing_folders({"folders": None}), set())
        self.assertEqual(probe.existing_folders({"folders": ["INBOX", 7, None]}), {"INBOX"})


class SquashTests(unittest.TestCase):
    def test_collapses_and_truncates(self):
        self.assertEqual(probe.squash("a \n\t b"), "a b")
        self.assertEqual(probe.squash("x" * 200, limit=10), "xxxxxxx...")


class ArgsTests(unittest.TestCase):
    def test_legs_parsing(self):
        args = probe.parse_args(["--control-domain", "example.net", "--legs", "mx"])
        self.assertEqual(args.legs, ["mx"])
        args = probe.parse_args(["--control-domain", "example.net"])
        self.assertEqual(args.legs, ["api", "mx"])

    def test_rejects_unknown_leg(self):
        with self.assertRaises(SystemExit):
            probe.parse_args(["--control-domain", "example.net", "--legs", "imap"])


if __name__ == "__main__":
    unittest.main()
