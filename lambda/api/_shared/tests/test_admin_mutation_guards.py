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


if __name__ == '__main__':
    unittest.main()
