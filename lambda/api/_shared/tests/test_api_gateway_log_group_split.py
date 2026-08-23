'''Unit test for the API Gateway access log and execution log living in
separate CloudWatch log groups.

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_api_gateway_log_group_split.py

Issue #1233: the stage's `access_log_settings.destination_arn` pointed at
`aws_cloudwatch_log_group.api_logs` -- the group API Gateway's *execution*
logging writes to, whose name the service fixes as
API-Gateway-Execution-Logs_<rest-api-id>/<stage>. Sharing one group means one
retention for two signals that want different answers: the execution log held
request and response bodies and truncated Authorization headers until #1223
turned data tracing off, and the only lever for ageing that history out --
retention on the group -- would have taken the per-request access log with it.

The invariant: the access log's destination is a group that is not the
execution-log group, and every log group this module declares carries an
explicit retention. Neither half is visible in a plan once the config is
written, and the failure mode is silent -- a `destination_arn` pointed back at
`api_logs` is a one-token edit that plans clean and re-entangles the two.

The second half of #1233 spends that separation: the execution log drops to 30
days so the body history ages out, while the access log keeps the year. That
asymmetry is the whole point of splitting the groups, so it is pinned here too
-- along with the `#checkov:skip=CKV_AWS_338` it needs, because the IaC gate
enforces a one-year floor and a retention below it without a co-located,
reasoned skip fails CI. A skip written against the wrong group would both fail
the gate and leave that group unscanned.

No handler import and no third-party deps - this reads one file off disk.
'''
import os
import re
import unittest

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(_TESTS_DIR))))
_APP_MODULE = os.path.join(_REPO_ROOT, 'terraform', 'infra', 'modules', 'app')
_MAIN_TF = os.path.join(_APP_MODULE, 'main.tf')

# The literal AWS fixes for an execution log group. A group whose name is built
# from this prefix is the execution log by definition, wherever it is declared.
_EXECUTION_PREFIX = 'API-Gateway-Execution-Logs_'

_LOG_GROUP = re.compile(
    r'resource\s+"aws_cloudwatch_log_group"\s+"([^"]+)"\s*\{', re.MULTILINE
)
_DESTINATION = re.compile(
    r'destination_arn\s*=\s*aws_cloudwatch_log_group\.([A-Za-z0-9_]+)\.arn'
)
_NAME = re.compile(r'name\s*=\s*"([^"]*)"')
_RETENTION = re.compile(r'retention_in_days\s*=\s*(\d+)')
_SKIP = re.compile(r'#\s*checkov:skip=([A-Za-z0-9_]+):\s*(\S.*?)\s*$', re.MULTILINE)

# The decision recorded on #1233. The execution log carries the bodies, so it
# ages out; the access log is the per-request record worth keeping.
_EXECUTION_RETENTION = 30
_RETENTION_FLOOR_CHECK = 'CKV_AWS_338'


def _read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def _brace_block(source, open_index):
    '''Returns the text between the brace at `open_index` and its match.

    A body cannot be matched with `[^}]*`: `${...}` interpolation puts a closing
    brace inside the name, which ends the block early and reads as a group with
    no name and no retention -- i.e. as a pass on two of the assertions below.
    '''
    depth = 0
    for i in range(open_index, len(source)):
        if source[i] == '{':
            depth += 1
        elif source[i] == '}':
            depth -= 1
            if depth == 0:
                return source[open_index + 1:i]
    raise AssertionError('unbalanced braces from index %d' % open_index)


def _log_groups(source):
    '''Maps each declared log group's local name to its (name, retention).'''
    found = {}
    for match in _LOG_GROUP.finditer(source):
        local = match.group(1)
        body = _brace_block(source, match.end() - 1)
        name = _NAME.search(body)
        retention = _RETENTION.search(body)
        found[local] = (
            name.group(1) if name else None,
            int(retention.group(1)) if retention else None,
        )
    return found


def _skips(source):
    '''Maps each declared log group's local name to its {check id: reason}.

    Read per block rather than per file: a skip is only effective where it is
    co-located with the resource it excuses, and one on the wrong group would
    leave that group unscanned while the intended one still fails the gate.
    '''
    found = {}
    for match in _LOG_GROUP.finditer(source):
        body = _brace_block(source, match.end() - 1)
        found[match.group(1)] = dict(_SKIP.findall(body))
    return found


def _access_log_destinations(source):
    '''The local names every access_log_settings block points at.'''
    return [match.group(1) for match in _DESTINATION.finditer(source)]


class ApiGatewayLogGroupSplitTests(unittest.TestCase):
    '''Pins the access log and the execution log to separate groups.'''

    def setUp(self):
        self.source = _read(_MAIN_TF)
        self.groups = _log_groups(self.source)
        self.destinations = _access_log_destinations(self.source)
        self.skips = _skips(self.source)

    def test_the_module_is_parsed(self):
        '''A floor: an empty parse would pass every assertion below.'''
        self.assertGreaterEqual(len(self.groups), 2, 'expected both log groups')
        self.assertEqual(len(self.destinations), 1, 'expected one access log destination')

    def test_exactly_one_group_is_the_execution_log(self):
        '''The execution log is identified by AWS's own name, not by ours, so a
        rename cannot hide it from this test.'''
        execution = [local for local, (name, _) in self.groups.items()
                     if name and _EXECUTION_PREFIX in name]
        self.assertEqual(execution, ['api_logs'])

    def test_the_access_log_is_not_the_execution_log(self):
        '''The defect. One group means one retention for two signals.'''
        for local in self.destinations:
            name = self.groups.get(local, (None, None))[0]
            self.assertIsNotNone(name, f'{local} is not a group this module declares')
            self.assertNotIn(
                _EXECUTION_PREFIX, name,
                'the access log is writing into the execution log group, so the two '
                'cannot be retained apart (#1233)'
            )

    def test_every_group_has_an_explicit_retention(self):
        '''A group left without one never expires, which is what makes the
        retention question answerable at all.'''
        for local, (_, retention) in self.groups.items():
            self.assertIsNotNone(retention, f'{local} has no retention_in_days')

    def test_the_execution_log_ages_out(self):
        """The decision on #1233: 30 days on the group that held the bodies."""
        self.assertEqual(self.groups['api_logs'][1], _EXECUTION_RETENTION)

    def test_the_access_log_outlives_the_execution_log(self):
        """What separating the groups bought. Raising the execution log back to
        match would plan clean, keep every other assertion here green, and
        quietly restore the entanglement the split exists to end."""
        destination = self.destinations[0]
        self.assertLess(
            self.groups['api_logs'][1], self.groups[destination][1],
            'the execution log is retained at least as long as the access log, so '
            'the split is declared but unspent (#1233)'
        )

    def test_the_retention_floor_is_skipped_where_it_is_broken(self):
        """A retention under a year fails the IaC gate, and the skip has to sit
        on this group and carry its reason -- one written against the access
        log would fail the gate anyway and unscan the wrong resource."""
        self.assertIn(
            _RETENTION_FLOOR_CHECK, self.skips['api_logs'],
            f'{_RETENTION_FLOOR_CHECK} is not skipped on the group that breaks its floor'
        )
        self.assertGreater(len(self.skips['api_logs'][_RETENTION_FLOOR_CHECK]), 40,
                           'the skip carries no rationale')
        for local, (_, retention) in self.groups.items():
            if retention is not None and retention >= 365:
                self.assertNotIn(
                    _RETENTION_FLOOR_CHECK, self.skips[local],
                    f'{local} meets the one-year floor and does not need the skip'
                )

    def test_detector_catches_an_unspent_split(self):
        """The detector self-test for the retention half: two groups at the same
        retention are the shape this suite exists to reject, and a skip on a
        group that does not need one must be visible."""
        unspent = '''
        resource "aws_cloudwatch_log_group" "api_logs" {
          #checkov:skip=CKV_AWS_338:a reason long enough to look deliberate but on the wrong group
          name              = "API-Gateway-Execution-Logs_${id}/${var.stage_name}"
          retention_in_days = 365
        }
        resource "aws_cloudwatch_log_group" "api_access_logs" {
          name              = "/cabal/apigateway/access/x"
          retention_in_days = 365
        }
        '''
        groups = _log_groups(unspent)
        self.assertEqual(groups['api_logs'][1], groups['api_access_logs'][1])
        self.assertIn(_RETENTION_FLOOR_CHECK, _skips(unspent)['api_logs'])
        self.assertEqual(_skips(unspent)['api_access_logs'], {})

    def test_detector_catches_a_shared_group(self):
        '''The detector self-test: a synthetic config with the pre-fix wiring
        must be caught, so a future rewrite cannot make this suite vacuous.'''
        shared = '''
        resource "aws_cloudwatch_log_group" "api_logs" {
          name              = "API-Gateway-Execution-Logs_${id}/${var.stage_name}"
          retention_in_days = 365
        }
        resource "aws_api_gateway_stage" "api_stage" {
          access_log_settings {
            destination_arn = aws_cloudwatch_log_group.api_logs.arn
          }
        }
        '''
        groups = _log_groups(shared)
        destinations = _access_log_destinations(shared)
        self.assertEqual(destinations, ['api_logs'])
        self.assertIn(_EXECUTION_PREFIX, groups['api_logs'][0])

    def test_detector_catches_a_missing_retention(self):
        '''The other half of the detector, on a synthetic group.'''
        forever = '''
        resource "aws_cloudwatch_log_group" "somewhere" {
          name = "/cabal/apigateway/access/x"
        }
        '''
        self.assertEqual(_log_groups(forever)['somewhere'], ('/cabal/apigateway/access/x', None))


if __name__ == '__main__':
    unittest.main()
