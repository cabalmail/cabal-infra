'''Unit tests for sync-users.sh (the Cognito -> OS account sync).

Run from the repo root (CI: lint.yml python job):
    python3 -m unittest discover -s docker/shared/test/sync-users -p "test_*.py"

Runs the real script with PATH stubs for aws, getent, groupadd, useradd,
install, cmp and chown over fake account and group databases, so it needs no
root, no image and no AWS. bash, jq and sort are real. The groupadd and
useradd stubs refuse roughly what the image's shadow-utils refuses (names
outside [A-Za-z0-9_.][A-Za-z0-9_.-]{0,31}, all-digit names, a gid or uid
already taken, a missing primary group), and getent reads a numeric key as
an id, as glibc's does.
'''
import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, '..', '..', 'sync-users.sh')

BASE_ACCOUNTS = textwrap.dedent('''\
    root:x:0:0:root:/root:/bin/bash
    halt:x:7:0:halt:/sbin:/sbin/halt
    mail:x:8:12:mail:/var/spool/mail:/sbin/nologin
    nobody:x:65534:65534:Kernel Overflow User:/:/sbin/nologin
    dovenull:x:996:996:Dovecot's unauthorized user:/usr/libexec/dovecot:/sbin/nologin
''')
BASE_GROUP = textwrap.dedent('''\
    root:x:0:
    mail:x:12:
    users:x:100:
    wheel:x:10:
    nobody:x:65534:
    dovenull:x:996:
''')

STUBS = {
    'aws': 'cat "$FAKE/users.json"',
    'getent': r'''
db="$1"; shift; [ "${1:-}" = "--" ] && shift
key="$1"
# The fake account database is "accounts"; the group one keeps its name.
case "$db" in passwd) f="$FAKE/accounts" ;; *) f="$FAKE/$db" ;; esac
if [[ "$key" =~ ^[0-9]+$ ]]; then
  awk -F: -v k="$key" '$3==k{print; found=1; exit} END{exit !found}' "$f" || exit 2
else
  awk -F: -v k="$key" '$1==k{print; found=1; exit} END{exit !found}' "$f" || exit 2
fi''',
    'groupadd': r'''
[ "$1" = "-g" ] || exit 2; gid="$2"; name="$3"
[[ "$name" =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]{0,31}$ ]] && [[ ! "$name" =~ ^[0-9]+$ ]] \
  || { echo "groupadd: '$name' is not a valid group name" >&2; exit 3; }
awk -F: -v k="$gid" '$3==k{f=1} END{exit !f}' "$FAKE/group" \
  && { echo "groupadd: GID '$gid' already exists" >&2; exit 4; }
echo "$name:x:$gid:" >> "$FAKE/group"; echo "groupadd $gid $name" >> "$FAKE/log"''',
    'useradd': r'''
uid="$2"; gid="$4"; name="$6"
[[ "$name" =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]{0,31}$ ]] && [[ ! "$name" =~ ^[0-9]+$ ]] \
  || { echo "useradd: invalid user name '$name'" >&2; exit 3; }
awk -F: -v k="$gid" '$3==k{f=1} END{exit !f}' "$FAKE/group" \
  || { echo "useradd: group '$gid' does not exist" >&2; exit 6; }
awk -F: -v k="$uid" '$3==k{f=1} END{exit !f}' "$FAKE/accounts" \
  && { echo "useradd: UID $uid is not unique" >&2; exit 4; }
echo "$name:x:$uid:$gid::/home/$name:/bin/bash" >> "$FAKE/accounts"
echo "useradd $uid $name" >> "$FAKE/log"''',
    'install': 'echo "install $*" >> "$FAKE/log"',
    'cmp': 'exit 1',
    'chown': 'echo "chown $*" >> "$FAKE/log"',
}


def user(name, osid, status='CONFIRMED'):
    '''One list-users entry, with custom:osid unless osid is None.'''
    attrs = [] if osid is None else [{'Name': 'custom:osid', 'Value': str(osid)}]
    return {'Username': name, 'UserStatus': status, 'Attributes': attrs}


class SyncUsersTests(unittest.TestCase):
    '''Each test runs the script once or twice against a fresh fake system.'''

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.fake = os.path.join(self.dir, 'fake')
        os.mkdir(self.fake)
        self.bindir = os.path.join(self.dir, 'bin')
        os.mkdir(self.bindir)
        for name, body in STUBS.items():
            self.write_stub(name, body)
        for name, body in (('accounts', BASE_ACCOUNTS), ('group', BASE_GROUP), ('log', '')):
            with open(os.path.join(self.fake, name), 'w', encoding='utf-8') as handle:
                handle.write(body)
        self.env = dict(os.environ, PATH=self.bindir + ':' + os.environ['PATH'],
                        FAKE=self.fake, COGNITO_POOL_ID='pool', AWS_REGION='us-east-1')

    def write_stub(self, name, body):
        '''Writes an executable stub for `name` ahead of the real one on PATH.'''
        path = os.path.join(self.bindir, name)
        with open(path, 'w', encoding='utf-8') as handle:
            handle.write('#!/bin/bash\n' + body + '\n')
        os.chmod(path, 0o755)

    def run_sync(self, users):
        '''Runs sync-users.sh with `users` as the pool's list-users answer.'''
        with open(os.path.join(self.fake, 'users.json'), 'w', encoding='utf-8') as handle:
            json.dump({'Users': users}, handle)
        return subprocess.run(['bash', SCRIPT], env=self.env, capture_output=True,
                              text=True, check=False)

    def read(self, name):
        '''One of the fake system's files.'''
        with open(os.path.join(self.fake, name), encoding='utf-8') as handle:
            return handle.read()

    def entries(self, name):
        '''The names in the fake account or group database.'''
        return [line.split(':', 1)[0] for line in self.read(name).splitlines()]

    def installed_for(self, name):
        '''The install calls that touched /home/<name>/.'''
        return [line for line in self.read('log').splitlines()
                if line.startswith('install') and f'/home/{name}/' in line]

    def test_a_new_user_gets_its_own_uid_and_a_second_pass_changes_nothing(self):
        users = [user('alice', 65536), user('ci-probe', 9997)]
        first = self.run_sync(users)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn('alice:x:65536:65536:', self.read('accounts'))
        self.assertIn('alice:x:65536:', self.read('group'))
        second = self.run_sync(users)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotIn('SKIP', second.stderr)
        self.assertEqual(self.entries('accounts').count('alice'), 1)
        directories = [line for line in self.installed_for('alice')
                       if line.startswith('install -d ')]
        self.assertEqual(len(directories), 4, 'each pass ensures the two directories')

    def test_an_existing_account_with_another_id_is_skipped(self):
        res = self.run_sync([user('root', 65536), user('mail', 65537),
                             user('nobody', 65538), user('dovenull', 65539),
                             user('bob', 65540)])
        self.assertEqual(res.returncode, 0, res.stderr)
        for name in ('root', 'mail', 'nobody', 'dovenull'):
            self.assertEqual(self.installed_for(name), [], name)
            self.assertIn(f'SKIP {name} ', res.stderr)
        self.assertIn('bob:x:65540:65540:', self.read('accounts'))
        self.assertIn('skipped 4 user(s)', res.stderr)

    def test_a_name_that_exists_only_as_an_account_leaves_no_group_behind(self):
        res = self.run_sync([user('halt', 65536), user('bob', 65537)])
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn('SKIP halt (osid=65536): account exists', res.stderr)
        self.assertNotIn('halt', self.entries('group'))
        self.assertEqual(self.installed_for('halt'), [])
        self.assertIn('bob:x:65537:65537:', self.read('accounts'))

    def test_a_name_that_exists_only_as_a_group_skips_that_user_alone(self):
        res = self.run_sync([user('alice', 65536), user('users', 65537), user('bob', 65538)])
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertNotIn('users', self.entries('accounts'))
        self.assertEqual(self.installed_for('users'), [])
        self.assertIn('bob:x:65538:65538:', self.read('accounts'))
        self.assertIn('skipped 1 user(s)', res.stderr)

    def test_a_name_that_is_not_a_safe_login_skips_that_user_alone(self):
        bad = ('a/b', '..', '.hidden', '-leading-dash', '12345', 'Bad*Name', 'x' * 33)
        res = self.run_sync([user('alice', 65536)]
                            + [user(name, 65537 + i) for i, name in enumerate(bad)]
                            + [user('bob', 65600)])
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn('bob:x:65600:65600:', self.read('accounts'))
        for name in bad:
            self.assertNotIn(name, self.entries('accounts'), name)
            self.assertNotIn(name, self.entries('group'), name)
            self.assertEqual(self.installed_for(name), [], name)
        self.assertNotIn('groupadd: ', res.stderr, 'refused before groupadd runs')

    def test_a_failed_groupadd_skips_that_user_alone(self):
        # A name SAFE_NAME allows but the image's groupadd still refuses.
        self.write_stub('groupadd', r'''
[ "$3" = "refused" ] && { echo "groupadd: refused" >&2; exit 3; }
echo "$3:x:$2:" >> "$FAKE/group"''')
        res = self.run_sync([user('refused', 65536), user('bob', 65537)])
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn('SKIP refused (osid=65536): groupadd failed', res.stderr)
        self.assertIn('bob:x:65537:65537:', self.read('accounts'))

    def test_a_failed_directory_step_names_the_user_it_skipped(self):
        self.write_stub('install', r'''
case "$*" in */home/refused/*) echo "install: refused" >&2; exit 1 ;; esac
echo "install $*" >> "$FAKE/log"''')
        res = self.run_sync([user('refused', 65536), user('bob', 65537)])
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn('SKIP refused (osid=65536): creating ~/Maildir failed', res.stderr)
        self.assertIn('skipped 1 user(s)', res.stderr)
        self.assertEqual(len(self.installed_for('bob')), 2)

    def test_a_duplicate_osid_skips_the_second_user(self):
        res = self.run_sync([user('alice', 65536), user('bob', 65536)])
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn('alice:x:65536:65536:', self.read('accounts'))
        self.assertNotIn('bob', self.entries('accounts'))
        self.assertEqual(self.installed_for('bob'), [])

    def test_a_non_numeric_osid_is_skipped(self):
        res = self.run_sync([user('alice', 'abc'), user('bob', 65537)])
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertNotIn('alice', self.entries('accounts'))
        self.assertIn('bob:x:65537:65537:', self.read('accounts'))

    def test_unconfirmed_and_osid_less_users_are_ignored(self):
        res = self.run_sync([user('pending', 65536, 'UNCONFIRMED'), user('fresh', None)])
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertNotIn('pending', self.entries('accounts'))
        self.assertNotIn('fresh', self.entries('accounts'))
        self.assertNotIn('SKIP', res.stderr)

    def test_a_failed_list_users_still_fails_the_script(self):
        self.write_stub('aws', 'exit 255')
        res = self.run_sync([])
        self.assertNotEqual(res.returncode, 0)


if __name__ == '__main__':
    unittest.main()
