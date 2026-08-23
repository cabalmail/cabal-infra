'''Unit test for every admin-guarded mutation carrying the rate limit and the
audit log, not just the admin-group check.

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_admin_mutation_guards.py

The failure this pins is one nothing connected. Issue #1200: `confirm_user`
ran the admin guard and neither of the other two, and so did `assign_address`,
`unassign_address` and `repair_dns_record` - four handlers that between them
confirm accounts, rewrite `cabal-addresses` rows and UPSERT Route 53 records
with no per-caller ceiling and no `AUDIT` line. The gap traced back to the
Phase 5 plan's enumerated list of five endpoints
(`docs/0.10.x/application-surface-hardening-plan.md`) rather than to a handler
someone skipped, so a list was the only thing saying which handlers were in
scope, and a new admin mutation joins the codebase without touching it.

The invariant: every `lambda/api/*/function.py` that runs the admin guard also
runs the rate limit and emits an audit line - either directly, or through
`admin_user_action_response`, which does all three. The exceptions are
read-only admin endpoints, named individually in `_READ_ONLY` below with what
each one reads, because "it is a read" is a claim that should be written down
rather than inferred from a handler's name.

No handler import and no third-party deps - this reads source off disk.
'''
import os
import re
import unittest

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_API_DIR = os.path.dirname(os.path.dirname(_TESTS_DIR))

# Admin endpoints that legitimately carry neither the rate limit nor an audit
# line, because they mutate nothing. Keyed by handler directory, valued with
# what the handler returns, so adding an entry means making a claim.
_READ_ONLY = {
    'list_users': 'lists the Cognito user pool',
    'list_addresses_admin': 'lists cabal-addresses rows',
    'list_user_domain_access': 'lists cabal-user-domain-access rows',
    'list_dmarc_reports': 'lists stored DMARC aggregate reports',
    'list_caa_reports': 'lists stored CAA reports',
    'check_dns_record': 'resolves a record and compares it to what Cabal expects',
}

_ADMIN_LIMITS = os.path.join(_API_DIR, '_shared', 'admin_limits.py')

# Prose asserting that a handler skips one of the two controls the admin-
# mutation contract requires. #1229: the envelope's own docstring still said
# confirm_user "runs neither the rate limit nor the audit log" after #1227 gave
# it both, and that sentence had already been read once as a rationale for the
# gap. A claim about the code, sitting in the code, is checkable.
_SKIPS_A_CONTROL = re.compile(
    r'runs neither|does not run|skips the (rate limit|audit)|'
    r'neither the rate limit|no rate limit|no audit line|'
    r'without the rate limit|without an audit',
    re.IGNORECASE
)

_ADMIN_GUARD = re.compile(r'\badmin_response_or_none\s*\(')
_RATE_LIMIT = re.compile(r'\brate_limit_response_or_none\s*\(')
_AUDIT = re.compile(r'\baudit_log\s*\(')
# `disable_user`/`enable_user` get guard, rate limit and audit in one call.
_COMBINED = re.compile(r'\badmin_user_action_response\s*\(')


def _handlers():
    '''Returns {endpoint directory: function.py source} for every API handler.'''
    found = {}
    for name in sorted(os.listdir(_API_DIR)):
        path = os.path.join(_API_DIR, name, 'function.py')
        if os.path.isfile(path):
            with open(path, encoding='utf-8') as handle:
                found[name] = handle.read()
    return found


def _admin_endpoints():
    '''Returns {endpoint: source} for every handler behind the admin guard.'''
    return {
        name: src for name, src in _handlers().items()
        if _ADMIN_GUARD.search(src) or _COMBINED.search(src)
    }


def _missing(src):
    '''Returns the guards `src` does not run, as a sorted list of names.'''
    if _COMBINED.search(src):
        return []
    gaps = []
    if not _RATE_LIMIT.search(src):
        gaps.append('rate_limit_response_or_none')
    if not _AUDIT.search(src):
        gaps.append('audit_log')
    return gaps


def _prose_sentences(path):
    '''Returns `path`'s text as whitespace-normalised sentences.

    The docstrings wrap across lines, so a claim about a handler is only one
    "sentence" after the newlines collapse.
    '''
    with open(path, encoding='utf-8') as handle:
        text = handle.read()
    text = re.sub(r'\s+', ' ', text)
    return [part.strip() for part in re.split(r'(?<=\.)\s+', text) if part.strip()]


def _stale_control_claims(sentences, admin):
    '''Returns {handler: sentence} for each sentence claiming a handler skips
    a control that `admin` proves it runs.

    Attribution is per sentence, not per clause: the #1229 sentence said "the
    first runs neither", so every handler it named is reported, including the
    one the claim was accurate about. That over-reports within a sentence,
    which is the right way round for a check whose remedy is a reword.
    '''
    found = {}
    for sentence in sentences:
        if not _SKIPS_A_CONTROL.search(sentence):
            continue
        for name, src in admin.items():
            if re.search(r'\b%s\b' % re.escape(name), sentence) and not _missing(src):
                found[name] = sentence
    return found


class AdminMutationGuardTests(unittest.TestCase):
    '''#1200: the admin guard alone is not the admin-mutation contract.'''

    def test_handlers_parsed(self):
        '''Floor: an empty scan would make every other assertion vacuous.'''
        handlers = _handlers()
        self.assertGreater(len(handlers), 30, sorted(handlers))
        self.assertIn('confirm_user', handlers)

    def test_admin_endpoints_found(self):
        '''Second floor, on the subset that matters: the detector has to find
        the admin endpoints, not just some files.'''
        admin = _admin_endpoints()
        self.assertGreaterEqual(len(admin), 10, sorted(admin))
        for expected in ('confirm_user', 'delete_user', 'disable_user',
                         'assign_address', 'repair_dns_record'):
            self.assertIn(expected, admin)

    def test_every_admin_mutation_runs_all_three(self):
        '''The invariant.'''
        offenders = {
            name: _missing(src)
            for name, src in _admin_endpoints().items()
            if name not in _READ_ONLY and _missing(src)
        }
        self.assertEqual(
            offenders, {},
            'admin mutations running the guard but not the rest: %r' % offenders
        )

    def test_read_only_exemptions_all_exist(self):
        '''An exemption for an endpoint that no longer exists is a stale claim
        that would silently cover a future handler of the same name.'''
        admin = _admin_endpoints()
        for name in _READ_ONLY:
            self.assertIn(name, admin, '%s is exempted but is not an admin endpoint' % name)

    def test_read_only_exemptions_are_actually_read_only(self):
        '''The exemption list is the one place this test trusts prose, so it
        gets checked against the code: a read must not write.'''
        writes = re.compile(
            r'\b(put_item|update_item|delete_item|batch_writer|'
            r'admin_confirm_sign_up|admin_delete_user|admin_disable_user|'
            r'admin_enable_user|admin_update_user_attributes|'
            r'change_resource_record_sets)\s*\('
        )
        admin = _admin_endpoints()
        for name in _READ_ONLY:
            self.assertIsNone(
                writes.search(admin[name]),
                '%s is exempted as read-only but calls a write API' % name
            )

    def test_detector_catches_a_handler_missing_both(self):
        '''Self-test on a synthetic handler, so a future rewrite cannot make
        the invariant pass by finding nothing.'''
        src = (
            'from admin_limits import admin_response_or_none\n'
            'def handler(event, _c):\n'
            '    denial = admin_response_or_none(event)\n'
        )
        self.assertTrue(_ADMIN_GUARD.search(src))
        self.assertEqual(_missing(src), ['rate_limit_response_or_none', 'audit_log'])

    def test_detector_catches_a_handler_missing_only_the_audit(self):
        '''The half-done case, which is what a partial fix looks like.'''
        src = (
            '    denial = admin_response_or_none(event)\n'
            "    limited = rate_limit_response_or_none(caller, 'x')\n"
        )
        self.assertEqual(_missing(src), ['audit_log'])

    def test_detector_accepts_the_combined_helper(self):
        '''`admin_user_action_response` runs all three, so a handler that uses
        it must not be reported as a gap.'''
        src = "    return admin_user_action_response(event, 'disable_user', 'disabled', op)\n"
        self.assertEqual(_missing(src), [])


class AdminLimitsProseTests(unittest.TestCase):
    """#1229: admin_limits.py's prose makes claims about handlers, and a claim
    that goes stale reads as a rationale for the gap it describes."""

    # The clause exactly as it shipped between #1227 and #1229, which is what
    # this detector exists to catch.
    STALE_1229 = (
        'caller. confirm_user and set_user_domain_access differ further still '
        '-- the first runs neither the rate limit nor the audit log, the '
        'second reads a three-field body and reports allowed/denied rather '
        'than a status word.'
    )

    def test_prose_parsed(self):
        """Floor: an empty or unsplit parse would pass the invariant vacuously."""
        sentences = _prose_sentences(_ADMIN_LIMITS)
        self.assertGreater(len(sentences), 20, len(sentences))
        named = [s for s in sentences if 'delete_user' in s or 'set_user_domain_access' in s]
        self.assertTrue(named, 'prose names none of the handlers it documents')

    def test_no_stale_control_claims(self):
        """The invariant."""
        stale = _stale_control_claims(_prose_sentences(_ADMIN_LIMITS), _admin_endpoints())
        self.assertEqual(
            stale, {},
            'admin_limits.py says these handlers skip a control they run: %r' % stale
        )

    def test_detector_catches_the_claim_from_1229(self):
        """Self-test on the real pre-fix sentence: restoring it must fail."""
        stale = _stale_control_claims([self.STALE_1229], _admin_endpoints())
        self.assertIn('confirm_user', stale)

    def test_detector_allows_a_claim_that_is_true(self):
        """Saying a handler skips a control is fine when it does -- otherwise
        the fix for a real gap would be to stop describing it."""
        admin = {'gappy': 'denial = admin_response_or_none(event)\n'}
        sentence = 'gappy runs neither the rate limit nor the audit log.'
        self.assertEqual(_stale_control_claims([sentence], admin), {})

    def test_detector_ignores_prose_with_no_control_claim(self):
        """Naming a handler is not making a claim about its controls."""
        admin = _admin_endpoints()
        sentence = 'confirm_user differs from disable_user only in which Cognito call it makes.'
        self.assertEqual(_stale_control_claims([sentence], admin), {})


if __name__ == '__main__':
    unittest.main()
