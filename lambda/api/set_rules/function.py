'''Validates and stores the current user's mail rules
(docs/1.x/user-mail-rules-plan.md, Phase 1).

The whole ordered rule set arrives as one array and is written as one
whole-row replacement: array index is precedence, so there are no per-rule
ordinals to renumber and a reorder is a single PUT. `expectedVersion` carries
optimistic concurrency - a stale writer gets a 409 and reloads rather than
interleaving two orderings.

Every successful write also appends a JSON-Patch diff to the audit table
(operator incident response; TTL-pruned) and publishes to the user-rules SNS
topic so the imap tier's reconfigure loop picks the change up. Both are
best-effort AFTER the committed write: the periodic reconfigure fallback
covers a lost publish, and a lost audit row must not fail a write that has
already happened.

Validation here is the write-time layer only. Folder targets are NOT checked
against the user's IMAP folder list (the user may create the folder right
after saving); the compiler re-verifies at compile time and skips rules whose
folder is gone. The response's `warnings` field names every accepted-but-
unverified folder target so clients can surface it.
'''
import json
import os
import re
import secrets
import time
from datetime import datetime, timezone

import boto3  # pylint: disable=import-error
from botocore.exceptions import ClientError  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
sns = boto3.client('sns')
TABLE_NAME = os.environ.get('USER_RULES_TABLE_NAME', 'cabal-user-rules')
AUDIT_TABLE_NAME = os.environ.get('USER_RULES_AUDIT_TABLE_NAME', 'cabal-user-rules-audit')
TOPIC_ARN = os.environ.get('USER_RULES_TOPIC_ARN', '')
table = ddb.Table(TABLE_NAME)
audit_table = ddb.Table(AUDIT_TABLE_NAME)

MAX_RULES = 100
MAX_NAME_LENGTH = 100
MAX_CONDITIONS = 10
MAX_VALUE_LENGTH = 500
MAX_FORWARDS = 10
MAX_COPY_FOLDERS = 10
MAX_ADDRESS_LENGTH = 320   # RFC 5321 forward/reverse-path bound
MAX_REPLY_BODY_LENGTH = 4000
MAX_FOLDER_LENGTH = 255
# Well under the 400 KB DynamoDB item cap even with the version/updatedAt
# attributes alongside; a limit the validation caps above make unreachable in
# practice, kept as a backstop against pathological inputs.
MAX_RULES_BYTES = 300_000
AUDIT_RETENTION_SECONDS = 90 * 24 * 3600

FIELDS = {'from', 'to', 'cc', 'subject', 'body'}
ACTIONS = {'move', 'copy', 'delete', 'archive', 'none'}
FORWARD_RE = re.compile(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
RULE_ID_RE = re.compile(r'^r-[0-9a-f]{12}$')
BOOL_KEYS = ('enabled', 'flag', 'markRead', 'reply', 'continueToNext')
# Custom-flag slots a rule may set at delivery
# (docs/1.x/rules-composition-and-custom-flags-plan.md, decision 6). Shape is
# enforced hard here; palette membership is a WARNING, not an error, exactly
# like folder targets: a palette edit after the rule was saved must not wedge
# every subsequent whole-set save, and the compiler is the enforcement point
# (flag_not_in_palette skip). The legacy `flag` boolean stays alongside,
# meaning the system \Flagged, accepted indefinitely.
SLOT_RE = re.compile(r'^cabal-flag-(0[1-9]|1[0-9]|20)$')
MAX_RULE_FLAGS = 20
DEFAULTS = {
    'name': '',
    'enabled': True,
    'conditions': [],
    'action': 'none',
    'moveFolder': '',
    'copyFolders': [],
    'flag': False,
    'flags': [],
    'markRead': False,
    'forward': [],
    'reply': False,
    'replyBody': '',
    'continueToNext': False,
}

# Characters that are procmail- or shell-meaningful and must never appear in a
# folder target regardless of the compiler's later escaping (defense in depth;
# see the plan's security model, Layer 1). Control characters are rejected
# separately by _bad_controls.
FOLDER_FORBIDDEN = set('|>`')


def _bad_controls(value, allow=''):
    '''True if the string contains control characters outside the allow set.'''
    return any((ord(ch) < 32 and ch not in allow) or ord(ch) == 127 for ch in value)


def _folder_error(value):
    '''Returns a client-facing message if the folder target is invalid, else None.

    Empty is allowed - a rule may be saved with its destination not yet picked
    (the templates do exactly that, disabled until a folder is chosen).
    '''
    if not isinstance(value, str):
        return 'Folder must be a string.'
    if value == '':
        return None
    if len(value) > MAX_FOLDER_LENGTH:
        return f'Folder name exceeds {MAX_FOLDER_LENGTH} characters.'
    if _bad_controls(value) or FOLDER_FORBIDDEN & set(value):
        return 'Folder name contains a forbidden character.'
    if value.startswith('/') or '..' in value:
        return 'Folder name must be a relative path without "..".'
    return None


def _condition_errors(conditions):
    '''Validates the conditions list; returns a list of (field, message).'''
    errors = []
    if not isinstance(conditions, list):
        return [('conditions', 'Must be a list.')]
    if len(conditions) > MAX_CONDITIONS:
        return [('conditions', f'At most {MAX_CONDITIONS} conditions per rule.')]
    for i, cond in enumerate(conditions):
        where = f'conditions[{i}]'
        if not isinstance(cond, dict) or set(cond) != {'field', 'value'}:
            errors.append((where, 'Each condition needs exactly field and value.'))
            continue
        if cond['field'] not in FIELDS:
            errors.append((f'{where}.field', 'Unknown field.'))
        value = cond['value']
        if (not isinstance(value, str) or not 1 <= len(value) <= MAX_VALUE_LENGTH
                or _bad_controls(value)):
            errors.append((f'{where}.value',
                           f'Must be 1-{MAX_VALUE_LENGTH} characters, no control characters.'))
    return errors


def _scalar_errors(rule):
    '''Validates a rule's non-collection fields; returns a list of (field, message).'''
    errors = []
    name = rule['name']
    if (not isinstance(name, str) or not 1 <= len(name.strip()) <= MAX_NAME_LENGTH
            or _bad_controls(name)):
        errors.append(('name', f'Must be 1-{MAX_NAME_LENGTH} characters, no control characters.'))
    for key in BOOL_KEYS:
        if not isinstance(rule[key], bool):
            errors.append((key, 'Must be a boolean.'))
    if rule['action'] not in ACTIONS:
        errors.append(('action', 'Unknown action.'))
    folder_error = _folder_error(rule['moveFolder'])
    if folder_error:
        errors.append(('moveFolder', folder_error))
    body = rule['replyBody']
    if not isinstance(body, str) or len(body) > MAX_REPLY_BODY_LENGTH or _bad_controls(body, '\n'):
        errors.append(
            ('replyBody', f'Must be at most {MAX_REPLY_BODY_LENGTH} characters; newlines only.'))
    elif rule['reply'] is True and body == '':
        errors.append(('replyBody', 'Required when reply is on.'))
    return errors


def _rule_flags_errors(flags):
    '''Validates the custom-flag slot list; returns a list of (field, message).

    Slot atoms only, unique, bounded. Whether a slot is (still) in the
    user's palette is deliberately not checked here — see SLOT_RE's comment.
    '''
    if not isinstance(flags, list):
        return [('flags', 'Must be a list.')]
    if len(flags) > MAX_RULE_FLAGS:
        return [('flags', f'At most {MAX_RULE_FLAGS} flags per rule.')]
    errors = []
    seen = set()
    for i, slot in enumerate(flags):
        if not isinstance(slot, str) or not SLOT_RE.match(slot):
            errors.append((f'flags[{i}]', 'Unknown flag slot.'))
        elif slot in seen:
            errors.append((f'flags[{i}]', 'Duplicate flag slot.'))
        else:
            seen.add(slot)
    return errors


def _copy_folder_errors(folders):
    '''Validates the copyFolders list; returns a list of (field, message).'''
    if not isinstance(folders, list):
        return [('copyFolders', 'Must be a list.')]
    if len(folders) > MAX_COPY_FOLDERS:
        return [('copyFolders', f'At most {MAX_COPY_FOLDERS} copy targets per rule.')]
    errors = []
    for i, folder in enumerate(folders):
        folder_error = _folder_error(folder)
        if folder_error is None and folder == '':
            folder_error = 'Copy target must not be empty.'
        if folder_error:
            errors.append((f'copyFolders[{i}]', folder_error))
    return errors


def _clean_forwards(forwards):
    '''Splits a forward list into (valid, stripped).

    Invalid entries are stripped rather than rejected - the editors allow
    half-typed chips locally, and the plan has the API drop them at PUT time
    and surface what it dropped. Anything non-string is stripped too.
    '''
    if not isinstance(forwards, list):
        return None, None
    valid, stripped = [], []
    for addr in forwards:
        if (isinstance(addr, str) and len(addr) <= MAX_ADDRESS_LENGTH
                and FORWARD_RE.match(addr) and not _bad_controls(addr)):
            valid.append(addr)
        else:
            stripped.append(addr if isinstance(addr, str) else repr(addr))
    return valid[:MAX_FORWARDS], stripped


def _normalize_rules(rules_in):
    '''Validates and canonicalizes the incoming rule array.

    Returns (rules, errors, stripped): the canonical rule dicts (schema keys
    only, server-assigned ids), the structured validation errors, and the
    invalid forward chips dropped per rule. `rules` is meaningful only when
    `errors` is empty.
    '''
    rules, errors, stripped, seen_ids = [], [], [], set()
    for index, rule_in in enumerate(rules_in):
        if not isinstance(rule_in, dict):
            errors.append({'rule': index, 'field': '', 'error': 'Rule must be an object.'})
            continue
        rule_errors = []
        for key in rule_in:
            if key not in DEFAULTS and key != 'id':
                rule_errors.append((key, 'Unknown field.'))
        rule = {key: rule_in.get(key, default) for key, default in DEFAULTS.items()}
        rule_errors += _scalar_errors(rule)
        rule_errors += _condition_errors(rule['conditions'])
        rule_errors += _copy_folder_errors(rule['copyFolders'])
        rule_errors += _rule_flags_errors(rule['flags'])
        forwards, dropped = _clean_forwards(rule['forward'])
        if forwards is None:
            rule_errors.append(('forward', 'Must be a list.'))
        else:
            rule['forward'] = forwards
            if dropped:
                stripped.append({'rule': index, 'forward': dropped})
        # Ids are server-assigned: keep a well-formed, unseen client id (so
        # edits are stable across saves), mint a fresh one otherwise.
        rule_id = rule_in.get('id', '')
        if not isinstance(rule_id, str) or not RULE_ID_RE.match(rule_id) or rule_id in seen_ids:
            rule_id = 'r-' + secrets.token_hex(6)
        seen_ids.add(rule_id)
        rule['id'] = rule_id
        errors += [{'rule': index, 'field': field, 'error': message}
                   for field, message in rule_errors]
        rules.append(rule)
    return rules, errors, stripped


def _folder_warnings(rules):
    '''Names every folder target accepted without verification (see module doc).'''
    warnings = []
    for rule in rules:
        targets = [('moveFolder', rule['moveFolder'])] if rule['moveFolder'] else []
        targets += [('copyFolders', folder) for folder in rule['copyFolders']]
        warnings += [{'rule': rule['id'], 'field': field, 'folder': folder,
                      'warning': 'folder_not_verified_until_compile'}
                     for field, folder in targets]
    return warnings


def _json_patch(old, new):
    '''A JSON Patch (RFC 6902) turning the old rules array into the new one.'''
    ops = []
    for i in range(min(len(old), len(new))):
        if old[i] != new[i]:
            ops.append({'op': 'replace', 'path': f'/rules/{i}', 'value': new[i]})
    for i in range(len(old), len(new)):
        ops.append({'op': 'add', 'path': f'/rules/{i}', 'value': new[i]})
    for i in range(len(old) - 1, len(new) - 1, -1):
        ops.append({'op': 'remove', 'path': f'/rules/{i}'})
    return ops


def _parse_request(event):
    '''Returns (rules, expected_version) or raises ValueError with a 400 message.'''
    try:
        body = json.loads(event.get('body') or '{}')
    except (TypeError, ValueError) as err:
        raise ValueError('Invalid JSON body.') from err
    rules = body.get('rules')
    expected = body.get('expectedVersion')
    if not isinstance(rules, list):
        raise ValueError('rules must be a list.')
    if len(rules) > MAX_RULES:
        raise ValueError(f'At most {MAX_RULES} rules.')
    if isinstance(expected, bool) or not isinstance(expected, int) or expected < 0:
        raise ValueError('expectedVersion must be a non-negative integer.')
    return rules, expected


def _write_row(user, serialized, expected, updated_at):
    '''Commits the whole-row replacement guarded by the version condition.

    A first-ever write (expected 0) must find no versioned row; any later
    write must find exactly the version the client saw. Raises
    ClientError(ConditionalCheckFailedException) on a lost race.
    '''
    if expected == 0:
        condition = 'attribute_not_exists(#v)'
        values = {':r': serialized, ':v': 1, ':t': updated_at}
    else:
        condition = '#v = :ev'
        values = {':r': serialized, ':v': expected + 1, ':t': updated_at, ':ev': expected}
    table.update_item(
        Key={'user': user},
        UpdateExpression='SET #r = :r, #v = :v, #t = :t',
        ConditionExpression=condition,
        ExpressionAttributeNames={'#r': 'rules', '#v': 'version', '#t': 'updatedAt'},
        ExpressionAttributeValues=values,
    )


def _record_side_effects(user, prior_rules, rules, version):
    '''Audit row + SNS fan-out, best-effort after the committed write.'''
    now = time.time()
    try:
        audit_table.put_item(Item={
            'user': user,
            'ts': int(now * 1000),
            'version': version,
            'diff': json.dumps(_json_patch(prior_rules, rules)),
            'expiresAt': int(now) + AUDIT_RETENTION_SECONDS,
        })
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'[set_rules] audit write failed for {user}: {err}')
    try:
        sns.publish(TopicArn=TOPIC_ARN,
                    Message=json.dumps({'user': user, 'version': version}))
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'[set_rules] SNS publish failed for {user}: {err}')


def _error_response(err, prior_version):
    '''Maps a storage exception to the client response: 409 on a lost
    optimistic-concurrency race, 500 on anything else.'''
    if (isinstance(err, ClientError)
            and err.response['Error']['Code'] == 'ConditionalCheckFailedException'):
        return {
            'statusCode': 409,
            'body': json.dumps({'Error': 'Rules changed on another device; reload.',
                                'version': prior_version})
        }
    return {'statusCode': 500, 'body': json.dumps({'Error': str(err)})}


def handler(event, _context):
    '''Validates and stores the caller's rule set with optimistic concurrency.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    prior = {}
    try:
        rules_in, expected = _parse_request(event)
    except ValueError as err:
        return {'statusCode': 400, 'body': json.dumps({'Error': str(err)})}
    rules, errors, stripped = _normalize_rules(rules_in)
    if errors:
        return {'statusCode': 400, 'body': json.dumps({'errors': errors})}
    serialized = json.dumps(rules)
    if len(serialized) > MAX_RULES_BYTES:
        return {'statusCode': 400, 'body': json.dumps({'Error': 'Rule set too large.'})}
    updated_at = datetime.now(timezone.utc).isoformat()
    try:
        # Prior state read consistently for the audit diff; the conditional
        # write below is what actually guards the version race.
        prior = table.get_item(Key={'user': user}, ConsistentRead=True).get('Item', {})
        prior_rules = json.loads(prior.get('rules', '[]'))
        _write_row(user, serialized, expected, updated_at)
    except Exception as err:  # pylint: disable=broad-exception-caught
        return _error_response(err, int(prior.get('version', 0)))
    _record_side_effects(user, prior_rules, rules, expected + 1)
    return {
        'statusCode': 200,
        'body': json.dumps({
            'rules': rules,
            'version': expected + 1,
            'updatedAt': updated_at,
            'stripped': stripped,
            'warnings': _folder_warnings(rules),
        })
    }
