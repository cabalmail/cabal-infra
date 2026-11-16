'''Unit tests for how the mail tiers restart sendmail (issue #2450):
sendmail-restart-lib.sh, and the parts of reconfigure.sh and
sendmail-wrapper.sh that use it.

Run from the repo root (CI: lint.yml python job):
    python3 -m unittest discover -s docker/shared/test/sendmail-restart -p "test_*.py"

The scripts are the real ones. reconfigure.sh and sendmail-wrapper.sh name
their helpers by absolute path, so each test runs a copy in which
/usr/local/bin/ and /usr/sbin/sendmail point into a temporary directory of
stubs, and /etc/mail/ and the two /run files at the test's own copies;
nothing else in them is altered. bash, jq and sha256sum are real.
Time is faked: the `sleep` stub adds its argument to a clock file instead of
sleeping, and the `ps` stub answers a process's age from that clock, so a
test that "waits" 15 seconds takes none.

What is pinned, in the order of the two rules in sendmail-restart-lib.sh:
  1. a kill never lands on a sendmail that supervisord started less than
     SENDMAIL_MIN_AGE seconds ago;
  2. a pass that a queue message started kills only when a file sendmail
     reads has changed since sendmail started, and the fallback pass kills
     regardless.
'''
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SHARED = os.path.join(HERE, '..', '..')
LIB = os.path.join(SHARED, 'sendmail-restart-lib.sh')
RECONFIGURE = os.path.join(SHARED, 'reconfigure.sh')
WRAPPER = os.path.join(SHARED, 'sendmail-wrapper.sh')

SUPERVISOR_PID = '4242'

# Every stub appends what it was asked to $FAKE/log, one line a call.
STUBS = {
    # The clock. Each call is one line in the log, so a test can count them.
    'sleep': r'''
echo "sleep $1" >> "$FAKE/log"
now=$(cat "$FAKE/clock"); echo $((now + ${1%.*})) > "$FAKE/clock"''',
    # supervisord's children: $FAKE/children holds "pid name started-at"
    # lines. Only the form the library uses is answered; anything else is
    # an error, so a change to the call shows up as a failing test.
    'pgrep': r'''
echo "pgrep $*" >> "$FAKE/log"
[ "$1" = "-x" ] && [ "$2" = "-P" ] && [ "$4" = "sendmail|sendmail-wrappe" ] || exit 2
[ "$3" = "$FAKE_SUPERVISOR" ] || exit 1
now=$(cat "$FAKE/clock"); found=1
while read -r pid name started; do
  [ -n "$pid" ] || continue
  # A process that has not been spawned yet is not there to be found.
  [ "$started" -le "$now" ] || continue
  case "$name" in sendmail|sendmail-wrappe) echo "$pid"; found=0 ;; esac
done < "$FAKE/children"
exit $found''',
    'ps': r'''
echo "ps $*" >> "$FAKE/log"
[ "$1" = "-o" ] && [ "$2" = "etimes=" ] && [ "$3" = "-p" ] || exit 2
now=$(cat "$FAKE/clock")
while read -r pid name started; do
  if [ "$pid" = "$4" ]; then
    [ -f "$FAKE/ps-garbage" ] && { echo "  ?"; exit 0; }
    printf '%7d\n' $((now - started)); exit 0
  fi
done < "$FAKE/children"
exit 1''',
    # Records the kill with the age of supervisord's sendmail at that
    # instant, which is the number rule 1 is about. With $FAKE/respawn, a
    # kill is followed at once by a new child, as under supervisord.
    'pkill': r'''
now=$(cat "$FAKE/clock"); age=none
while read -r pid name started; do
  [ -n "$pid" ] && [ "$started" -le "$now" ] && age=$((now - started))
done < "$FAKE/children"
echo "pkill $* age=$age" >> "$FAKE/log"
if [ -f "$FAKE/respawn" ] && [ "$1 $2" = "-x sendmail" ]; then
  echo "$((now + 100000)) sendmail $now" > "$FAKE/children"
fi
exit 0''',
}

# Stubs for the reconfigure.sh runs.
RECONFIGURE_STUBS = {
    # $FAKE/queue is the script: one line a long poll, "msg" or "empty";
    # when it runs out the stub ends the loop by stopping the script. A
    # drain (--wait-time-seconds 0) always finds the queue empty.
    'aws': r'''
echo "aws $1 $2" >> "$FAKE/log"
case "$1 $2" in
  "sqs receive-message")
    case " $* " in *" --wait-time-seconds 0 "*) echo '{}'; exit 0 ;; esac
    next=$(head -n 1 "$FAKE/queue"); sed -i.bak 1d "$FAKE/queue"
    case "$next" in
      msg) echo '{"Messages":[{"ReceiptHandle":"h"}]}' ;;
      empty) echo '{}' ;;
      *) kill -TERM "$PPID"; sleep_forever=1; exit 0 ;;
    esac ;;
esac
exit 0''',
    # Writes the tier's files from $FAKE/state, as the real one writes
    # them from the table.
    'generate-config.sh': r'''
echo "generate-config" >> "$FAKE/log"
cp "$FAKE"/state/* "$SENDMAIL_INPUT_DIR"/''',
    'makemap': 'cat > /dev/null; exit 0',
    'date': r'''
[ "$1" = "+%s" ] && { cat "$FAKE/clock"; exit 0; }
exec /bin/date "$@"''',
}


def _write_exec(path, body):
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('#!/bin/bash\n' + textwrap.dedent(body).strip('\n') + '\n')
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Sandbox(unittest.TestCase):
    '''A temporary directory with stubs first on PATH, a fake clock, a fake
    /etc/mail and a fake list of supervisord's children.'''

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='sendmail-restart-')
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.fake = os.path.join(self.tmp, 'fake')
        self.bin = os.path.join(self.tmp, 'bin')
        self.mail = os.path.join(self.tmp, 'mail')
        for path in (self.fake, self.bin, self.mail, os.path.join(self.fake, 'state')):
            os.makedirs(path)
        for name, body in STUBS.items():
            _write_exec(os.path.join(self.bin, name), body)
        if not shutil.which('sha256sum'):  # a stock macOS has shasum only
            _write_exec(os.path.join(self.bin, 'sha256sum'), 'exec shasum -a 256 "$@"')
        shutil.copy(LIB, os.path.join(self.bin, 'sendmail-restart-lib.sh'))
        self.aliases = os.path.join(self.tmp, 'aliases')
        self.record = os.path.join(self.tmp, 'sendmail-loaded.digest')
        self.put('clock', '1000\n')
        self.put('children', '')
        self.put('log', '')
        self.mail_file('access', 'To:a@example.test\tRELAY\n')
        self.mail_file('relay-domains', 'example.test\n')
        self.env = dict(
            os.environ,
            PATH=self.bin + os.pathsep + os.environ['PATH'],
            FAKE=self.fake,
            FAKE_SUPERVISOR=SUPERVISOR_PID,
            SENDMAIL_SUPERVISOR_PID=SUPERVISOR_PID,
            SENDMAIL_INPUT_DIR=self.mail,
            SENDMAIL_ALIASES=self.aliases,
            SENDMAIL_LOADED_DIGEST=self.record,
        )
        self.env.pop('SENDMAIL_MIN_AGE', None)

    def put(self, name, text):
        with open(os.path.join(self.fake, name), 'w', encoding='utf-8') as fh:
            fh.write(text)

    def mail_file(self, name, text):
        with open(os.path.join(self.mail, name), 'w', encoding='utf-8') as fh:
            fh.write(text)

    def children(self, *rows):
        '''Each row: (pid, name, seconds ago supervisord started it).'''
        self.put('children', ''.join(f'{pid} {name} {1000 - ago}\n' for pid, name, ago in rows))

    def log(self):
        with open(os.path.join(self.fake, 'log'), encoding='utf-8') as fh:
            return fh.read().splitlines()

    def calls(self, prefix):
        return [line for line in self.log() if line.startswith(prefix)]

    def lib(self, snippet, strict=True, **env):
        '''Runs a bash snippet with the library sourced; under the same
        options as reconfigure.sh when strict, bare (as the wrapper) when
        not.'''
        head = 'set -euo pipefail\n' if strict else ''
        script = head + f'. "{self.bin}/sendmail-restart-lib.sh"\n' + snippet
        return subprocess.run(['bash', '-c', script], env=dict(self.env, **env),
                              capture_output=True, text=True, check=False)

    def digest(self):
        proc = self.lib('sendmail_inputs_digest')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def record_now(self):
        proc = self.lib('sendmail_record_loaded_inputs')
        self.assertEqual(proc.returncode, 0, proc.stderr)


class Digest(Sandbox):
    '''What counts as "a file sendmail reads has changed".'''

    def test_same_files_same_digest(self):
        first = self.digest()
        self.assertRegex(first, r'^[0-9a-f]{64}$')
        self.assertEqual(first, self.digest())

    def test_a_changed_line_changes_it(self):
        before = self.digest()
        self.mail_file('access', 'To:a@example.test\tRELAY\nTo:b@example.test\tRELAY\n')
        self.assertNotEqual(before, self.digest())

    def test_a_new_file_changes_it(self):
        before = self.digest()
        self.mail_file('local-host-names', 'example.test\n')
        self.assertNotEqual(before, self.digest())

    def test_content_moving_between_files_changes_it(self):
        # The file's name is part of the digest: the same lines under
        # another name are another configuration.
        self.mail_file('masq-domains', 'x.test\n')
        before = self.digest()
        os.rename(os.path.join(self.mail, 'masq-domains'), os.path.join(self.mail, 'mailertable'))
        self.assertNotEqual(before, self.digest())

    def test_the_aliases_file_counts(self):
        before = self.digest()
        with open(self.aliases, 'w', encoding='utf-8') as fh:
            fh.write('a_b: a, b\n')
        self.assertNotEqual(before, self.digest())

    def test_rebuilt_maps_and_staging_files_do_not_count(self):
        # makemap rewrites every .db on every pass, and generate-config.sh
        # stages each write as <name>.tmp; neither is a change.
        before = self.digest()
        self.mail_file('access.db', 'rebuilt, different bytes\n')
        self.mail_file('virtusertable.tmp', 'half-written\n')
        os.makedirs(os.path.join(self.mail, 'subdir'))
        self.assertEqual(before, self.digest())

    @unittest.skipIf(os.geteuid() == 0, 'root reads any file')
    def test_an_unreadable_file_is_an_error_not_a_digest(self):
        os.chmod(os.path.join(self.mail, 'access'), 0)
        proc = self.lib('sendmail_inputs_digest')
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, '')

    def test_works_without_the_callers_shell_options(self):
        # sendmail-wrapper.sh runs without set -e or pipefail.
        proc = self.lib('sendmail_inputs_digest', strict=False)
        self.assertEqual(proc.stdout.strip(), self.digest())


class Changed(Sandbox):
    '''sendmail_inputs_changed: exit 0 means "restart".'''

    def changed(self):
        return self.lib('if sendmail_inputs_changed; then echo changed; else echo same; fi').stdout.strip()

    def test_same_files_as_recorded(self):
        self.record_now()
        self.assertEqual(self.changed(), 'same')

    def test_a_file_changed_since_the_record(self):
        self.record_now()
        self.mail_file('relay-domains', 'example.test\nnew.example.test\n')
        self.assertEqual(self.changed(), 'changed')

    def test_changed_back_is_same_again(self):
        self.record_now()
        self.mail_file('relay-domains', 'example.test\nnew.example.test\n')
        self.mail_file('relay-domains', 'example.test\n')
        self.assertEqual(self.changed(), 'same')

    def test_no_record_means_changed(self):
        self.assertFalse(os.path.exists(self.record))
        self.assertEqual(self.changed(), 'changed')

    def test_an_empty_or_foreign_record_means_changed(self):
        for text in ('', 'not a digest\n'):
            with open(self.record, 'w', encoding='utf-8') as fh:
                fh.write(text)
            self.assertEqual(self.changed(), 'changed', repr(text))

    @unittest.skipIf(os.geteuid() == 0, 'root reads any file')
    def test_a_file_that_cannot_be_read_means_changed(self):
        self.record_now()
        os.chmod(os.path.join(self.mail, 'access'), 0)
        self.assertEqual(self.changed(), 'changed')

    @unittest.skipIf(os.geteuid() == 0, 'root writes anywhere')
    def test_a_record_that_cannot_be_written_is_reported(self):
        self.record_now()
        os.chmod(self.tmp, 0o500)
        self.addCleanup(os.chmod, self.tmp, 0o700)
        proc = self.lib('sendmail_record_loaded_inputs', strict=False)
        self.assertNotEqual(proc.returncode, 0)
        # (Here the old record could not be removed either. The caller
        # is told, and sendmail-wrapper.sh says so in the tier's log.)

    def test_recording_replaces_an_older_record(self):
        self.record_now()
        self.mail_file('access', 'To:z@example.test\tRELAY\n')
        self.assertEqual(self.changed(), 'changed')
        self.record_now()
        self.assertEqual(self.changed(), 'same')


class Age(Sandbox):
    '''sendmail_supervised_age: whose age is read.'''

    def age(self, **env):
        return self.lib('sendmail_supervised_age', **env)

    def test_the_daemon_under_supervisord(self):
        self.children((77, 'sendmail', 40))
        proc = self.age()
        self.assertEqual((proc.returncode, proc.stdout.strip()), (0, '40'))

    def test_the_wrapper_before_its_exec_counts(self):
        # Until the exec the process is named for the wrapper; it is the
        # same process and supervisord's clock is already running.
        self.children((77, 'sendmail-wrappe', 0))
        proc = self.age()
        self.assertEqual((proc.returncode, proc.stdout.strip()), (0, '0'))

    def test_asks_only_under_supervisord_and_only_for_those_two_names(self):
        self.children((77, 'sendmail', 40))
        self.age()
        self.assertEqual(self.calls('pgrep'),
                         [f'pgrep -x -P {SUPERVISOR_PID} sendmail|sendmail-wrappe'])
        self.assertEqual(self.calls('ps'), ['ps -o etimes= -p 77'])

    def test_supervisord_is_the_parent_unless_told(self):
        env = dict(self.env)
        del env['SENDMAIL_SUPERVISOR_PID']
        script = (f'. "{self.bin}/sendmail-restart-lib.sh"\n'
                  'echo "$SENDMAIL_SUPERVISOR_PID $PPID"')
        out = subprocess.run(['bash', '-c', script], env=env, capture_output=True,
                             text=True, check=True).stdout.split()
        self.assertEqual(out[0], out[1])
        self.assertEqual(out[0], str(os.getpid()))

    def test_no_child_is_not_an_age(self):
        proc = self.age()
        self.assertEqual((proc.returncode, proc.stdout), (1, ''))

    def test_another_program_under_supervisord_is_not_sendmail(self):
        self.children((80, 'dovecot', 500))
        self.assertEqual(self.age().returncode, 1)

    def test_an_age_that_cannot_be_read_is_not_an_age(self):
        self.children((77, 'sendmail', 40))
        self.put('ps-garbage', '')
        proc = self.age()
        self.assertEqual((proc.returncode, proc.stdout), (1, ''))


class Restart(Sandbox):
    '''sendmail_restart: rule 1. The pkill stub records the age of
    supervisord's sendmail at the instant of the kill.'''

    def restart(self, **env):
        proc = self.lib('sendmail_restart', **env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout

    def test_an_old_sendmail_is_killed_at_once(self):
        self.children((77, 'sendmail', 900))
        out = self.restart()
        self.assertEqual(self.calls('pkill'), ['pkill -x sendmail age=900'])
        self.assertEqual(self.calls('sleep'), [])
        self.assertIn('[reconfigure] Killing sendmail; supervisord will restart it...', out)

    def test_exactly_old_enough_is_killed_at_once(self):
        self.children((77, 'sendmail', 15))
        self.restart()
        self.assertEqual(self.calls('pkill'), ['pkill -x sendmail age=15'])
        self.assertEqual(self.calls('sleep'), [])

    def test_a_young_sendmail_is_waited_for(self):
        # Started 3s ago, so 2s short of supervisord's startsecs: a kill
        # now is the failed start of issue #2450.
        self.children((77, 'sendmail', 3))
        out = self.restart()
        self.assertEqual(self.calls('pkill'), ['pkill -x sendmail age=15'])
        self.assertEqual(self.calls('sleep'), ['sleep 1'] * 12)
        self.assertEqual(out.count('waiting until it has been up 15s'), 1)
        self.assertIn('sendmail was started 3s ago', out)

    def test_a_wrapper_that_has_not_become_sendmail_is_waited_for(self):
        self.children((77, 'sendmail-wrappe', 0))
        self.restart()
        self.assertEqual(self.calls('pkill'), ['pkill -x sendmail age=15'])

    def test_no_kill_is_ever_younger_than_the_minimum(self):
        for ago in range(0, 15):
            with self.subTest(started_seconds_ago=ago):
                self.put('log', '')
                self.put('clock', '1000\n')
                self.children((77, 'sendmail', ago))
                self.restart()
                kills = self.calls('pkill')
                self.assertEqual(len(kills), 1)
                self.assertGreaterEqual(int(kills[0].split('age=')[1]), 15)

    def test_the_minimum_is_three_times_supervisords_startsecs(self):
        # The floor is tied to the configuration it guards: change
        # startsecs in a tier's supervisord.conf and this fails until the
        # default here is looked at again.
        proc = self.lib('echo "$SENDMAIL_MIN_AGE"')
        self.assertEqual(proc.stdout.strip(), '15')
        for tier in ('imap', 'smtp-in', 'smtp-out'):
            with open(os.path.join(SHARED, '..', tier, 'supervisord.conf'), encoding='utf-8') as fh:
                block = fh.read().split('[program:sendmail]')[1].split('[program:')[0]
            self.assertIn('\nstartsecs=5\n', block, tier)
            self.assertNotIn('startretries', block, tier)

    def test_the_minimum_can_be_set(self):
        self.children((77, 'sendmail', 3))
        self.restart(SENDMAIL_MIN_AGE='30')
        self.assertEqual(self.calls('pkill'), ['pkill -x sendmail age=30'])

    def test_with_no_sendmail_under_supervisord_there_is_nothing_to_wait_for(self):
        # supervisord is between retries or has given up. The pkill still
        # runs, as it always did, for anything else named sendmail.
        self.restart()
        self.assertEqual(self.calls('pkill'), ['pkill -x sendmail age=none'])
        self.assertEqual(self.calls('sleep'), [])

    def test_a_sendmail_that_goes_away_during_the_wait_ends_the_wait(self):
        self.children((77, 'sendmail', 3))
        _write_exec(os.path.join(self.bin, 'sleep'), STUBS['sleep'] + r'''
[ "$(cat "$FAKE/clock")" -ge 1004 ] && : > "$FAKE/children"''')
        self.restart()
        self.assertEqual(self.calls('sleep'), ['sleep 1'] * 4)
        self.assertEqual(self.calls('pkill'), ['pkill -x sendmail age=none'])

    def test_a_sendmail_that_never_stays_up_is_left_alone(self):
        # Something else keeps restarting it: every look finds one that
        # is 2s old. Killing it would add a failed start to a program
        # already failing, so after four times the minimum the pass goes
        # on without the kill.
        _write_exec(os.path.join(self.bin, 'ps'), r'''
echo "ps $*" >> "$FAKE/log"; echo "      2"''')
        self.children((77, 'sendmail', 2))
        out = self.restart()
        self.assertEqual(self.calls('pkill'), [])
        self.assertEqual(self.calls('sleep'), ['sleep 1'] * 60)
        self.assertIn('not staying up 15s; not killing it', out)
        self.assertNotIn('Killing sendmail', out)


class ReconfigurePass(Sandbox):
    '''reconfigure.sh itself, tier smtp-in: which passes end in a kill.
    The copy under test differs from the real script only in where its
    absolute paths point.'''

    def setUp(self):
        super().setUp()
        for name, body in RECONFIGURE_STUBS.items():
            _write_exec(os.path.join(self.bin, name), body)
        with open(RECONFIGURE, encoding='utf-8') as fh:
            text = fh.read()
        self.assertIn('. /usr/local/bin/sendmail-restart-lib.sh', text)
        script = os.path.join(self.bin, 'reconfigure.sh')
        with open(script, 'w', encoding='utf-8') as fh:
            fh.write(text.replace('/usr/local/bin/', self.bin + '/')
                     .replace('/etc/mail/', self.mail + '/'))
        os.chmod(script, 0o755)
        self.script = script
        self.ready = os.path.join(self.tmp, 'sendmail-ready')
        for name in ('masq-domains', 'access', 'relay-domains', 'mailertable', 'virtusertable'):
            text = f'{name} v1\n'
            self.mail_file(name, text)
            with open(os.path.join(self.fake, 'state', name), 'w', encoding='utf-8') as fh:
                fh.write(text)
        self.children((77, 'sendmail', 900))
        self.put('respawn', '')
        self.record_now()   # what sendmail-wrapper.sh did when it started sendmail

    def state(self, name, text):
        with open(os.path.join(self.fake, 'state', name), 'w', encoding='utf-8') as fh:
            fh.write(text)

    def run_loop(self, queue, interval='900', **env):
        '''Runs the loop over a scripted queue; returns its output.'''
        self.put('queue', ''.join(line + '\n' for line in queue))
        with open(self.script, encoding='utf-8') as fh:
            text = fh.read()
        with open(self.script, 'w', encoding='utf-8') as fh:
            fh.write(text.replace('/run/sendmail-ready', self.ready))
        open(self.ready, 'w', encoding='utf-8').close()
        run_env = dict(self.env, TIER='smtp-in', CERT_DOMAIN='example.test',
                       AWS_REGION='us-east-1', SQS_QUEUE_URL='stub',
                       RECONFIGURE_INTERVAL=interval)
        run_env.update(env)
        proc = subprocess.run(['bash', self.script], env=run_env, capture_output=True,
                              text=True, check=False, timeout=60)
        # The aws stub ends the loop with SIGTERM once the queue script
        # runs out (bash reports that as the signal or as 128+15);
        # anything else is the script failing.
        self.assertIn(proc.returncode, (-15, 143), proc.stdout + proc.stderr)
        return proc.stdout

    def kills(self):
        return self.calls('pkill -x sendmail')

    def test_a_message_that_changes_nothing_sendmail_reads_restarts_nothing(self):
        out = self.run_loop(['msg'])
        self.assertEqual(self.calls('generate-config'), ['generate-config'])
        self.assertEqual(self.kills(), [])
        self.assertIn('[reconfigure] Nothing sendmail reads has changed; not restarting it.', out)
        self.assertIn('[reconfigure] Done.', out)

    def test_a_train_of_such_messages_restarts_nothing(self):
        # The rule-save train of issue #2450: prod's longest was ten.
        out = self.run_loop(['msg'] * 10)
        self.assertEqual(len(self.calls('generate-config')), 10)
        self.assertEqual(self.kills(), [])
        self.assertEqual(out.count('Nothing sendmail reads has changed'), 10)

    def test_a_message_that_changes_a_file_restarts_once(self):
        self.state('access', 'access v2\n')
        out = self.run_loop(['msg'])
        self.assertEqual(self.kills(), ['pkill -x sendmail age=900'])
        self.assertNotIn('Nothing sendmail reads has changed', out)

    def test_with_no_record_a_message_restarts(self):
        os.remove(self.record)
        self.run_loop(['msg'])
        self.assertEqual(len(self.kills()), 1)

    def test_the_fallback_pass_restarts_whatever_the_files_say(self):
        out = self.run_loop(['empty'], interval='0')
        self.assertIn('Periodic fallback regeneration', out)
        self.assertEqual(self.kills(), ['pkill -x sendmail age=900'])
        self.assertNotIn('Nothing sendmail reads has changed', out)

    def test_periodic_only_mode_restarts_whatever_the_files_say(self):
        # No queue configured: the script ends itself through the sleep
        # stub the second time round.
        _write_exec(os.path.join(self.bin, 'sleep'), STUBS['sleep'] + r'''
[ "$1" = 60 ] && [ "$(grep -c '^sleep 60' "$FAKE/log")" -ge 2 ] && kill -TERM "$PPID"
exit 0''')
        out = self.run_loop([], interval='0', SQS_QUEUE_URL='')
        self.assertIn('Periodic regeneration', out)
        self.assertGreaterEqual(len(self.kills()), 1)

    def test_a_train_that_changes_a_file_every_time_never_kills_a_young_sendmail(self):
        # The address burst: every message changes what sendmail reads,
        # so every pass restarts. The generate-config stub writes a new
        # file each pass and "takes" 2s; after each kill the pkill stub
        # gives supervisord a new child. Before #2450's change this loop
        # killed a 2-second-old sendmail on the second pass.
        _write_exec(os.path.join(self.bin, 'generate-config.sh'), r'''
echo "generate-config" >> "$FAKE/log"
n=$(grep -c '^generate-config' "$FAKE/log")
echo "access after pass $n" > "$SENDMAIL_INPUT_DIR/access"
now=$(cat "$FAKE/clock"); echo $((now + 2)) > "$FAKE/clock"''')
        # Nothing re-records in this harness (no wrapper runs), so every
        # pass sees a change, which is the worst case.
        self.run_loop(['msg'] * 6)
        kills = self.kills()
        self.assertEqual(len(kills), 6)
        ages = [int(k.split('age=')[1]) for k in kills]
        self.assertEqual(ages[0], 902)
        for age in ages[1:]:
            self.assertGreaterEqual(age, 15)

    def test_the_fallback_pass_waits_for_a_young_sendmail_too(self):
        self.children((77, 'sendmail', 1))
        self.run_loop(['empty'], interval='0')
        self.assertEqual(self.kills(), ['pkill -x sendmail age=15'])


class Wrapper(Sandbox):
    '''sendmail-wrapper.sh records what sendmail is about to read, and
    starts sendmail whether or not it could.'''

    def setUp(self):
        super().setUp()
        with open(WRAPPER, encoding='utf-8') as fh:
            text = fh.read()
        self.assertIn('. /usr/local/bin/sendmail-restart-lib.sh', text)
        self.assertIn('exec /usr/sbin/sendmail -bD -q15m', text)
        self.ready = os.path.join(self.tmp, 'sendmail-ready')
        open(self.ready, 'w', encoding='utf-8').close()
        text = (text.replace('/usr/local/bin/', self.bin + '/')
                .replace('/usr/sbin/sendmail', os.path.join(self.bin, 'fake-sendmail'))
                .replace('/run/sendmail-ready', self.ready)
                .replace('/var/run/sendmail.pid', os.path.join(self.tmp, 'sendmail.pid')))
        self.script = os.path.join(self.bin, 'sendmail-wrapper.sh')
        with open(self.script, 'w', encoding='utf-8') as fh:
            fh.write(text)
        # The stand-in for sendmail notes whether the record was there
        # when it started, and what it said.
        _write_exec(os.path.join(self.bin, 'fake-sendmail'), r'''
echo "sendmail $* record=$(cat "$SENDMAIL_LOADED_DIGEST" 2>/dev/null || echo none)" >> "$FAKE/log"''')

    def run_wrapper(self):
        return subprocess.run(['bash', self.script], env=dict(self.env, TIER='imap'),
                              capture_output=True, text=True, check=False, timeout=30)

    def test_the_record_is_written_before_sendmail_starts(self):
        expected = self.digest()
        proc = self.run_wrapper()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.calls('sendmail'), [f'sendmail -bD -q15m record={expected}'])

    def test_a_restart_records_the_files_as_they_are_now(self):
        self.run_wrapper()
        self.mail_file('access', 'To:new@example.test\tRELAY\n')
        self.run_wrapper()
        first, second = self.calls('sendmail')
        self.assertNotEqual(first, second)
        self.assertEqual(second, f'sendmail -bD -q15m record={self.digest()}')

    def test_sendmail_starts_even_if_the_library_is_missing(self):
        os.remove(os.path.join(self.bin, 'sendmail-restart-lib.sh'))
        proc = self.run_wrapper()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.calls('sendmail'), ['sendmail -bD -q15m record=none'])

    @unittest.skipIf(os.geteuid() == 0, 'root reads any file')
    def test_sendmail_starts_even_if_the_record_cannot_be_made(self):
        with open(self.record, 'w', encoding='utf-8') as fh:
            fh.write('stale\n')
        os.chmod(os.path.join(self.mail, 'access'), 0)
        proc = self.run_wrapper()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # No record at all, so the next queue message restarts sendmail:
        # a stale one could have said "nothing changed".
        self.assertEqual(self.calls('sendmail'), ['sendmail -bD -q15m record=none'])
        self.assertIn("could not record sendmail's inputs", proc.stdout)


if __name__ == '__main__':
    unittest.main()
