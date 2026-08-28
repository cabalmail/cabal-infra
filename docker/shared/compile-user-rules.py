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

Auxiliary actions: flag / markRead (Phase 2b) deliver through the
cabal-maildir-deliver helper, which writes cur/ with the :2,<flags> info
suffix procmail's native maildir delivery cannot set; forward (2b) runs
through the cabal-rules-forward helper behind an X-Loop guard condition,
so a forward that routes back into the same mailbox is forwarded exactly
once (issue #1266); reply (2c) runs through the cabal-rules-reply helper
behind the bounce-suppression guard conditions, with the user's reply
body carried as an opaque base64 argv token - user text never appears as
procmail syntax, and base64's alphabet contains no SHELLMETAS, so the
recipe execs directly under SHELL=/usr/bin/false.

Pending decorations (docs/1.x/rules-composition-and-custom-flags-plan.md,
decision 3): a decorate-only rule - flag/markRead, destination none,
spill-through - compiles to per-message variable assignments (PENDING_F=F /
PENDING_S=S) instead of nothing. Once one has been emitted for a user, every
LATER delivery point becomes pending-aware: it folds the pending flags into
the helper argument via a per-delivery DFLAGS variable (own flags override
their slot, so F-then-S order and dedupe hold by construction and the value
is always '', F, S, or FS), keeping the native no-helper delivery for
undecorated messages behind a runtime DFLAGS condition. The file-level
inbox fallback lives in the procmailrc template, similarly runtime-guarded.
A rule set with no decorate-only rules compiles byte-identically to the
pre-decision-3 output.

Output is deterministic (no timestamps, sorted iteration) so the golden-file
self-test (compile-user-rules-selftest.py) can compare byte-for-byte.
'''
import base64
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
PREFS_TABLE_NAME = os.environ.get('USER_PREFERENCES_TABLE_NAME',
                                  'cabal-user-preferences')
PUSH_ENQUEUE = '/usr/local/bin/push-enqueue.sh'
DELIVER_HELPER = '/usr/local/bin/cabal-maildir-deliver.sh'
FORWARD_HELPER = '/usr/local/bin/cabal-rules-forward.sh'
REPLY_HELPER = '/usr/local/bin/cabal-rules-reply.sh'
MAX_REPLY_BODY_LENGTH = 4000

# OS usernames reach forward-helper argv and the X-Loop marker; sync-users
# creates them from Cognito usernames, but re-check the shape before
# emitting one into a recipe (skip-not-mangle, like everything else).
USER_SAFE_RE = re.compile(r'^[A-Za-z0-9._-]+$')

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
# Custom-flag slot atoms a rule may set (decision 6). Slots are re-validated
# against the user's palette at compile time (defense in depth behind
# set_rules; skip-not-mangle) - a rule referencing a slot that is missing
# from or disabled in the palette is skipped whole with flag_not_in_palette,
# exactly parallel to folder_not_found.
SLOT_RE = re.compile(r'^cabal-flag-(0[1-9]|1[0-9]|20)$')
MAX_RULE_FLAGS = 20
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
    flags_list = rule.get('flags', [])
    if not isinstance(flags_list, list) or len(flags_list) > MAX_RULE_FLAGS:
        return 'schema'
    for slot in flags_list:
        if not isinstance(slot, str) or not SLOT_RE.match(slot):
            return 'schema'
    copy_folders = rule.get('copyFolders')
    if not isinstance(copy_folders, list) or len(copy_folders) > MAX_COPY_FOLDERS:
        return 'schema'
    forwards = rule.get('forward')
    if not isinstance(forwards, list) or len(forwards) > MAX_FORWARDS:
        return 'schema'
    if rule.get('reply'):
        body = rule.get('replyBody')
        if (not isinstance(body, str) or not 1 <= len(body) <= MAX_REPLY_BODY_LENGTH
                or any((ord(ch) < 32 and ch != '\n') or ord(ch) == 127
                       for ch in body)):
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


def deliver_block(dir_name, flags, copy, pending=False, pending_kw=False,
                  keywords=()):
    '''Delivery recipe lines for one maildir target, flagged or plain.

    Unflagged targets keep procmail's native maildir delivery. Flagged
    targets pipe through cabal-maildir-deliver, which writes cur/ with the
    :2,<flags> suffix; the `w` flag makes procmail read the helper's exit
    status, so a helper failure leaves the message for later recipes /
    DEFAULT instead of losing it.

    With `pending` (a decorate-only flag/markRead rule was emitted earlier
    in this set), the delivery folds `PENDING_F`/`PENDING_S` in via a
    per-delivery DFLAGS variable rather than mutating the pending state
    itself - a spill copy's own flags must decorate the copy only, never
    leak into later rules. An undecorated message still takes the native
    no-helper path behind a runtime condition; own FS needs no folding
    (both slots are already saturated) and keeps the constant-argument
    shape.

    Custom-flag slots (decision 6) extend the same design: `keywords` are
    the rule's own slot atoms, `pending_kw` marks that an earlier
    decorate-only rule may have armed `PENDING_KW`, and either routes the
    delivery through the helper's four-argument APPEND form (flags, IMAP
    folder name, comma-joined keywords). When no keywords are possible the
    Phase 2 shapes are emitted byte-for-byte.
    '''
    target = '"$MAILDIR"' if dir_name == '' else f'"$MAILDIR/{dir_name}"'
    if not pending_kw and not keywords:
        # Phase 2 shapes, byte-identical (the no-keywords golden prefix).
        if not pending or flags == 'FS':
            if not flags:
                return ['  :0c:' if copy else '  :0:', delivery_path(dir_name)]
            return ['  :0cw' if copy else '  :0w',
                    f'  | {DELIVER_HELPER} {target} {flags}']
        assign = {'F': '  DFLAGS=F$PENDING_S',
                  'S': '  DFLAGS=${PENDING_F}S',
                  '': '  DFLAGS=$PENDING_F$PENDING_S'}[flags]
        helper_line = f'  | {DELIVER_HELPER} {target} "$DFLAGS"'
        if flags:
            # DFLAGS is non-empty by construction: the helper always delivers.
            return [assign, '  :0cw' if copy else '  :0w', helper_line]
        native = ['  :0c:' if copy else '  :0:', '  * ! DFLAGS ?? .',
                  delivery_path(dir_name)]
        helper = ['  :0cw' if copy else '  :0w']
        if copy:
            # A copy recipe continues after delivering, so the two recipes
            # need mutually exclusive conditions; a terminal pair does not
            # (the second is only reached when the first did not deliver).
            helper.append('  * DFLAGS ?? .')
        helper.append(helper_line)
        return [assign] + native + [''] + helper

    # Keyword-capable delivery: the helper's APPEND form.
    lines = []
    if pending and flags != 'FS':
        lines.append({'F': '  DFLAGS=F$PENDING_S',
                      'S': '  DFLAGS=${PENDING_F}S',
                      '': '  DFLAGS=$PENDING_F$PENDING_S'}[flags])
        flags_arg = '"$DFLAGS"'
    else:
        flags_arg = f'"{flags}"'
    own = ','.join(keywords)
    if pending_kw:
        # Own slots override nothing (unions dedupe at the drain); the
        # ${VAR:+} idiom keeps the comma out when nothing is pending.
        if own:
            lines.append(f'  KWFLAGS={own}${{PENDING_KW:+,${{PENDING_KW}}}}')
        else:
            lines.append('  KWFLAGS=$PENDING_KW')
        kw_arg = '"$KWFLAGS"'
    else:
        kw_arg = f'"{own}"'
    helper_line = (f'  | {DELIVER_HELPER} {target} {flags_arg} '
                   f'"{push_label(dir_name)}" {kw_arg}')
    if keywords or flags:
        # Own decoration of any kind: the delivery is always decorated, so
        # the helper runs unconditionally (the APPEND path when keywords
        # end up non-empty, the raw write when only flags do).
        return lines + ['  :0cw' if copy else '  :0w', helper_line]
    # Nothing own: keep the native path for messages no decorator matched.
    # Emptiness of EITHER pending kind must route to the helper, and
    # procmail conditions AND, so a combined sentinel provides the OR.
    if pending:
        lines.append('  PENDINGANY=${DFLAGS}${KWFLAGS}')
        gate = 'PENDINGANY'
    else:
        gate = 'KWFLAGS'
    native = ['  :0c:' if copy else '  :0:', f'  * ! {gate} ?? .',
              delivery_path(dir_name)]
    helper = ['  :0cw' if copy else '  :0w']
    if copy:
        helper.append(f'  * {gate} ?? .')
    helper.append(helper_line)
    return lines + native + [''] + helper


def pending_assignments(flags, keywords=()):
    '''A decorate-only rule's body: arm the per-message pending state.

    Assignment blocks are non-terminal and create no copy; every later
    delivery point (and the procmailrc inbox fallback) folds the variables
    into its flags/keywords arguments. Procmail runs once per message, so
    per-message isolation of the variables is free. Keywords append with
    the ${VAR:+} idiom so multiple decorators accumulate.
    '''
    lines = []
    if 'F' in flags:
        lines.append('  PENDING_F=F')
    if 'S' in flags:
        lines.append('  PENDING_S=S')
    if keywords:
        joined = ','.join(keywords)
        lines.append(f'  PENDING_KW=${{PENDING_KW:+${{PENDING_KW}},}}{joined}')
    return lines


def arms_pending(rule):
    '''True for a validated decorate-only rule setting flag/markRead:
    destination none, spill-through. Compiling one makes every later
    delivery in the set fold PENDING_F/PENDING_S in.'''
    return (rule['action'] == 'none' and rule['continueToNext']
            and bool(rule.get('flag') or rule.get('markRead')))


def arms_pending_kw(rule):
    '''True for a validated decorate-only rule setting custom-flag slots:
    every later delivery must fold PENDING_KW in (and route through the
    helper's APPEND form when it ends up non-empty).'''
    return (rule['action'] == 'none' and rule['continueToNext']
            and bool(rule.get('flags')))


def reply_block(user, body):
    '''The guarded auto-reply recipe (Phase 2c).

    The condition set is the plan's bounce-suppression guard, baked into
    every compiled reply recipe and not user-controlled: never answer
    anything auto-generated, bulk/list traffic, mailer daemons, our own
    marker, or a message with no usable From. The helper owns the
    vacation cache, rate cap, and composition; the body rides as an
    opaque base64 token.
    '''
    marker = escape_value(f'X-Loop: cabal-rules-{user}')
    blob = base64.b64encode(body.encode()).decode()
    return [
        '  :0cw',
        '  * ! ^Auto-Submitted:',
        '  * ! ^Precedence:.*(bulk|junk|list)',
        '  * ! ^List-Id:',
        '  * ! ^X-Mailer-Daemon:',
        '  * ! ^From:.*MAILER-DAEMON',
        f'  * ! ^{marker}',
        '  * ^From:.',
        f'  | {REPLY_HELPER} {user} {blob}',
        '',
    ]


def forward_block(user, forwards):
    '''The guarded forward recipe (Phase 2b; issue #1266).

    The condition skips messages already stamped with this user's X-Loop
    marker; the helper stamps the outbound copy - together they bound any
    forward cycle through this mailbox to a single hop.
    '''
    marker = escape_value(f'X-Loop: cabal-rules-{user}')
    return ['  :0cw',
            f'  * ! ^{marker}',
            f'  | {FORWARD_HELPER} {user} ' + ' '.join(forwards),
            '']


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


def compile_rule(rule, folder_exists, user, pending_possible=False,
                 pending_kw=False, palette_slots=frozenset()):
    '''Compiles one enabled rule into its recipe lines.

    Returns (lines, aux_skips, None) on success or (None, [], reason) when
    the whole rule is skipped. aux_skips lists per-rule auxiliary notes
    (dropped forwards, unimplemented aux) that are logged but not fatal.
    `pending_possible` marks that a decorate-only flag/markRead rule was
    already emitted for this user (fold PENDING_F/PENDING_S in);
    `pending_kw` the same for custom-flag slots (fold PENDING_KW in).
    `palette_slots` is the user's ENABLED palette slot set - a rule
    referencing anything else is skipped whole (flag_not_in_palette,
    decision 6), exactly parallel to folder_not_found.
    '''
    reason = validate_rule(rule)
    if reason:
        return None, [], reason
    action = rule['action']
    # Reply and forward emit the username into recipes; an unexpected
    # shape skips the whole rule (skip-not-mangle).
    if (rule.get('reply') or rule.get('forward')) and not USER_SAFE_RE.match(user):
        if rule.get('reply'):
            return None, [], 'user_unsafe'
    aux_skips = []
    # Maildir info flags for this rule's own deliveries (sorted: F < S).
    flags = ('F' if rule.get('flag') else '') + ('S' if rule.get('markRead') else '')
    # Custom-flag slots, deduped into deterministic slot order (zero-padded
    # atoms sort lexicographically). Slot atoms are fixed safe strings, so
    # the argv surface stays trivial (decision 6).
    keywords = tuple(sorted(set(rule.get('flags') or [])))
    if action == 'delete':
        flags = ''
        keywords = ()
    if any(slot not in palette_slots for slot in keywords):
        return None, aux_skips, 'flag_not_in_palette'

    forwards = list(rule['forward']) if action != 'delete' else []
    dropped = [a for a in forwards if not valid_forward(a)]
    if dropped:
        aux_skips.append('forward_invalid_dropped')
    forwards = [a for a in forwards if valid_forward(a)]
    if forwards and not USER_SAFE_RE.match(user):
        aux_skips.append('forward_user_unsafe')
        forwards = []

    spill = rule['continueToNext'] and action != 'delete'
    body = []
    if forwards:
        body += forward_block(user, forwards)
    # Settled decision 2: forward fires before reply (the forward target
    # sees the original, not the auto-reply); reply before the destination.
    if rule.get('reply') and action != 'delete':
        body += reply_block(user, rule['replyBody'])

    if action in ('move', 'archive'):
        folder = 'Archive' if action == 'archive' else rule['moveFolder']
        if not folder:
            return None, [], 'folder_not_set'
        dir_name, reason = resolve_folder(folder, folder_exists)
        if reason:
            return None, [], reason
        if spill:
            body += deliver_block(dir_name, flags, copy=True,
                                  pending=pending_possible,
                                  pending_kw=pending_kw, keywords=keywords)
        else:
            body += push_block(push_label(dir_name))
            body += deliver_block(dir_name, flags, copy=False,
                                  pending=pending_possible,
                                  pending_kw=pending_kw, keywords=keywords)
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
            copy_lines += deliver_block(dir_name, flags, copy=True,
                                        pending=pending_possible,
                                        pending_kw=pending_kw,
                                        keywords=keywords) + ['']
        body += copy_lines
        if not spill:
            body += push_block('INBOX')
            body += deliver_block('', flags, copy=False,
                                  pending=pending_possible,
                                  pending_kw=pending_kw, keywords=keywords)
        elif body and body[-1] == '':
            body.pop()
    else:  # 'none'
        if not spill:
            body += push_block('INBOX')
            body += deliver_block('', flags, copy=False,
                                  pending=pending_possible,
                                  pending_kw=pending_kw, keywords=keywords)
        elif flags or keywords:
            # Decorate-only (decision 3): arm the pending state instead of
            # compiling to nothing.
            body += pending_assignments(flags, keywords)
        elif body and body[-1] == '':
            body.pop()

    if not body:
        return None, aux_skips, 'no_effect'
    lines = [f'# [{rule.get("id", "r-unknown")}] {rule["name"].strip()}', ':0']
    lines += condition_lines(rule['conditions'])
    lines += ['{'] + body + ['}', '']
    return lines, aux_skips, None


def compile_ruleset(user, rules, folder_exists, palette_slots=frozenset()):
    '''Compiles a user's whole rule set into their include-file content.

    Returns (content, compiled_count, skips) where skips is a list of
    (rule_id, reason) covering skipped rules AND per-rule aux notes.
    `palette_slots` is the user's enabled custom-flag slot set (decision 6).
    '''
    header = [
        '# Generated by compile-user-rules.py (docs/1.x/user-mail-rules-plan.md).',
        '# DO NOT EDIT - regenerated on every reconfigure.',
        f'# user: {user}',
        # Reply recipes carry the base64 body inline (<= ~5.4 KB for the
        # 4000-char cap); keep well clear of the longest legal line.
        'LINEBUF=16384',
        '',
    ]
    lines = []
    compiled = 0
    skips = []
    # Set once a decorate-only rule compiles: every later delivery in this
    # set must fold the pending flags in. Stays False for sets without
    # decorators, keeping their output byte-identical to the prior shape.
    pending_possible = False
    pending_kw = False
    if isinstance(rules, list) and len(rules) <= MAX_RULES:
        for rule in rules:
            rule_id = rule.get('id', 'r-unknown') if isinstance(rule, dict) else 'r-unknown'
            if isinstance(rule, dict) and rule.get('enabled') is False:
                continue
            rule_lines, aux_skips, reason = compile_rule(
                rule, folder_exists, user, pending_possible, pending_kw,
                palette_slots)
            skips += [(rule_id, aux) for aux in aux_skips]
            if reason:
                skips.append((rule_id, reason))
                continue
            lines += rule_lines
            compiled += 1
            if arms_pending(rule):
                pending_possible = True
            if arms_pending_kw(rule):
                pending_kw = True
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
    result = subprocess.run(
        ['aws', 'dynamodb', 'scan', '--table-name', TABLE_NAME,
         '--consistent-read', '--region', os.environ['AWS_REGION'],
         '--output', 'json'],
        check=False, capture_output=True, text=True)
    if result.returncode != 0:
        # Surface the CLI's stderr (AccessDenied, throttling, ...) - a bare
        # CalledProcessError hides the reason the scan failed.
        raise RuntimeError(
            f'dynamodb scan failed (exit {result.returncode}): '
            f'{result.stderr.strip()[-500:]}')
    out = result.stdout
    rows = {}
    for item in json.loads(out).get('Items', []):
        user = item.get('user', {}).get('S', '')
        if user:
            rows[user] = item.get('rules', {}).get('S', '[]')
    return rows


def scan_preferences_table():
    '''Scans cabal-user-preferences for palettes (decision 6).

    Returns {user: raw flag_palette JSON string}. A scan failure is
    tolerated with a warning and an empty map - every keyworded rule then
    skips with flag_not_in_palette (fail closed, skip-not-mangle) while
    ordinary rules keep compiling; palette-less users are the common case
    and cost nothing.
    '''
    result = subprocess.run(
        ['aws', 'dynamodb', 'scan', '--table-name', PREFS_TABLE_NAME,
         '--projection-expression', '#u, app.flag_palette',
         '--expression-attribute-names', '{"#u": "user"}',
         '--region', os.environ['AWS_REGION'], '--output', 'json'],
        check=False, capture_output=True, text=True)
    if result.returncode != 0:
        print('[compile-user-rules] preferences scan failed '
              f'(exit {result.returncode}): {result.stderr.strip()[-300:]}')
        return {}
    rows = {}
    for item in json.loads(result.stdout).get('Items', []):
        user = item.get('user', {}).get('S', '')
        raw = item.get('app', {}).get('M', {}).get('flag_palette', {}).get('S', '')
        if user and raw:
            rows[user] = raw
    return rows


def palette_enabled_slots(raw):
    '''The enabled slot atoms of one palette JSON string, as a frozenset.

    Tolerant of malformed values (set_preferences validates writes, but the
    compiler trusts nothing): anything unparseable reads as an empty
    palette, so keyworded rules skip rather than compile against garbage.
    '''
    try:
        entries = json.loads(raw)
    except (TypeError, ValueError):
        return frozenset()
    if not isinstance(entries, list):
        return frozenset()
    return frozenset(
        entry['slot'] for entry in entries
        if isinstance(entry, dict) and isinstance(entry.get('slot'), str)
        and SLOT_RE.match(entry['slot']) and entry.get('enabled', True) is True)


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
    palettes = scan_preferences_table()
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

        content, compiled, skips = compile_ruleset(
            user, rules, folder_exists,
            palette_enabled_slots(palettes.get(user, '')))
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
        # aux_* and forward_* are per-rule warnings on rules that still
        # compiled; only whole-rule skips count here.
        rules_skipped += sum(
            1 for _, r in skips
            if not r.startswith('aux_') and not r.startswith('forward_'))
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
