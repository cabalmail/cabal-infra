'''Unit test for every API Gateway method-settings override declaring the
observability policy rather than inheriting it.

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_api_gateway_method_overrides.py

The failure this pins is invisible to a plan and to a casual read of the
config. Issue #1223: API Gateway resolves method settings by longest match,
not by merge, so a per-method entry REPLACES the `*/*` defaults for that
method instead of inheriting the fields it leaves out. `cache_settings` set
only the two caching fields for all 51 methods, so the `*/*` entry stayed
correctly at `ERROR`/no-trace while the overrides that actually decide each
method carried whatever had been written there before - measured in stage,
35 of 51 running `loggingLevel INFO` with `dataTraceEnabled true`, writing
envelope metadata into a 365-day log group, and the four entries the resource
had genuinely written carrying no `loggingLevel` at all and `metricsEnabled`
false.

The invariant: every `settings` block in a `aws_api_gateway_method_settings`
resource sets `metrics_enabled`, `data_trace_enabled` and `logging_level`,
and sets all three from `local.method_observability` - so the shared policy
cannot drift between the default entry and the per-method ones, and a new
resource that forgets them fails here rather than silently opting a method
out of it.

No handler import and no third-party deps - this reads two files off disk.
'''
import os
import re
import unittest

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(_TESTS_DIR))))
_APP_MODULE = os.path.join(_REPO_ROOT, 'terraform', 'infra', 'modules', 'app')
_MAIN_TF = os.path.join(_APP_MODULE, 'main.tf')
_LOCALS_TF = os.path.join(_APP_MODULE, 'locals.tf')

# The fields a per-method entry has to restate, and the value each one has to
# carry. These are the security-relevant half of the policy: metrics off is a
# monitoring hole, and INFO/data-trace is what put mail metadata in the log.
_REQUIRED = {
    'metrics_enabled': 'true',
    'data_trace_enabled': 'false',
    'logging_level': '"ERROR"',
}

_RESOURCE = re.compile(
    r'resource\s+"aws_api_gateway_method_settings"\s+"([^"]+)"\s*\{', re.MULTILINE
)


def _read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def _brace_block(source, open_index):
    '''Returns the text between the brace at `open_index` and its match.'''
    depth = 0
    for i in range(open_index, len(source)):
        if source[i] == '{':
            depth += 1
        elif source[i] == '}':
            depth -= 1
            if depth == 0:
                return source[open_index + 1:i]
    raise AssertionError('unbalanced braces from index %d' % open_index)


def _method_settings_resources():
    '''Returns {resource name: its `settings` block body}.'''
    source = _read(_MAIN_TF)
    found = {}
    for match in _RESOURCE.finditer(source):
        body = _brace_block(source, match.end() - 1)
        settings_at = body.index('settings {')
        found[match.group(1)] = _brace_block(body, settings_at + len('settings '))
    return found


def _method_observability():
    '''Returns {attribute: literal} from the shared `method_observability` local.'''
    source = _read(_LOCALS_TF)
    start = source.index('method_observability = {')
    body = _brace_block(source, start + len('method_observability = '))
    return dict(re.findall(r'^\s*(\w+)\s*=\s*(.+?)\s*$', body, re.MULTILINE))


class MethodSettingOverrideTests(unittest.TestCase):
    '''#1223: an override that omits a field does not inherit it.'''

    def test_resources_parsed(self):
        '''Floor: an empty parse would make every other assertion vacuous.'''
        resources = _method_settings_resources()
        self.assertGreaterEqual(len(resources), 2, resources)
        self.assertIn('general_settings', resources)
        self.assertIn('cache_settings', resources)

    def test_shared_local_carries_the_safe_values(self):
        '''The policy itself, in the one place both resources read it from.'''
        policy = _method_observability()
        for field, expected in _REQUIRED.items():
            self.assertIn(field, policy, 'local.method_observability lacks %s' % field)
            self.assertEqual(policy[field], expected, field)

    def test_every_resource_restates_the_whole_policy(self):
        '''The invariant. A per-method entry replaces `*/*` rather than
        merging with it, so each one has to set all three itself.'''
        for name, settings in _method_settings_resources().items():
            for field in _REQUIRED:
                self.assertRegex(
                    settings,
                    r'\b%s\s*=' % field,
                    '%s does not set %s, so its methods fall back to API '
                    'Gateway defaults rather than the `*/*` entry' % (name, field),
                )

    def test_every_resource_reads_the_shared_local(self):
        '''Setting the field is not enough: a literal here would drift away
        from the default entry silently, which is the shape of the defect.'''
        for name, settings in _method_settings_resources().items():
            for field in _REQUIRED:
                self.assertRegex(
                    settings,
                    r'\b%s\s*=\s*local\.method_observability\.%s\b' % (field, field),
                    '%s sets %s from something other than the shared local' % (name, field),
                )

    def test_detector_catches_an_omitted_field(self):
        '''Self-test on a synthetic block, so a future rewrite of the parser
        cannot make the assertions above pass by finding nothing.'''
        block = '''
    caching_enabled      = each.value.cache
    cache_ttl_in_seconds = each.value.cache_ttl
    metrics_enabled      = local.method_observability.metrics_enabled
'''
        self.assertNotRegex(block, r'\bdata_trace_enabled\s*=')
        self.assertRegex(block, r'\bmetrics_enabled\s*=\s*local\.method_observability\.')

    def test_detector_catches_an_inlined_literal(self):
        '''The other half of the self-test: present but not from the local.'''
        block = '    data_trace_enabled = false\n'
        self.assertRegex(block, r'\bdata_trace_enabled\s*=')
        self.assertNotRegex(
            block, r'\bdata_trace_enabled\s*=\s*local\.method_observability\.'
        )


if __name__ == '__main__':
    unittest.main()
