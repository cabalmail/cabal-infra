'''Unit test for the alert_sink runbook map's agreement with the operator docs.

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_alert_sink_runbook_names.py

Kuma's webhook body carries no per-monitor runbook URL, so alert_sink resolves
one by looking the monitor name up in _RUNBOOK_MAP under a `kuma/` prefix. The
name is typed into the Kuma dashboard by an operator following the monitor
table in docs/monitoring.md section 10, and both that table and the map are
edited by hand. When they disagree the failure is silent: the push still goes
out, just without a runbook link, and nothing in CI or at runtime notices.

Renaming a monitor is exactly what happens when an endpoint moves -- issue
#779 moved the IMAP monitor off the removed `imap.<control-domain>:993`
listener onto `imap.cabal.internal:143` and renamed it to match. This test
pins the two sides together so the next such move cannot land half-done.

boto3 is faked in sys.modules so the handler imports without third-party deps.
'''
import os
import sys
import types
import unittest
import importlib.util

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(_TESTS_DIR))))
_ALERT_SINK = os.path.join(_REPO_ROOT, 'lambda', 'api', 'alert_sink', 'function.py')
_MONITORING_DOC = os.path.join(_REPO_ROOT, 'docs', 'monitoring.md')


def _load_alert_sink():
    '''Imports alert_sink/function.py under a unique module name.

    The repo has one `function.py` per handler directory, so a plain import
    name would collide with whichever handler another test loaded first.'''
    fake_boto3 = types.ModuleType('boto3')
    fake_boto3.client = lambda *a, **k: None
    sys.modules.setdefault('boto3', fake_boto3)
    # The handler reads its SSM parameter names and ntfy endpoint at import
    # time and raises KeyError if any is missing. None of them is exercised
    # here - only the module-scope runbook map is - so any value will do.
    for name in ('SHARED_SECRET_PARAM', 'PUSHOVER_USER_KEY_PARAM',
                 'PUSHOVER_APP_TOKEN_PARAM', 'NTFY_PUBLISHER_TOKEN_PARAM',
                 'NTFY_BASE_URL', 'NTFY_TOPIC'):
        os.environ.setdefault(name, 'test-value')
    spec = importlib.util.spec_from_file_location('alert_sink_function', _ALERT_SINK)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _documented_kuma_monitors():
    '''Returns [(monitor name, target)] from the docs' section-10 table.

    The table is the first Markdown table after the "## 10." heading; its
    first column is the monitor name the operator types into Kuma and its
    third is the endpoint that monitor probes. Backticks are stripped from
    the name: the docs render targets and paths as code spans, but what
    reaches alert_sink as `source` is the plain name.'''
    with open(_MONITORING_DOC, encoding='utf-8') as handle:
        lines = handle.read().splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith('## 10.'))
    rows = []
    seen_table = False
    for line in lines[start + 1:]:
        if line.startswith('## '):
            break
        if not line.startswith('|'):
            if seen_table:
                break
            continue
        seen_table = True
        cells = [c.strip() for c in line.strip('|').split('|')]
        name = cells[0].replace('`', '')
        if not name or set(name) <= set('- ') or name == 'Monitor':
            continue
        rows.append((name, cells[2] if len(cells) > 2 else ''))
    return rows


class RunbookMapMatchesDocsTest(unittest.TestCase):
    '''The `kuma/` keys and the documented monitor names are one list.'''

    def setUp(self):
        self.module = _load_alert_sink()
        self.mapped = {
            key[len('kuma/'):]
            for key in self.module._RUNBOOK_MAP  # pylint: disable=protected-access
            if key.startswith('kuma/')
        }
        self.rows = _documented_kuma_monitors()
        self.documented = {name for name, _ in self.rows}

    def test_docs_table_parsed(self):
        '''Guards the parser itself: an empty table would pass every other
        assertion here vacuously.'''
        self.assertGreaterEqual(len(self.documented), 5)

    def test_every_documented_monitor_has_a_runbook(self):
        '''A monitor the operator creates but the map does not know pushes
        without a runbook link.'''
        self.assertEqual(set(), self.documented - self.mapped)

    def test_every_mapped_monitor_is_documented(self):
        '''A map key with no monitor behind it is dead weight that reads as
        coverage.'''
        self.assertEqual(set(), self.mapped - self.documented)

    def test_imap_monitor_is_the_internal_starttls_endpoint(self):
        '''#779: the IMAP monitor must not point at the removed 993 listener.'''
        imap = [row for row in self.rows if 'IMAP' in row[0]]
        self.assertEqual(1, len(imap))
        self.assertIn('imap.cabal.internal:143', imap[0][1])
        self.assertNotIn(':993', imap[0][1])


class RunbookTargetsExistTest(unittest.TestCase):
    '''Every runbook the map points at is a file that exists.'''

    def test_runbooks_resolve_to_files(self):
        module = _load_alert_sink()
        base = module._RUNBOOK_BASE  # pylint: disable=protected-access
        for key, url in module._RUNBOOK_MAP.items():  # pylint: disable=protected-access
            self.assertTrue(url.startswith(base), key)
            path = os.path.join(
                _REPO_ROOT, 'docs', 'operations', 'runbooks', url[len(base):])
            self.assertTrue(os.path.isfile(path), f'{key} -> {url}')


if __name__ == '__main__':
    unittest.main()
