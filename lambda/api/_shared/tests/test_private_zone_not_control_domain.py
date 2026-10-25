'''Unit test for the VPC holding no Route 53 private zone named for the whole
control domain.

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_private_zone_not_control_domain.py

Issue #2064: `modules/vpc/zone.tf` created a private hosted zone with
`name = var.control_domain`, which makes it authoritative inside the VPC for
every name below the control domain. It held ten record sets and nothing else,
so every other name under the control domain was NXDOMAIN in the VPC -
including each address subdomain's own MX/TXT/DKIM/DMARC/BIMI set, which the
`new` handler publishes into the public zone only
(`_shared/helper.py:address_dns_records`). sendmail's `check_mail` rule does an
MX-then-A lookup on the envelope sender, so `smtp-in` answered
`553 5.1.8 ... Domain of sender address ... does not exist` for every inbound
message whose sender was an address under the control domain, and OpenDKIM and
OpenDMARC evaluated those senders against no key and no policy. #1411 is the
same shadow seen one name higher up, and the three mail-authentication mirrors
it added to that zone were a workaround for it.

The invariant: a private hosted zone may not be named for the control domain
itself. A private zone named for one *specific* internal name
(`imap.<control-domain>`) is legitimate and stays legitimate - it shadows only
that name - so this scan distinguishes the two rather than banning private
zones. The second half is that the `private_zone_id` plumbing is gone: it
existed only to carry record sets into the broad zone, and a reintroduced
variable is how the broad zone would come back.

Neither half is visible in a plan: re-adding the zone plans as a clean create
and the breakage is a DNS answer inside the VPC, which no Terraform output
reports.

No handler import and no third-party deps - this reads Terraform sources off
disk.
'''
import os
import re
import unittest

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(_TESTS_DIR))))
_INFRA = os.path.join(_REPO_ROOT, 'terraform', 'infra')

_ZONE_BLOCK = re.compile(r'resource\s+"aws_route53_zone"\s+"([^"]+)"\s*\{', re.MULTILINE)
_NAME_ARG = re.compile(r'^\s*name\s*=\s*(.+?)\s*$', re.MULTILINE)
_VPC_BLOCK = re.compile(r'^\s*vpc\s*\{', re.MULTILINE)

# The spellings that name a zone for the control domain and nothing narrower.
# A name with anything in front of the interpolation (`"imap.${...}"`) is a
# narrower zone and is deliberately not matched.
_WHOLE_CONTROL_DOMAIN = (
    'var.control_domain',
    'local.control_domain',
    '"${var.control_domain}"',
    '"${local.control_domain}"',
    '"${var.control_domain}."',
)


def _tf_sources(root):
    '''Every .tf file under `root`, skipping provider caches.'''
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != '.terraform']
        for filename in sorted(filenames):
            if filename.endswith('.tf'):
                yield os.path.join(dirpath, filename)


def _brace_span(text, open_index):
    '''Return the source of the block whose opening brace is at `open_index`.'''
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[open_index:i + 1]
    raise AssertionError('unbalanced braces from offset %d' % open_index)


def broad_private_zones(text):
    '''Names of private `aws_route53_zone` blocks named for the control domain.

    The detector, factored out so the tests can run it over fixture text as
    well as over the tree.
    '''
    found = []
    for match in _ZONE_BLOCK.finditer(text):
        block = _brace_span(text, match.end() - 1)
        if not _VPC_BLOCK.search(block):
            continue  # a public zone shadows nothing
        for name in _NAME_ARG.findall(block):
            if name in _WHOLE_CONTROL_DOMAIN:
                found.append(match.group(1))
    return found


class PrivateZoneIsNotTheControlDomain(unittest.TestCase):
    '''#2064: no private zone may cover the whole control domain.'''

    def test_no_private_zone_is_named_for_the_control_domain(self):
        offenders = []
        for path in _tf_sources(_INFRA):
            with open(path, encoding='utf-8') as handle:
                for resource in broad_private_zones(handle.read()):
                    offenders.append('%s: aws_route53_zone.%s' % (
                        os.path.relpath(path, _REPO_ROOT), resource))
        self.assertEqual(offenders, [], (
            'A private hosted zone named for the control domain is '
            'authoritative inside the VPC for every address subdomain under '
            'it, which 553-rejects those addresses as envelope senders '
            '(#2064). Name the zone for the one internal name that needs a '
            'private answer instead: %s' % offenders))

    def test_detector_fires_on_a_reintroduced_broad_zone(self):
        '''Negative control: the shape #2064 removed is still detected.'''
        reintroduced = '''
resource "aws_route53_zone" "private_dns" {
  name    = var.control_domain
  comment = "Internal control domain"
  vpc {
    vpc_id = aws_vpc.network.id
  }
}
'''
        self.assertEqual(broad_private_zones(reintroduced), ['private_dns'])

    def test_detector_allows_a_narrow_private_zone(self):
        '''A zone named for one internal name shadows only that name.

        The private-IMAP plan (docs/1.x/private-imap-smtp-plan.md) may want
        exactly this when it deletes the public `imap` record, so the scan must
        not read it as the defect.
        '''
        narrow = '''
resource "aws_route53_zone" "imap_private" {
  name = "imap.${var.control_domain}"
  vpc {
    vpc_id = var.vpc_id
  }
}
'''
        self.assertEqual(broad_private_zones(narrow), [])

    def test_detector_ignores_a_public_zone_for_the_control_domain(self):
        '''The public zone is named for the control domain by design.'''
        public = '''
resource "aws_route53_zone" "control" {
  name = var.control_domain
}
'''
        self.assertEqual(broad_private_zones(public), [])

    def test_no_module_takes_a_private_zone_id(self):
        '''The plumbing that fed the broad zone its record sets is gone.

        Every `private_zone_id` consumer existed to publish a second, identical
        copy of a public record into the shadowing zone. A reintroduced
        variable is the tell that the mirrors - and the zone - are back.
        '''
        references = []
        for path in _tf_sources(_INFRA):
            with open(path, encoding='utf-8') as handle:
                for number, line in enumerate(handle, start=1):
                    if 'private_zone_id' in line:
                        references.append('%s:%d' % (
                            os.path.relpath(path, _REPO_ROOT), number))
        self.assertEqual(references, [], (
            'private_zone_id is the broad zone\'s plumbing (#2064): %s'
            % references))


if __name__ == '__main__':
    unittest.main()
