'''Unit test for operator runbooks prescribing network controls on ports the
mail tiers actually serve.

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_runbook_remediation_ports.py

The failure this pins is silent and only shows up mid-incident. Issue #1156:
the IMAPAuthFailureSpike runbook told the operator to allow 993 at a security
group and deny it at a NACL, months after #778 removed the NLB's IMAPS
listener and #779 switched the container's own off. Both commands were dead -
they operate on a port nothing reaches - so an operator following the runbook
during a real auth-failure spike would spend the incident on the wrong control
plane, with nothing in CI or at runtime to say otherwise.

The invariant: every TCP port named in a runbook's network-control command is
a port some mail tier's task definition actually publishes. That ties the docs
to the one place the answer is authoritative, so removing a listener fails here
until the runbooks that reference it are updated too.

No handler import and no third-party deps - this reads two files off disk.
'''
import os
import re
import unittest

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(_TESTS_DIR))))
_TASK_DEFS = os.path.join(_REPO_ROOT, 'terraform', 'infra', 'modules', 'ecs', 'task-definitions.tf')
_RUNBOOK_DIR = os.path.join(_REPO_ROOT, 'docs', 'operations', 'runbooks')

# `--port 993` / `--port-range From=993,To=993`: the two shapes the AWS CLI
# takes for a security-group rule and a NACL entry respectively, which are the
# network controls a runbook has any reason to prescribe.
_PORT_FLAG = re.compile(r'--port[ =](\d+)')
_PORT_RANGE = re.compile(r'From=(\d+),To=(\d+)')


def _served_ports():
    '''Returns the set of containerPorts across every tier's task definition.'''
    with open(_TASK_DEFS, encoding='utf-8') as handle:
        source = handle.read()
    return {int(p) for p in re.findall(r'containerPort\s*=\s*(\d+)', source)}


def _ports_named_in(text):
    '''Returns the set of TCP ports a chunk of Markdown prescribes acting on.'''
    named = {int(p) for p in _PORT_FLAG.findall(text)}
    for low, high in _PORT_RANGE.findall(text):
        named.update(range(int(low), int(high) + 1))
    return named


def _runbooks():
    '''Returns [(filename, contents)] for every runbook.'''
    names = sorted(n for n in os.listdir(_RUNBOOK_DIR) if n.endswith('.md'))
    out = []
    for name in names:
        with open(os.path.join(_RUNBOOK_DIR, name), encoding='utf-8') as handle:
            out.append((name, handle.read()))
    return out


class RunbookRemediationPortsTest(unittest.TestCase):
    '''The runbooks' network controls vs. the ports the tiers publish.'''

    def test_task_definitions_parsed(self):
        '''Floor: an unparsed task-definitions file would pass everything.'''
        served = _served_ports()
        self.assertIn(143, served, 'imap tier should publish 143')
        self.assertIn(25, served, 'mail tiers should publish 25')

    def test_runbooks_found(self):
        '''Floor: an empty runbook directory would pass everything.'''
        self.assertTrue(_runbooks(), 'no runbooks found under docs/operations/runbooks')

    def test_scanner_flags_a_retired_port(self):
        '''Floor: the scanner must actually catch the #1156 shape.

        Without this, a regex that matched nothing would make the real
        assertion below vacuous.'''
        dead = ('aws ec2 authorize-security-group-ingress --group-id sg-x '
                '--protocol tcp --port 993 --cidr 0.0.0.0/0\n'
                'aws ec2 create-network-acl-entry --network-acl-id acl-x '
                '--protocol tcp --port-range From=993,To=993 --rule-action deny')
        self.assertEqual({993}, _ports_named_in(dead) - _served_ports())

    def test_no_runbook_acts_on_an_unserved_port(self):
        '''The invariant itself.'''
        served = _served_ports()
        offenders = {}
        for name, text in _runbooks():
            dead = _ports_named_in(text) - served
            if dead:
                offenders[name] = sorted(dead)
        self.assertEqual({}, offenders,
                         'runbook(s) prescribe network controls on ports no tier '
                         'publishes: %s (served: %s)' % (offenders, sorted(served)))


if __name__ == '__main__':
    unittest.main()
