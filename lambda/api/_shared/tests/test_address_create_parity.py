'''Unit tests pinning the two address-create endpoints to one another: /new
(any user) and /new_address_admin (admin, on behalf of others).

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_address_create_parity.py

The two handlers reach an identical Route 53 UPSERT, and each used to reach it
through its own private copy of the change list and its own (or, in the admin
case, absent) input guards. The copies drifted: the admin path published four
of the five canonical records, omitting BIMI (#1073), and never carried the
reserved-control-subdomain check at all (#1072). Both now go through
helper.publish_address_dns_records and helper.new_address_response_or_none (the
reserved check among them), so the cases below assert the two handlers agree --
against the canonical record set rather than a hand-copied list, so a sixth
record added to address_dns_records() cannot pass while only one handler
publishes it.

The guard is scoped by label, not applied wholesale: the collision-driven
labels stay control-domain-only (a mail-domain zone carries none of the records
they would hit), while `mail-admin` -- the label dmarc_user.tf provisions the
system sender on, on the first *mail* domain -- is refused on every domain
(#1097). The last two classes pin both halves of that split.
'''
import importlib.util
import json
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'control.example.com')
os.environ.setdefault('DOMAINS', json.dumps({
    'control.example.com': 'ZCONTROL',
    'mail.example.net': 'ZMAIL',
}))
os.environ.setdefault('USER_POOL_ID', 'us-east-1_test')
# Loading the handlers below imports address_events, which reads this once at
# module load. Under a directory-wide `discover` run this file sorts first, so
# without it the value test_notify_containers pins would be the empty string by
# the time that suite ran (#860). Same value it sets, so either order agrees.
os.environ.setdefault('ADDRESS_CHANGED_TOPIC_ARN',
                      'arn:aws:sns:us-east-1:1:address-changed')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

# --- fake boto3 / botocore ---------------------------------------------------


# Identical to the fake in the sibling suites on purpose; setdefault means
# whichever suite `unittest discover` reaches first owns the module (#860).
class _FakeSSMExceptions:
    class ParameterNotFound(Exception):
        pass


class _FakeSSM:
    exceptions = _FakeSSMExceptions

    def get_parameter(self, Name=None, **_kwargs):  # pylint: disable=invalid-name
        if Name == '/cabal/maintenance/imap':
            raise _FakeSSMExceptions.ParameterNotFound()
        return {"Parameter": {"Value": "fake-master-password"}}


class _FakeResource:
    def Table(self, _name):  # pylint: disable=invalid-name
        return types.SimpleNamespace()


_boto3 = types.ModuleType("boto3")
_boto3.resource = lambda _name, **_kw: _FakeResource()
_boto3.client = lambda name, **_kw: _FakeSSM() if name == 'ssm' else types.SimpleNamespace()
_boto3.session = types.SimpleNamespace(Config=lambda **_kw: None)
sys.modules.setdefault('boto3', _boto3)

_botocore = types.ModuleType("botocore")
_botocore_exceptions = types.ModuleType("botocore.exceptions")


class _ClientError(Exception):
    pass


_botocore_exceptions.ClientError = _ClientError
_botocore.exceptions = _botocore_exceptions
sys.modules.setdefault('botocore', _botocore)
sys.modules.setdefault('botocore.exceptions', _botocore_exceptions)

_imap_session = types.ModuleType("imap_session")
_imap_session.open_imap_client = lambda *_a, **_kw: None
sys.modules.setdefault('imap_session', _imap_session)

import helper  # noqa: E402  pylint: disable=wrong-import-position


def _load_handler(name):
    '''Loads lambda/api/<name>/function.py under a unique module name.

    Every deployed zip names its handler module `function`, so a plain
    `import function` lets whichever suite runs first win the `sys.modules`
    slot and hands every later suite the wrong handler (#860).
    '''
    path = os.path.join(os.path.dirname(_SHARED), name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'function_{name}', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


new = _load_handler('new')
new_admin = _load_handler('new_address_admin')


class _FakeRoute53:
    '''Records the change batches a handler submits, and answers the zone-owns-
    apex probe truthfully for the two zones in DOMAINS.'''

    ZONES = {'ZCONTROL': 'control.example.com.', 'ZMAIL': 'mail.example.net.'}

    def __init__(self):
        self.batches = []

    def get_hosted_zone(self, Id=None, **_kwargs):  # pylint: disable=invalid-name
        return {'HostedZone': {'Name': self.ZONES[Id]}}

    def change_resource_record_sets(self, HostedZoneId=None, ChangeBatch=None, **_kw):  # pylint: disable=invalid-name
        self.batches.append((HostedZoneId, ChangeBatch))
        return {}

    def upserts(self):
        '''The submitted records as (name, type, value) triples, matching the
        shape of helper.address_dns_records().'''
        return {
            (c['ResourceRecordSet']['Name'],
             c['ResourceRecordSet']['Type'],
             c['ResourceRecordSet']['ResourceRecords'][0]['Value'])
            for _zone, batch in self.batches
            for c in batch['Changes']
            if c['Action'] == 'UPSERT'
        }


class _FakeTable:
    '''Stands in for the cabal-addresses Table, recording writes.'''

    def __init__(self):
        self.items = []

    def put_item(self, Item=None, **_kwargs):  # pylint: disable=invalid-name
        self.items.append(Item)


def _event(subdomain, tld, user='alice', usernames=('alice',)):
    '''An API Gateway proxy event for either create endpoint. The admin arm
    reads `usernames`; the user arm ignores it.'''
    return {
        'requestContext': {'authorizer': {'claims': {
            'cognito:username': user,
            'cognito:groups': 'admin',
        }}},
        'body': json.dumps({
            'username': 'someone',
            'subdomain': subdomain,
            'tld': tld,
            'usernames': list(usernames),
        })
    }


class _CreateCase(unittest.TestCase):
    '''Binds the fakes into both handlers.

    Rebinding on the handler module (not on `helper`) is what the sibling
    suites do: the handlers import their helpers by name at module load, so a
    later patch of `helper.x` would not be seen (#913). The Route 53 client is
    the exception -- publish_address_dns_records calls helper._route53() per
    invocation, so the fake goes in helper's cached client slot.'''

    def setUp(self):
        self.r53 = _FakeRoute53()
        self.table = _FakeTable()
        self.admin_table = _FakeTable()
        self._saved_r53 = helper._R53_CLIENT  # pylint: disable=protected-access
        helper._R53_CLIENT = self.r53  # pylint: disable=protected-access
        self._saved = {}
        for module, attrs in (
            (new, {
                'table': self.table,
                'notify_containers': lambda: None,
                'user_authorized_for_domain': lambda *_a: True,
            }),
            (new_admin, {
                'table': self.admin_table,
                'notify_containers': lambda: None,
                'user_authorized_for_domain': lambda *_a: True,
                'cognito_user_exists': lambda _u: True,
                'admin_response_or_none': lambda _e: None,
                'rate_limit_response_or_none': lambda *_a: None,
                'audit_log': lambda *_a: None,
            }),
        ):
            for attr, value in attrs.items():
                self._saved[(module, attr)] = getattr(module, attr)
                setattr(module, attr, value)

    def tearDown(self):
        helper._R53_CLIENT = self._saved_r53  # pylint: disable=protected-access
        for (module, attr), value in self._saved.items():
            setattr(module, attr, value)


class CanonicalRecordSetTests(_CreateCase):
    '''Both create paths publish exactly helper.address_dns_records() (#1073).'''

    def _expected(self, subdomain, tld):
        return set(helper.address_dns_records(subdomain, tld, 'control.example.com'))

    def test_new_publishes_the_canonical_set(self):
        response = new.handler(_event('sales', 'mail.example.net'), None)
        self.assertEqual(response['statusCode'], 201)
        self.assertEqual(self.r53.upserts(), self._expected('sales', 'mail.example.net'))

    def test_admin_publishes_the_canonical_set(self):
        response = new_admin.handler(_event('sales', 'mail.example.net'), None)
        self.assertEqual(response['statusCode'], 201)
        self.assertEqual(self.r53.upserts(), self._expected('sales', 'mail.example.net'))

    def test_admin_publishes_the_bimi_record(self):
        '''The one record the admin copy of the change list had omitted, called
        out on its own so a regression names itself.'''
        new_admin.handler(_event('sales', 'mail.example.net'), None)
        names = {name for name, _type, _value in self.r53.upserts()}
        self.assertIn('default._bimi.sales.mail.example.net', names)

    def test_the_two_handlers_publish_the_same_records(self):
        new.handler(_event('sales', 'mail.example.net'), None)
        user_arm = self.r53.upserts()
        self.r53.batches.clear()
        new_admin.handler(_event('sales', 'mail.example.net'), None)
        self.assertEqual(self.r53.upserts(), user_arm)


class ReservedSubdomainTests(_CreateCase):
    '''Both create paths refuse the reserved control-domain labels (#1072).'''

    def test_new_rejects_a_reserved_control_subdomain(self):
        response = new.handler(_event('mail-admin', 'control.example.com'), None)
        self.assertEqual(response['statusCode'], 400)
        self.assertIn('reserved', json.loads(response['body'])['Error'])

    def test_admin_rejects_a_reserved_control_subdomain(self):
        response = new_admin.handler(_event('mail-admin', 'control.example.com'), None)
        self.assertEqual(response['statusCode'], 400)
        self.assertIn('reserved', json.loads(response['body'])['Error'])

    def test_admin_rejection_writes_nothing(self):
        '''The guard runs before create_dns_records, so a refusal leaves neither
        an rrset nor a DynamoDB row behind.'''
        new_admin.handler(_event('imap', 'control.example.com'), None)
        self.assertEqual(self.r53.batches, [])
        self.assertEqual(self.admin_table.items, [])

    def test_admin_rejects_every_reachable_reserved_label(self):
        '''_DNS_LABEL_RE already refuses the two underscore labels, so the
        reachable set is the other seven; sweep them rather than one example.'''
        reachable = sorted(
            label for label in helper.RESERVED_CONTROL_SUBDOMAINS
            if '_' not in label
        )
        self.assertEqual(len(reachable), 7)
        for label in reachable:
            with self.subTest(label=label):
                response = new_admin.handler(
                    _event(label, 'control.example.com'), None)
                self.assertEqual(response['statusCode'], 400)

    def test_guard_is_case_and_trailing_dot_insensitive(self):
        response = new_admin.handler(_event('MAIL-ADMIN.', 'control.example.com'), None)
        self.assertEqual(response['statusCode'], 400)

    def test_collision_label_on_a_mail_domain_is_still_accepted(self):
        '''Pins what #1097 deliberately left alone. The rest of the reserved
        set is there because those labels collide with control-zone records
        (CloudFront/NLB aliases, the DKIM/DMARC selectors); a mail-domain zone
        carries none of them, so `smtp-out.<mail domain>` is accepted exactly
        as it was before. Only `mail-admin` widened -- see the case below.'''
        for handler in (new.handler, new_admin.handler):
            with self.subTest(handler=handler.__module__):
                self.r53.batches.clear()
                response = handler(_event('smtp-out', 'mail.example.net'), None)
                self.assertEqual(response['statusCode'], 201)


class SystemSenderSubdomainTests(_CreateCase):
    '''`mail-admin` is refused on EVERY domain, not just the control one
    (#1097): it is the label dmarc_user.tf provisions the system sender on, on
    domains[0] -- a mail domain. An address there sends mail that DKIM-signs
    and SPF-aligns as the system sender.'''

    def test_new_rejects_mail_admin_on_a_mail_domain(self):
        response = new.handler(_event('mail-admin', 'mail.example.net'), None)
        self.assertEqual(response['statusCode'], 400)
        self.assertIn('every mail domain', json.loads(response['body'])['Error'])

    def test_admin_rejects_mail_admin_on_a_mail_domain(self):
        response = new_admin.handler(_event('mail-admin', 'mail.example.net'), None)
        self.assertEqual(response['statusCode'], 400)
        self.assertIn('every mail domain', json.loads(response['body'])['Error'])

    def test_rejection_on_a_mail_domain_writes_nothing(self):
        '''Same shape as the control-domain refusal: the guard runs before
        publish_address_dns_records, so neither an rrset nor a row is left.'''
        for handler, table in ((new.handler, self.table),
                               (new_admin.handler, self.admin_table)):
            with self.subTest(handler=handler.__module__):
                handler(_event('mail-admin', 'mail.example.net'), None)
                self.assertEqual(self.r53.batches, [])
                self.assertEqual(table.items, [])

    def test_mail_admin_is_refused_on_every_configured_domain(self):
        '''Sweep the real DOMAINS map rather than one example: the guard must
        not depend on which entry is domains[0], because reordering
        TF_VAR_MAIL_DOMAINS moves the system sender.'''
        for tld in json.loads(os.environ['DOMAINS']):
            with self.subTest(tld=tld):
                response = new.handler(_event('mail-admin', tld), None)
                self.assertEqual(response['statusCode'], 400)

    def test_guard_is_case_and_trailing_dot_insensitive_off_control(self):
        response = new_admin.handler(_event('MAIL-ADMIN.', 'mail.example.net'), None)
        self.assertEqual(response['statusCode'], 400)


class SharedInputVettingTests(_CreateCase):
    '''helper.new_address_response_or_none is the one copy of the checks that
    run before either handler's own authorization: known domain, valid DNS
    labels, valid local part, subdomain not reserved.'''

    DOMAINS = {'control.example.com': 'ZCONTROL', 'mail.example.net': 'ZMAIL'}

    def _vet(self, subdomain='sales', tld='mail.example.net', username='someone'):
        return helper.new_address_response_or_none(
            {'username': username, 'subdomain': subdomain, 'tld': tld},
            self.DOMAINS, 'control.example.com')

    def test_a_clean_request_is_not_refused(self):
        self.assertIsNone(self._vet())

    def test_an_unknown_domain_is_refused(self):
        refusal = self._vet(tld='nope.example.org')
        self.assertEqual(refusal['statusCode'], 400)
        self.assertIn('Unknown domain', json.loads(refusal['body'])['Error'])

    def test_an_invalid_local_part_is_refused(self):
        refusal = self._vet(username='has space')
        self.assertEqual(refusal['statusCode'], 400)
        self.assertIn('Invalid input', json.loads(refusal['body'])['Error'])

    def test_an_invalid_subdomain_is_refused(self):
        refusal = self._vet(subdomain='')
        self.assertEqual(refusal['statusCode'], 400)
        self.assertIn('Invalid input', json.loads(refusal['body'])['Error'])

    def test_a_reserved_subdomain_is_refused(self):
        refusal = self._vet(subdomain='mail-admin')
        self.assertEqual(refusal['statusCode'], 400)
        self.assertIn('reserved', json.loads(refusal['body'])['Error'])

    def test_the_unknown_domain_check_runs_before_the_validators(self):
        '''A malformed label on an unknown domain reports the domain, not the
        label: the order the two 400s are produced in is observable.'''
        refusal = self._vet(subdomain='', tld='nope.example.org')
        self.assertIn('Unknown domain', json.loads(refusal['body'])['Error'])

    def test_the_validators_run_before_the_reserved_guard(self):
        '''`mail-admin` with a bad local part reports the local part. The
        reserved guard reads a label the validators have already accepted.'''
        refusal = self._vet(subdomain='mail-admin', username='has space')
        self.assertIn('Invalid input', json.loads(refusal['body'])['Error'])

    def test_both_handlers_refuse_identically(self):
        '''The point of the shared copy: byte-identical refusals from the two
        endpoints, so neither can drift the way the admin path did (#1072).'''
        for subdomain, tld, username in (
            ('sales', 'nope.example.org', 'someone'),
            ('', 'mail.example.net', 'someone'),
            ('sales', 'mail.example.net', 'has space'),
            ('mail-admin', 'mail.example.net', 'someone'),
            ('imap', 'control.example.com', 'someone'),
        ):
            with self.subTest(subdomain=subdomain, tld=tld, username=username):
                event = _event(subdomain, tld)
                event['body'] = json.dumps(
                    dict(json.loads(event['body']), username=username))
                self.assertEqual(new.handler(event, None),
                                 new_admin.handler(event, None))


if __name__ == '__main__':
    unittest.main()
