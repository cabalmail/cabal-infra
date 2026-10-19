"""The SMS consent checkbox says the same thing on every sign-up surface.

The 10DLC campaign registration quotes the webmail's checkbox text word for
word (docs/sms-10dlc.md), and the native sign-up screens show the same
consent under that registration (auth parity plan, D5, B2 and B3). So
the Apple and Android apps' text must not drift from the webmail's. All
three build the brand the same way at run time, so the comparison puts a
placeholder where each inserts it.

Runs from scripts-tests.yml, whose paths list all three files.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WEBMAIL = ROOT / "react/admin/src/SignUp/index.jsx"
APPLE = ROOT / "apple/CabalmailUI/Session/SignUp/SignUpModel.swift"
ANDROID = ROOT / "android/app/src/main/kotlin/com/cabalmail/android/ui/auth/SignUpRules.kt"


def _collapse(text):
    return " ".join(text.split())


def webmail_text(source):
    """The consent label's text, as the browser renders it."""
    match = re.search(r'<span className="auth__consent-label">(.*?)</span>', source, re.S)
    if not match:
        raise AssertionError(f"no auth__consent-label span in {WEBMAIL}")
    text = match.group(1)
    text = text.replace("{smsBrand}", "<brand>").replace("{' '}", " ").replace("&mdash;", "—")
    text = re.sub(r"</?code>", "", text)
    return _collapse(text)


def apple_text(source):
    """`smsConsentText`'s returned string, its literals joined."""
    match = re.search(r"var smsConsentText: String \{(.*?)\n    \}", source, re.S)
    if not match:
        raise AssertionError(f"no smsConsentText in {APPLE}")
    returned = match.group(1).split("return", 1)[1]
    literals = re.findall(r'"((?:[^"\\]|\\.)*)"', returned)
    if not literals:
        raise AssertionError(f"smsConsentText in {APPLE} returns no string literals")
    return _collapse("".join(literals).replace("\\(brand)", "<brand>"))


def android_text(source):
    """`SignUpRules.consentText`'s returned string, its literals joined."""
    match = re.search(r"fun consentText\(operatorName: String\): String \{(.*?)\n    \}", source, re.S)
    if not match:
        raise AssertionError(f"no consentText in {ANDROID}")
    returned = match.group(1).split("return", 1)[1]
    literals = re.findall(r'"((?:[^"\\]|\\.)*)"', returned)
    if not literals:
        raise AssertionError(f"consentText in {ANDROID} returns no string literals")
    return _collapse("".join(literals).replace("$brand", "<brand>"))


class SmsConsentTextTest(unittest.TestCase):
    def test_apple_matches_the_webmail_word_for_word(self):
        webmail = webmail_text(WEBMAIL.read_text(encoding="utf-8"))
        apple = apple_text(APPLE.read_text(encoding="utf-8"))
        self.assertIn("<brand>", webmail)
        self.assertEqual(apple, webmail)

    def test_android_matches_the_webmail_word_for_word(self):
        webmail = webmail_text(WEBMAIL.read_text(encoding="utf-8"))
        android = android_text(ANDROID.read_text(encoding="utf-8"))
        self.assertEqual(android, webmail)

    def test_a_changed_word_is_caught(self):
        """The extraction is not so loose that a different text passes."""
        webmail = webmail_text(WEBMAIL.read_text(encoding="utf-8"))
        changed = APPLE.read_text(encoding="utf-8").replace("transactional SMS", "marketing SMS")
        self.assertNotEqual(apple_text(changed), webmail)
        changed = ANDROID.read_text(encoding="utf-8").replace("transactional SMS", "marketing SMS")
        self.assertNotEqual(android_text(changed), webmail)


if __name__ == "__main__":
    unittest.main()
