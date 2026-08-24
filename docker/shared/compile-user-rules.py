#!/usr/bin/env python3
'''Compiles user-defined mail rules into per-user procmail includes.

docs/1.x/user-mail-rules-plan.md, Phase 2. Runs inside the imap container
(invoked by reconfigure.sh on every regenerate and by prepare-sendmail.sh at
startup): scans the cabal-user-rules DynamoDB table and writes one
/etc/procmail-user/<user>.rc per local user, which procmailrc includes -
after the system spam rule, BEFORE the push-enqueue recipe, so a rule that
consumes a message decides its push (deleted mail never buzzes; filed mail
gets a compiler-emitted wake signal carrying the destination folder).

This is the only component that turns user input into procmail syntax, so it
trusts nothing: every rule is re-validated against the write-time schema
(defense in depth behind set_rules), condition values are regex-escaped into
literal substring matchers, folder targets must match a conservative safe
character set and exist as Maildir directories, and forward addresses are
re-checked against the address shape. A rule that fails any check is skipped
whole with a logged reason - never emitted mangled - and the user's other
rules still apply. Folder existence is checked directly on the filesystem
(~user/Maildir/.<folder>/) rather than via IMAP LIST: the directory is
exactly what the emitted recipe will deliver into.

Auxiliary actions flag / markRead / reply are not implemented yet (Phase 2b
and 2c); a rule carrying them compiles its conditions, destination, and
forwards, and logs aux_not_implemented for the rest.

Output is deterministic (no timestamps, sorted iteration) so the golden-file
self-test (compile-user-rules-selftest.py) can compare byte-for-byte.
'''
import json
import os
import re
import subprocess
import sys
import tempfile
import time

OUTPUT_DIR = os.environ.get('RULES_OUTPUT_DIR', '/etc/procmail-user')
HOME_ROOT = os.environ.get('RULES_HOME_ROOT', '/home')
TABLE_NAME = os.environ.get('USER_RULES_TABLE_NAME', 'cabal-user-rules')
PUSH_ENQUEUE = '/usr/local/bin/push-enqueue.sh'

MAX_RULES = 100
MAX_NAME_LENGTH = 100
MAX_CONDITIONS = 10
MAX_VALUE_LENGTH = 500
MAX_FORWARDS = 10
MAX_COPY_FOLDERS = 10
MAX_ADDRESS_LENGTH = 320
MAX_FOLDER_LENGTH = 255

# Header anchor per condition field; body is handled separately (B ?? match).
HEADER_ANCHORS = {'from': '^From:', 'to': '^To:', 'cc': '^Cc:', 'subject': '^Subject:'}
ACTIONS = {'move', 'copy', 'delete', 'archive', 'none'}
BOOL_KEYS = ('enabled', 'flag', 'markRead', 'reply', 'continueToNext')
FORWARD_RE = re.compile(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')

# Everything procmail's matcher could treat as more than a literal. A
# backslash lands ONLY in front of these - never before an arbitrary
# character, where it could CREATE a special (procmail's \< is a word
# boundary, for example).
REGEX_METAS = set('\\.^$*+?()[]{}|')

# Folder targets reach recipe action lines (as delivery paths and as a
# push-enqueue argument), where procmail expands $variables and where shell
# metacharacters would demote the pipe to $SHELL. Rather than escape our way
# around that, only this conservative set is compilable; anything else skips
# the rule (unsafe_folder) - strict, never mangled. Slash is the wire-format
# hierarchy separator; space is allowed inside a segment but not at its ends.
FOLDER_SAFE_RE = re.compile(r'^[A-Za-z0-9._/ -]+$')


def escape_value(value):
    '''Regex-escapes a condition value so it matches as a literal substring.'''
    return ''.join('\\' + ch if ch in REGEX_METAS else ch for ch in value)


def has_controls(value):
    '''True if the string contains any control character.'''
    return any(ord(ch) < 32 or ord(ch) == 127 for ch in value)


def folder_to_dir(folder):
    '''Maps a wire-format folder name to its Maildir directory name.

    Returns '' for INBOX (the Maildir root), the '.'-joined maildir
    directory name (".Work.Clients") for a valid folder, or None when the
    name falls outside the safe set. Accepts '/' or '.' as the hierarchy
    separator ('/' on the wire, '.' internally - both appear in stored
    rules).
    '''
    if not isinstance(folder, str) or not folder or len(folder) > MAX_FOLDER_LENGTH:
        return None
    if not FOLDER_SAFE_RE.match(folder):
        return None
    name = folder.replace('/', '.')
    if name.upper() == 'INBOX':
        return ''
    segments = name.split('.')
    if any(not seg or seg != seg.strip() for seg in segments):
        return None
    return '.' + name


def valid_forward(addr):
    '''True if the address may appear in a compiled ! forward action.'''
    return (isinstance(addr, str) and len(addr) <= MAX_ADDRESS_LENGTH
            and bool(FORWARD_RE.match(addr)) and not has_controls(addr))


def validate_rule(rule):
    '''Re-validates the write-time schema; returns a skip reason or None.'''
    if not isinstance(rule, dict):
        return 'schema'
    name = rule.get('name')
    if (not isinstance(name, str) or not 1 <= len(name.strip()) <= MAX_NAME_LENGTH
            or has_controls(name)):
        return 'schema'
    for key in BOOL_KEYS:
        if not isinstance(rule.get(key), bool):
            return 'schema'
    if rule.get('action') not in ACTIONS:
        return 'schema'
    conditions = rule.get('conditions')
    if not isinstance(conditions, list) or len(conditions) > MAX_CONDITIONS:
        return 'schema'
    for cond in conditions:
        if not isinstance(cond, dict):
            return 'schema'
        if cond.get('field') not in set(HEADER_ANCHORS) | {'body'}:
            return 'schema'
        value = cond.get('value')
        if (not isinstance(value, str) or not 1 <= len(value) <= MAX_VALUE_LENGTH
                or has_controls(value)):
            return 'schema'
    if not isinstance(rule.get('moveFolder'), str):
        return 'schema'
    copy_folders = rule.get('copyFolders')
    if not isinstance(copy_folders, list) or len(copy_folders) > MAX_COPY_FOLDERS:
        return 'schema'
    forwards = rule.get('forward')
    if not isinstance(forwards, list) or len(forwards) > MAX_FORWARDS:
        return 'schema'
    return None


def condition_lines(conditions):
    '''The `* ` condition lines for a rule (empty list matches everything).'''
    lines = []
    for cond in conditions:
        escaped = escape_value(cond['value'])
        if cond['field'] == 'body':
            lines.append(f'* B ?? {escaped}')
        else:
            lines.append(f'* {HEADER_ANCHORS[cond["field"]]}.*{escaped}')
    return lines


def push_block(label):
    '''The guarded wake-signal recipe emitted ahead of a terminal delivery.

    Mirrors the push recipe in procmailrc: carbon-copy, best-effort, fires
    at most once per message via PUSH_ENQUEUED, but carries the REAL
    destination folder so a filed message buzzes with the right label. The
    file-level push recipe (after the user-rules include) is thereby
    suppressed for this message.
    '''
    return [
        '  :0c',
        '  * ! PUSH_ENQUEUED ?? yes',
        f'  | {PUSH_ENQUEUE} "$LOGNAME" "{label}"',
        '  PUSH_ENQUEUED=yes',
        '',
    ]


def delivery_path(dir_name):
    '''The action line delivering into a Maildir directory ('' = INBOX).'''
    return '  $DEFAULT' if dir_name == '' else f'  $MAILDIR/{dir_name}/'


def push_label(dir_name):
    '''The folder label the wake signal carries ('' = the Maildir root).'''
    return 'INBOX' if dir_name == '' else dir_name.lstrip('.')


def resolve_folder(folder, folder_exists):
    '''Returns (dir_name, None) or (None, skip_reason) for a folder target.'''
    dir_name = folder_to_dir(folder)
    if dir_name is None:
        return None, 'unsafe_folder'
    if not folder_exists(dir_name):
        return None, 'folder_not_found'
    return dir_name, None


def compile_rule(rule, folder_exists):
    '''Compiles one enabled rule into its recipe lines.

    Returns (lines, aux_skips, None) on success or (None, [], reason) when
    the whole rule is skipped. aux_skips lists per-rule auxiliary features
    that were requested but not compiled (logged, not fatal).
    '''
    reason = validate_rule(rule)
    if reason:
        return None, [], reason
    action = rule['action']
    # Reply is a primary effect (Phase 2c): compiling the rest of a reply
    # rule would consume the message's precedence without sending the reply
    # the rule exists for, so the whole rule skips until reply lands. Flag
    # and markRead (Phase 2b) are decorations - the rule still files or
    # forwards correctly without them, so only the aux is skipped.
    if rule.get('reply'):
        return None, [], 'aux_not_implemented:reply'
    aux_skips = [f'aux_not_implemented:{key}'
                 for key in ('flag', 'markRead') if rule.get(key)]

    forwards = [a for a in rule['forward']] if action != 'delete' else []
    dropped = [a for a in forwards if not valid_forward(a)]
    if dropped:
        aux_skips.append('forward_invalid_dropped')
    forwards = [a for a in forwards if valid_forward(a)]

    spill = rule['continueToNext'] and action != 'delete'
    body = []
    if forwards:
        body += ['  :0c', '  ! ' + ' '.join(forwards), '']

    if action in ('move', 'archive'):
        folder = 'Archive' if action == 'archive' else rule['moveFolder']
        if not folder:
            return None, [], 'folder_not_set'
        dir_name, reason = resolve_folder(folder, folder_exists)
        if reason:
            return None, [], reason
        if spill:
            body += ['  :0c:', delivery_path(dir_name)]
        else:
            body += push_block(push_label(dir_name))
            body += ['  :0:', delivery_path(dir_name)]
    elif action == 'delete':
        body += ['  :0', '  /dev/null']
    elif action == 'copy':
        if not rule['copyFolders']:
            return None, [], 'folder_not_set'
        copy_lines = []
        for folder in rule['copyFolders']:
            dir_name, reason = resolve_folder(folder, folder_exists)
            if reason:
                return None, [], reason
            copy_lines += ['  :0c:', delivery_path(dir_name), '']
        body += copy_lines
        if not spill:
            body += push_block('INBOX')
            body += ['  :0:', '  $DEFAULT']
        elif body and body[-1] == '':
            body.pop()
    else:  # 'none'
        if not spill:
            body += push_block('INBOX')
            body += ['  :0:', '  $DEFAULT']
        elif body and body[-1] == '':
            body.pop()

    if not body:
        return None, aux_skips, 'no_effect'
    lines = [f'# [{rule.get("id", "r-unknown")}] {rule["name"].strip()}', ':0']
    lines += condition_lines(rule['conditions'])
    lines += ['{'] + body + ['}', '']
    return lines, aux_skips, None


def compile_ruleset(user, rules, folder_exists):
    '''Compiles a user's whole rule set into their include-file content.

    Returns (content, compiled_count, skips) where skips is a list of
    (rule_id, reason) covering skipped rules AND per-rule aux notes.
    '''
    header = [
        '# Generated by compile-user-rules.py (docs/1.x/user-mail-rules-plan.md).',
        '# DO NOT EDIT - regenerated on every reconfigure.',
        f'# user: {user}',
        'LINEBUF=4096',
        '',
    ]
    lines = []
    compiled = 0
    skips = []
    if isinstance(rules, list) and len(rules) <= MAX_RULES:
        for rule in rules:
            rule_id = rule.get('id', 'r-unknown') if isinstance(rule, dict) else 'r-unknown'
            if isinstance(rule, dict) and rule.get('enabled') is False:
                continue
            rule_lines, aux_skips, reason = compile_rule(rule, folder_exists)
            skips += [(rule_id, aux) for aux in aux_skips]
            if reason:
                skips.append((rule_id, reason))
                continue
            lines += rule_lines
            compiled += 1
    elif rules:
        skips.append(('*', 'ruleset_invalid'))
    if not lines:
        return '\n'.join(header[:3] + ['# (no compiled rules)', '']), 0, skips
    return '\n'.join(header + lines), compiled, skips


def atomic_write(path, content):
    '''tmp + fsync + rename, world-readable (procmail runs as the user).'''
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.tmp.')
    try:
        os.write(fd, content.encode())
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def scan_rules_table():
    '''Scans cabal-user-rules via the CLI (matches generate-config.sh).

    Returns {user: raw rules JSON string}. The CLI auto-paginates.
    '''
    out = subprocess.run(
        ['aws', 'dynamodb', 'scan', '--table-name', TABLE_NAME,
         '--consistent-read', '--region', os.environ['AWS_REGION'],
         '--output', 'json'],
        check=True, capture_output=True, text=True).stdout
    rows = {}
    for item in json.loads(out).get('Items', []):
        user = item.get('user', {}).get('S', '')
        if user:
            rows[user] = item.get('rules', {}).get('S', '[]')
    return rows


def local_users():
    '''Users with a synced home + Maildir (the set procmail delivers for).'''
    try:
        entries = sorted(os.listdir(HOME_ROOT))
    except OSError:
        return []
    return [u for u in entries
            if os.path.isdir(os.path.join(HOME_ROOT, u, 'Maildir'))]


def emf(users_ok, rules_ok, rules_skipped, users_failed):
    '''One CloudWatch embedded-metric-format line for the run.'''
    print(json.dumps({
        '_aws': {
            'Timestamp': int(time.time() * 1000),
            'CloudWatchMetrics': [{
                'Namespace': 'Cabal/UserRules',
                'Dimensions': [[]],
                'Metrics': [{'Name': n, 'Unit': 'Count'} for n in
                            ('CompileOkUsers', 'CompiledRules',
                             'SkippedRules', 'FailedUsers')],
            }],
        },
        'CompileOkUsers': users_ok,
        'CompiledRules': rules_ok,
        'SkippedRules': rules_skipped,
        'FailedUsers': users_failed,
    }))


def main():
    '''Compiles every local user's rules; exits non-zero only on total failure.'''
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    rows = scan_rules_table()
    users = local_users()
    users_ok = rules_ok = rules_skipped = users_failed = 0
    for user in users:
        try:
            rules = json.loads(rows.get(user, '[]'))
        except ValueError as err:
            print(f'[compile-user-rules] compile_skip_user user={user} '
                  f'reason=rules_json_invalid ({err})')
            rules = []
            users_failed += 1

        def folder_exists(dir_name, _user=user):
            return dir_name == '' or os.path.isdir(
                os.path.join(HOME_ROOT, _user, 'Maildir', dir_name))

        content, compiled, skips = compile_ruleset(user, rules, folder_exists)
        for rule_id, reason in skips:
            print(f'[compile-user-rules] compile_skip_rule user={user} '
                  f'rule={rule_id} reason={reason}')
        try:
            atomic_write(os.path.join(OUTPUT_DIR, f'{user}.rc'), content)
        except OSError as err:
            print(f'[compile-user-rules] compile_skip_user user={user} '
                  f'reason=write_failed ({err})')
            users_failed += 1
            continue
        users_ok += 1
        rules_ok += compiled
        # aux_ and forward_invalid_dropped are per-rule warnings on rules
        # that still compiled; only whole-rule skips count here.
        rules_skipped += sum(
            1 for _, r in skips
            if not r.startswith('aux_') and r != 'forward_invalid_dropped')
        print(f'[compile-user-rules] compile_ok user={user} rules={compiled} '
              f'bytes={len(content)}')
    for user in sorted(set(rows) - set(users)):
        print(f'[compile-user-rules] compile_skip_user user={user} '
              f'reason=user_not_synced')
    emf(users_ok, rules_ok, rules_skipped, users_failed)
    print(f'[compile-user-rules] Done: {users_ok} users, {rules_ok} rules, '
          f'{rules_skipped} skipped.')


if __name__ == '__main__':
    sys.exit(main())
