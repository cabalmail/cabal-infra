'''Unit test pinning every Terraform-declared Cognito user to the MFA
gate's exemption list.

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_mfa_exempt_service_users.py

Issue #1739: `ci_probe_user.tf` (modules/app) minted the `ci-probe`
service account, and `EXEMPT_USERS` (modules/user_pool) -- the list
`require_admin_mfa/function.py` reads to decide who the MFA gate does not
apply to -- was never updated. Because a factorless non-admin user takes
the `user` gate, which carries a 48-hour grace window from account
creation, the probe signed in normally for two days: the apply that
created it, its first green run, and a day of deploys all looked fine.
Then the window closed and every post-deploy mail probe in both
environments failed at sign-in with "This account requires multi-factor
authentication", on stage and prod alike.

The invariant: every `aws_cognito_user` Terraform declares is a machine
account that authenticates with a password and can never enroll an
authenticator, so each one's username appears in `EXEMPT_USERS`. The
reverse direction is checked too -- an exempt name that matches no
declared user is a typo that silently exempts nobody -- with an
allowlist for names deliberately created outside Terraform.

The two halves live in different modules, which is exactly what let the
omission through review, and neither a plan nor any of the IaC scanners
can see the relationship: both files are individually valid.

No handler import and no third-party deps - this reads the .tf files off
disk.
'''
import os
import re
import unittest

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(_TESTS_DIR))))
_TERRAFORM = os.path.join(_REPO_ROOT, 'terraform')
_GATE_TF = os.path.join(
    _TERRAFORM, 'infra', 'modules', 'user_pool', 'require_admin_mfa.tf'
)

_COGNITO_USER = re.compile(
    r'resource\s+"aws_cognito_user"\s+"([^"]+)"\s*\{', re.MULTILINE
)
_USERNAME = re.compile(r'username\s*=\s*"([^"]*)"')
_EXEMPT = re.compile(r'EXEMPT_USERS\s*=\s*"([^"]*)"')

# Escape hatch for a declared user that is a human and therefore expected
# to enroll: an `# mfa-gate: human <why>` comment inside its resource
# block. None exists today -- every Cognito user in the tree is a machine
# account -- but the gate's own design admits the case, and without the
# hatch this test would force a human account onto the exemption list.
_HUMAN_ANNOTATION = re.compile(r'mfa-gate:\s*human\b(.*)')

# The inventory, asserted rather than merely iterated: a new user file
# that this test cannot see would otherwise be silently exempt from it.
_EXPECTED_USERS = {
    'master': 'terraform/infra/modules/app/master_user.tf',
    'dmarc': 'terraform/infra/modules/app/dmarc_user.tf',
    'ci-probe': 'terraform/infra/modules/app/ci_probe_user.tf',
}

# Exempt names with no Terraform-declared user behind them. Each entry
# gives its reason in prose; an entry here is a claim that the account is
# created by hand, which is the only thing that distinguishes it from a
# typo. Empty today: the App Store review demo account the gate's comment
# contemplates is deleted, and re-adding one would put a line here.
_EXEMPT_WITHOUT_RESOURCE = {}

# Floors. Below these the scan has stopped seeing the tree and every
# assertion under it passes vacuously.
_MIN_TF_FILES = 40


def _read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def _strip_comments(source):
    '''Removes `#` and `//` comments, leaving string literals intact.

    Needed in both directions: `require_admin_mfa.tf` names `ci-probe` in
    prose above the assignment, and a commented-out resource block would
    otherwise read as a declared user.
    '''
    out = []
    i = 0
    in_string = False
    while i < len(source):
        char = source[i]
        if in_string:
            out.append(char)
            if char == '\\' and i + 1 < len(source):
                out.append(source[i + 1])
                i += 2
                continue
            if char == '"':
                in_string = False
            i += 1
            continue
        if char == '"':
            in_string = True
            out.append(char)
            i += 1
            continue
        if char == '#' or source[i:i + 2] == '//':
            while i < len(source) and source[i] != '\n':
                i += 1
            continue
        out.append(char)
        i += 1
    return ''.join(out)


def _brace_block(source, open_index):
    '''Returns the text between the brace at `open_index` and its match.

    Walked by depth, not `[^}]*`: a `${...}` interpolation inside an
    attribute closes the block early, and a truncated body reads as a
    resource with no username - a pass on the assertion that matters.
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


def _cognito_users(source):
    '''Maps each declared username to its human annotation, or None.

    The block is located in the raw source so the annotation comment
    survives; the username is read off the comment-stripped body.
    '''
    found = {}
    for match in _COGNITO_USER.finditer(source):
        body = _brace_block(source, match.end() - 1)
        username = _USERNAME.search(_strip_comments(body))
        if username is None:
            raise AssertionError(
                'aws_cognito_user.%s declares no literal username' % match.group(1)
            )
        annotation = _HUMAN_ANNOTATION.search(body)
        found[username.group(1)] = annotation.group(1).strip() if annotation else None
    return found


def _tf_files():
    paths = []
    for root, _, names in os.walk(_TERRAFORM):
        for name in sorted(names):
            if name.endswith('.tf'):
                paths.append(os.path.join(root, name))
    return sorted(paths)


def _exempt_users(source):
    values = _EXEMPT.findall(_strip_comments(source))
    if len(values) != 1:
        raise AssertionError('expected one EXEMPT_USERS assignment, found %d' % len(values))
    return [name.strip() for name in values[0].split(',') if name.strip()]


class MfaExemptServiceUserTests(unittest.TestCase):
    '''Pins the Cognito users Terraform declares to the MFA exemption list.'''

    def setUp(self):
        self.tf_files = _tf_files()
        self.declared = {}
        for path in self.tf_files:
            for username, annotation in _cognito_users(_read(path)).items():
                self.declared[username] = (
                    os.path.relpath(path, _REPO_ROOT), annotation
                )
        self.exempt = _exempt_users(_read(_GATE_TF))

    def test_the_tree_is_parsed(self):
        '''A floor: an empty walk would pass every assertion below.'''
        self.assertGreaterEqual(
            len(self.tf_files), _MIN_TF_FILES,
            'the .tf walk found too few files to be reading the tree'
        )
        self.assertGreaterEqual(len(self.exempt), 2, 'EXEMPT_USERS parsed as empty')

    def test_the_declared_user_inventory(self):
        '''Asserted, not iterated: a user added in a file this test does not
        expect is a change to the surface the gate has to cover, and it should
        be read by a human rather than picked up silently.'''
        self.assertEqual(
            {name: path for name, (path, _) in self.declared.items()},
            _EXPECTED_USERS
        )

    def test_every_declared_user_is_exempt_or_annotated_human(self):
        '''The defect. A password-authenticating Cognito user missing from
        EXEMPT_USERS signs in for GRACE_HOURS and is blocked forever after
        (#1739) - and nothing in a plan, in tflint, or in Checkov can see it,
        because the user and the list are valid on their own.'''
        offenders = sorted(
            '%s (%s)' % (name, path)
            for name, (path, annotation) in self.declared.items()
            if name not in self.exempt and annotation is None
        )
        self.assertEqual(
            offenders, [],
            'these Terraform-declared Cognito users are neither in EXEMPT_USERS nor '
            'annotated as human, so the MFA gate will block them once their grace '
            'window closes: %s' % ', '.join(offenders)
        )

    def test_every_exempt_name_matches_a_declared_user(self):
        '''The other direction. A misspelled entry exempts nobody and fails the
        same way, 48 hours later - and reads as done in review.'''
        unmatched = sorted(
            name for name in self.exempt
            if name not in self.declared and name not in _EXEMPT_WITHOUT_RESOURCE
        )
        self.assertEqual(
            unmatched, [],
            'these EXEMPT_USERS entries match no aws_cognito_user in the tree; a '
            'typo exempts nobody: %s' % ', '.join(unmatched)
        )

    def test_the_probe_user_is_exempt(self):
        '''Named outright, because this is the account #1739 was about and the
        one that signs in on every mail-tier and API deploy.'''
        self.assertIn('ci-probe', self.exempt)

    def test_detector_catches_the_pre_fix_state(self):
        '''The detector self-test: the shape this suite exists to reject must
        be caught, so a later rewrite cannot make it vacuous.'''
        source = '''
        resource "aws_cognito_user" "ci_probe" {
          user_pool_id = var.user_pool_id
          username     = "ci-probe"
          attributes = {
            osid = 9997
          }
        }
        '''
        declared = _cognito_users(source)
        self.assertEqual(declared, {'ci-probe': None})
        self.assertNotIn('ci-probe', _exempt_users('EXEMPT_USERS = "master,dmarc"'))

    def test_detector_reads_past_an_interpolated_brace(self):
        '''A body matched with `[^}]*` ends at the brace inside `${...}` and
        yields a resource with no username, which reads as a pass.'''
        source = '''
        resource "aws_cognito_user" "dmarc" {
          user_pool_id = var.user_pool_id
          attributes = {
            email = "dmarc@mail-admin.${var.domains[0].domain}"
          }
          username = "dmarc"
        }
        '''
        self.assertEqual(_cognito_users(source), {'dmarc': None})

    def test_detector_honours_the_human_annotation(self):
        '''The escape hatch, with its reason captured so an unexplained
        annotation is visible in the assertion message.'''
        source = '''
        resource "aws_cognito_user" "operator" {
          # mfa-gate: human - enrolls via the Security page like any signup
          username = "operator"
        }
        '''
        self.assertEqual(
            _cognito_users(source),
            {'operator': '- enrolls via the Security page like any signup'}
        )

    def test_detector_ignores_commented_out_declarations(self):
        '''A commented-out block is not a declared user, and prose naming a
        user is not an exemption.'''
        source = '''
        # resource "aws_cognito_user" "old_demo" {
        #   username = "apple"
        # }
        resource "aws_cognito_user" "master" {
          username = "master"
        }
        '''
        self.assertEqual(_cognito_users(_strip_comments(source)), {'master': None})
        self.assertEqual(
            _exempt_users('# ci-probe is described here\nEXEMPT_USERS = "master"'),
            ['master']
        )

    def test_detector_keeps_a_hash_inside_a_string(self):
        '''Comment stripping that ate string contents would silently shorten
        an exemption list or a username.'''
        self.assertEqual(
            _strip_comments('description = "pool #1" # trailing'),
            'description = "pool #1" '
        )


if __name__ == '__main__':
    unittest.main()
