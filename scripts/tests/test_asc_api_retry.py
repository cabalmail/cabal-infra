"""Regression tests for .github/scripts/asc_api.py's transient-failure retry.

A single App Store Connect 500 on the `GET /v1/apps/{id}/betaGroups` that
`assign-testflight-group.py` makes reddened an upload job whose binary was
already on the store (issue #1407): `api_request` had no retry at all, so
the 200 sitting one round trip behind the failure was never asked for.
These pin the retry's shape — which statuses, which methods, how many
attempts, and the backoff, including a server-supplied Retry-After.

The method rule is the load-bearing half: a repeat must not be able to
double an effect, so GET and HEAD retry unconditionally and anything else
only when its call site passes `idempotent=True`. The call-site tests at
the bottom pin which of the three mutating calls in the tree opted in.

PyJWT is a CI-step dependency of the scripts, not of this suite, so `jwt`
is faked in sys.modules before the module under test is imported.

Run in CI by `.github/workflows/scripts-tests.yml` on pull requests and on
pushes to the named branches. Run by hand from the repo root:

    python3 scripts/tests/test_asc_api_retry.py
"""

import email.message
import importlib.util
import io
import json
import os
import sys
import types
import unittest
import urllib.error
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPTS = os.path.join(REPO_ROOT, ".github", "scripts")

_jwt = types.ModuleType("jwt")
_jwt.encode = lambda *args, **kwargs: "fake.jwt.token"  # noqa: E731
sys.modules.setdefault("jwt", _jwt)
sys.path.insert(0, SCRIPTS)

import asc_api  # noqa: E402  pylint: disable=wrong-import-position

_spec = importlib.util.spec_from_file_location(
    "assign_testflight_group",
    os.path.join(SCRIPTS, "assign-testflight-group.py"),
)
assign = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(assign)

_spec = importlib.util.spec_from_file_location(
    "set_testflight_notes",
    os.path.join(SCRIPTS, "set-testflight-notes.py"),
)
notes_script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(notes_script)


def token_factory():
    return "fake.jwt.token"


class FakeResponse:
    """The context-manager shape urlopen returns on success."""

    def __init__(self, payload):
        self.payload = payload

    def read(self):
        return self.payload

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class Transport:
    """A urlopen stub driven by a list of outcomes; the last one repeats.

    An outcome is either `bytes` (a 200 with that body) or an `(int, dict)`
    pair (an HTTPError with that status and those headers).
    """

    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.calls = []

    def __call__(self, request, timeout=None):  # pylint: disable=unused-argument
        self.calls.append((request.get_method(), request.full_url))
        outcome = self.outcomes[min(len(self.calls) - 1, len(self.outcomes) - 1)]
        if isinstance(outcome, bytes):
            return FakeResponse(outcome)
        status, headers = outcome
        message = email.message.Message()
        for name, value in (headers or {}).items():
            message[name] = value
        raise urllib.error.HTTPError(
            "https://api.appstoreconnect.apple.com/v1/apps",
            status,
            f"HTTP {status}",
            message,
            io.BytesIO(b'{"errors":[{"detail":"upstream"}]}'),
        )

    @property
    def attempts(self):
        return len(self.calls)


class RetryHarness(unittest.TestCase):
    """Runs the real api_request over a stubbed transport and clock."""

    def drive(self, transport, *args, **kwargs):
        """Call api_request; return (result_or_error, recorded sleeps)."""
        sleeps = []
        with mock.patch.object(asc_api.urllib.request, "urlopen", transport), \
                mock.patch.object(asc_api.time, "sleep", sleeps.append):
            try:
                return asc_api.api_request(*args, **kwargs), sleeps
            except urllib.error.HTTPError as err:
                return err, sleeps


OK = json.dumps({"data": [{"id": "GRP1", "attributes": {"name": "stage"}}]}).encode()


class TransientFailureRetryTests(RetryHarness):
    """Which outcomes are retried, and how many times."""

    def test_success_is_one_attempt_and_parses(self):
        transport = Transport(OK)
        result, sleeps = self.drive(transport, "GET", "/v1/apps", token_factory)
        self.assertEqual(result["data"][0]["id"], "GRP1")
        self.assertEqual(transport.attempts, 1)
        self.assertEqual(sleeps, [])

    def test_500_then_200_returns_the_200(self):
        transport = Transport((500, {}), OK)
        result, sleeps = self.drive(transport, "GET", "/v1/apps", token_factory)
        self.assertEqual(result["data"][0]["id"], "GRP1")
        self.assertEqual(transport.attempts, 2)
        self.assertEqual(sleeps, [2.0])

    def test_429_then_200_returns_the_200(self):
        transport = Transport((429, {}), OK)
        result, _ = self.drive(transport, "GET", "/v1/apps", token_factory)
        self.assertEqual(result["data"][0]["id"], "GRP1")
        self.assertEqual(transport.attempts, 2)

    def test_persistent_5xx_raises_after_the_attempt_budget(self):
        transport = Transport((503, {}))
        result, sleeps = self.drive(transport, "GET", "/v1/apps", token_factory)
        self.assertIsInstance(result, urllib.error.HTTPError)
        self.assertEqual(result.code, 503)
        self.assertEqual(transport.attempts, asc_api.RETRY_ATTEMPTS)
        self.assertEqual(sleeps, [2.0, 4.0, 8.0])

    def test_a_4xx_that_is_not_429_raises_on_the_first_attempt(self):
        # The attach loop's refusals are 403/404/409 and are the caller's to
        # interpret; retrying them would only burn the poll window.
        for status in (400, 403, 404, 409):
            with self.subTest(status=status):
                transport = Transport((status, {}))
                result, sleeps = self.drive(
                    transport, "GET", "/v1/apps", token_factory
                )
                self.assertIsInstance(result, urllib.error.HTTPError)
                self.assertEqual(transport.attempts, 1)
                self.assertEqual(sleeps, [])

    def test_the_raised_error_body_is_still_readable(self):
        # assign-testflight-group.py reads err.read() for the ASC detail.
        transport = Transport((404, {}))
        result, _ = self.drive(transport, "GET", "/v1/apps", token_factory)
        self.assertIn("upstream", result.read().decode())

    def test_each_attempt_mints_a_fresh_token(self):
        minted = []

        def counting_factory():
            minted.append(len(minted))
            return f"token-{len(minted)}"

        transport = Transport((500, {}), (500, {}), OK)
        self.drive(transport, "GET", "/v1/apps", counting_factory)
        self.assertEqual(len(minted), 3)


class MethodEligibilityTests(RetryHarness):
    """A repeat must not be able to double an effect."""

    def test_a_post_is_not_retried_by_default(self):
        transport = Transport((500, {}), OK)
        result, sleeps = self.drive(
            transport, "POST", "/v1/betaBuildLocalizations", token_factory, {"a": 1}
        )
        self.assertIsInstance(result, urllib.error.HTTPError)
        self.assertEqual(transport.attempts, 1)
        self.assertEqual(sleeps, [])

    def test_a_post_marked_idempotent_is_retried(self):
        transport = Transport((500, {}), b"")
        result, _ = self.drive(
            transport,
            "POST",
            "/v1/builds/B1/relationships/betaGroups",
            token_factory,
            {"data": []},
            True,
        )
        self.assertIsNone(result)  # 204-shaped: empty body parses to None
        self.assertEqual(transport.attempts, 2)

    def test_a_patch_is_not_retried_by_default(self):
        transport = Transport((500, {}), OK)
        result, _ = self.drive(
            transport, "PATCH", "/v1/betaBuildLocalizations/L1", token_factory, {"a": 1}
        )
        self.assertIsInstance(result, urllib.error.HTTPError)
        self.assertEqual(transport.attempts, 1)


class RetryAfterTests(RetryHarness):
    """The server's own pacing wins, up to the cap."""

    def test_delta_seconds_header_is_honoured(self):
        transport = Transport((429, {"Retry-After": "5"}), OK)
        _, sleeps = self.drive(transport, "GET", "/v1/apps", token_factory)
        self.assertEqual(sleeps, [5.0])

    def test_an_absurd_retry_after_is_capped(self):
        transport = Transport((503, {"Retry-After": "600"}), OK)
        _, sleeps = self.drive(transport, "GET", "/v1/apps", token_factory)
        self.assertEqual(sleeps, [asc_api.RETRY_BACKOFF_CAP_SECONDS])

    def test_an_http_date_header_is_honoured(self):
        with mock.patch.object(asc_api.time, "time", lambda: 1_000_000.0):
            when = email.utils.formatdate(1_000_007.0, usegmt=True)
            transport = Transport((503, {"Retry-After": when}), OK)
            _, sleeps = self.drive(transport, "GET", "/v1/apps", token_factory)
        self.assertEqual(sleeps, [7.0])

    def test_a_past_http_date_does_not_sleep_negative(self):
        with mock.patch.object(asc_api.time, "time", lambda: 1_000_000.0):
            when = email.utils.formatdate(999_000.0, usegmt=True)
            transport = Transport((503, {"Retry-After": when}), OK)
            _, sleeps = self.drive(transport, "GET", "/v1/apps", token_factory)
        self.assertEqual(sleeps, [0.0])

    def test_an_unparseable_header_falls_back_to_backoff(self):
        transport = Transport((503, {"Retry-After": "soon"}), OK)
        _, sleeps = self.drive(transport, "GET", "/v1/apps", token_factory)
        self.assertEqual(sleeps, [2.0])


class ReportedCallPathTests(RetryHarness):
    """The exact call that failed in run 33519007312, end to end."""

    def test_find_group_id_survives_a_single_500(self):
        transport = Transport((500, {}), OK)
        sleeps = []
        with mock.patch.object(asc_api.urllib.request, "urlopen", transport), \
                mock.patch.object(asc_api.time, "sleep", sleeps.append):
            group_id = assign.find_group_id("APP1", "stage", token_factory)
        self.assertEqual(group_id, "GRP1")
        self.assertEqual(transport.attempts, 2)

    def test_find_app_id_and_find_build_survive_a_single_500(self):
        for call, payload in (
            (lambda: asc_api.find_app_id("com.cabalmail.Cabalmail", token_factory),
             json.dumps({"data": [{"id": "APP1"}]}).encode()),
            (lambda: asc_api.find_build("APP1", "42", token_factory),
             json.dumps({"data": [{"id": "B1"}]}).encode()),
        ):
            with self.subTest(call=call):
                transport = Transport((500, {}), payload)
                with mock.patch.object(
                    asc_api.urllib.request, "urlopen", transport
                ), mock.patch.object(asc_api.time, "sleep", lambda _s: None):
                    self.assertIsNotNone(call())
                self.assertEqual(transport.attempts, 2)


class CallSiteOptInTests(unittest.TestCase):
    """Which mutating calls in the tree opted into the retry, and which did not."""

    def test_attach_opts_in(self):
        # Its own doc comment is the argument: adding a build to a group it
        # is already in is a no-op success.
        seen = {}

        def recording_api_request(method, path, factory, body=None, idempotent=False):
            seen.update(method=method, path=path, idempotent=idempotent)
            return None

        with mock.patch.object(assign, "api_request", recording_api_request):
            assign.attach("GRP1", "B1", token_factory)
        self.assertEqual(seen["method"], "POST")
        self.assertTrue(seen["idempotent"])

    def test_set_notes_patches_idempotently_and_creates_without_retry(self):
        calls = []

        def recording_api_request(method, path, factory, body=None, idempotent=False):
            calls.append({"method": method, "idempotent": idempotent})
            # First call is the lookup; answer it with an existing
            # localization once, then with none, to reach both branches.
            if method == "GET":
                return {"data": [{"id": "L1"}] if len(calls) == 1 else []}
            return None

        with mock.patch.object(notes_script, "api_request", recording_api_request):
            notes_script.set_notes("B1", "en-US", "hello", token_factory)
            notes_script.set_notes("B1", "en-US", "hello", token_factory)

        patch_call = next(c for c in calls if c["method"] == "PATCH")
        post_call = next(c for c in calls if c["method"] == "POST")
        self.assertTrue(patch_call["idempotent"])
        self.assertFalse(post_call["idempotent"])


if __name__ == "__main__":
    unittest.main()
