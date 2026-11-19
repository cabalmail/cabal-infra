'''Validates and stores the current user's rules: the mail rules
(docs/1.x/user-mail-rules-plan.md, Phase 1) and the feed rules beside them
(docs/1.x/cross-media-ux-plan.md, Phase 4).

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

Feed rules are a second list, `feedRules`, in the same row and under the same
version, so there is one conflict story for both. The key is optional: a
request without it leaves the stored list as it is, which is what every
client that predates feed rules sends, so a save from one can neither see
nor lose a feed rule. A request that carries it replaces the list whole, as
`rules` always is. The mail compiler reads only `rules`; feed rules are
applied by the fetch worker when it inserts an item (rss_fetch, rss_rules).
Only a save that changes the mail rules is published to the imap tier.
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
MAX_FEED_RULES = 100
# The two lists share one DynamoDB item (400 KB). Each has its own cap
# rather than one for the pair, so a save that sends only `rules` can be
# judged without reading what `feedRules` holds, and the two caps together
# stay under the item limit. A feed rule has no reply body or folder list,
# so this is room for a full list of long ones.
MAX_FEED_RULES_BYTES = 60_000
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

# A feed rule decorates a newly fetched feed item: it has conditions and the
# three decoration actions a mail rule has, and no destination, forward,
# reply or continue (nothing is filed, so every matching rule applies).
# rss_rules.FIELDS is the reader's copy of FEED_FIELDS; a test holds the two
# together.
FEED_FIELDS = {'feed', 'title', 'author', 'summary'}
FEED_BOOL_KEYS = ('enabled', 'flag', 'markRead')
FEED_DEFAULTS = {
    'name': '',
    'enabled': True,
    'conditions': [],
    'flag': False,
    'flags': [],
    'markRead': False,
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


def _condition_errors(conditions, fields=None):
    '''Validates the conditions list; returns a list of (field, message).
    `fields` is the set of condition fields the rule's kind allows (a mail
    rule's by default).'''
    fields = FIELDS if fields is None else fields
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
        if cond['field'] not in fields:
            errors.append((f'{where}.field', 'Unknown field.'))
        value = cond['value']
        if (not isinstance(value, str) or not 1 <= len(value) <= MAX_VALUE_LENGTH
                or _bad_controls(value)):
            errors.append((f'{where}.value',
                           f'Must be 1-{MAX_VALUE_LENGTH} characters, no control characters.'))
    return errors


def _name_and_bool_errors(rule, bool_keys):
    '''Validates a rule's name and its boolean fields; returns a list of
    (field, message). Shared by mail and feed rules.'''
    errors = []
    name = rule['name']
    if (not isinstance(name, str) or not 1 <= len(name.strip()) <= MAX_NAME_LENGTH
            or _bad_controls(name)):
        errors.append(('name', f'Must be 1-{MAX_NAME_LENGTH} characters, no control characters.'))
    for key in bool_keys:
        if not isinstance(rule[key], bool):
            errors.append((key, 'Must be a boolean.'))
    return errors


def _scalar_errors(rule):
    '''Validates a rule's non-collection fields; returns a list of (field, message).'''
    errors = _name_and_bool_errors(rule, BOOL_KEYS)
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
        rule['id'] = _assign_id(rule_in, seen_ids)
        errors += [{'rule': index, 'field': field, 'error': message}
                   for field, message in rule_errors]
        rules.append(rule)
    return rules, errors, stripped


def _assign_id(rule_in, seen_ids):
    '''The id a rule is stored under. Ids are server-assigned: keep a
    well-formed, unseen client id (so edits are stable across saves), mint a
    fresh one otherwise. Adds it to `seen_ids`.'''
    rule_id = rule_in.get('id', '')
    if not isinstance(rule_id, str) or not RULE_ID_RE.match(rule_id) or rule_id in seen_ids:
        rule_id = 'r-' + secrets.token_hex(6)
    seen_ids.add(rule_id)
    return rule_id


def _feed_condition_errors(conditions):
    '''Validates a feed rule's conditions; returns a list of (field, message).

    The shape rules are a mail rule's, over the feed fields. One more: at
    most one `feed` condition. Conditions are ANDed and `feed` names one
    subscription exactly, so two of them could never both hold.'''
    errors = _condition_errors(conditions, FEED_FIELDS)
    if errors or not isinstance(conditions, list):
        return errors
    if sum(1 for cond in conditions if cond['field'] == 'feed') > 1:
        errors.append(('conditions', 'At most one feed condition per rule.'))
    return errors


def _normalize_feed_rules(rules_in, taken_ids):
    '''Validates and canonicalizes the incoming feed rule array.

    Returns (rules, errors): the canonical feed rule dicts (schema keys only,
    server-assigned ids) and the structured validation errors, each marked
    `'list': 'feedRules'` so a client can tell which list `rule` indexes.
    `rules` is meaningful only when `errors` is empty. `taken_ids` are the
    ids the mail rules of the same request hold: an id is unique across both
    lists, so an audit path or a client's selection never names two rules.

    Whether a `feed` condition names a subscription the caller still has,
    and whether a slot is still in the palette, are not checked here, for
    the reason folder targets are not: either can change after the save, and
    a stale reference must not wedge every later whole-set save. The fetch
    worker is the enforcement point: a rule for a subscription that is gone
    matches nothing, and one that sets a slot not in the palette is skipped.
    '''
    rules, errors, seen_ids = [], [], set(taken_ids)
    for index, rule_in in enumerate(rules_in):
        if not isinstance(rule_in, dict):
            errors.append({'list': 'feedRules', 'rule': index, 'field': '',
                           'error': 'Rule must be an object.'})
            continue
        rule_errors = [(key, 'Unknown field.') for key in rule_in
                       if key not in FEED_DEFAULTS and key != 'id']
        rule = {key: rule_in.get(key, default) for key, default in FEED_DEFAULTS.items()}
        rule_errors += _name_and_bool_errors(rule, FEED_BOOL_KEYS)
        rule_errors += _feed_condition_errors(rule['conditions'])
        rule_errors += _rule_flags_errors(rule['flags'])
        rule['id'] = _assign_id(rule_in, seen_ids)
        errors += [{'list': 'feedRules', 'rule': index, 'field': field, 'error': message}
                   for field, message in rule_errors]
        rules.append(rule)
    return rules, errors


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


def _json_patch(old, new, root='rules'):
    '''A JSON Patch (RFC 6902) turning the old array at /<root> into the new one.'''
    ops = []
    for i in range(min(len(old), len(new))):
        if old[i] != new[i]:
            ops.append({'op': 'replace', 'path': f'/{root}/{i}', 'value': new[i]})
    for i in range(len(old), len(new)):
        ops.append({'op': 'add', 'path': f'/{root}/{i}', 'value': new[i]})
    for i in range(len(old) - 1, len(new) - 1, -1):
        ops.append({'op': 'remove', 'path': f'/{root}/{i}'})
    return ops


def _parse_request(event):
    '''Returns (rules, feed_rules, expected_version) or raises ValueError with
    a 400 message. `feed_rules` is None when the request has no `feedRules`
    key, which means "leave the stored list alone"; an explicit null is
    refused rather than read as either that or "clear the list".'''
    try:
        body = json.loads(event.get('body') or '{}')
    except (TypeError, ValueError) as err:
        raise ValueError('Invalid JSON body.') from err
    if not isinstance(body, dict):
        raise ValueError('Request body must be a JSON object.')
    rules = body.get('rules')
    expected = body.get('expectedVersion')
    if not isinstance(rules, list):
        raise ValueError('rules must be a list.')
    if len(rules) > MAX_RULES:
        raise ValueError(f'At most {MAX_RULES} rules.')
    feed_rules = None
    if 'feedRules' in body:
        feed_rules = body['feedRules']
        if not isinstance(feed_rules, list):
            raise ValueError('feedRules must be a list.')
        if len(feed_rules) > MAX_FEED_RULES:
            raise ValueError(f'At most {MAX_FEED_RULES} feed rules.')
    if isinstance(expected, bool) or not isinstance(expected, int) or expected < 0:
        raise ValueError('expectedVersion must be a non-negative integer.')
    return rules, feed_rules, expected


def _write_row(user, serialized, serialized_feed, expected, updated_at):  # pylint: disable=too-many-arguments,too-many-positional-arguments
    '''Commits the replacement guarded by the version condition and returns
    the feed rules the row holds afterwards, as a JSON string.

    `rules` is always replaced. `feedRules` is replaced only when
    `serialized_feed` is not None: an UpdateItem that does not name an
    attribute leaves it as it is, which is how a save from a client that
    does not know feed rules keeps them.

    A first-ever write (expected 0) must find no versioned row; any later
    write must find exactly the version the client saw. Raises
    ClientError(ConditionalCheckFailedException) on a lost race.
    '''
    expression = 'SET #r = :r, #v = :v, #t = :t'
    names = {'#r': 'rules', '#v': 'version', '#t': 'updatedAt'}
    if expected == 0:
        condition = 'attribute_not_exists(#v)'
        values = {':r': serialized, ':v': 1, ':t': updated_at}
    else:
        condition = '#v = :ev'
        values = {':r': serialized, ':v': expected + 1, ':t': updated_at, ':ev': expected}
    if serialized_feed is not None:
        expression += ', #f = :f'
        names['#f'] = 'feedRules'
        values[':f'] = serialized_feed
    # The stored list is read back from the write itself, not from the read
    # before it: that read can be a version behind the one the condition
    # then matched.
    written = table.update_item(
        Key={'user': user},
        UpdateExpression=expression,
        ConditionExpression=condition,
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
        ReturnValues='ALL_NEW',
    )
    return (written or {}).get('Attributes', {}).get('feedRules', '[]')


def _record_side_effects(user, prior, new, version):
    '''Audit row + SNS fan-out, best-effort after the committed write.

    `prior` and `new` are (rules, feed_rules) pairs; `new`'s feed rules are
    None when the request left them alone. The audit diff covers both lists,
    under /rules and /feedRules.

    The publish is what makes the imap tier recompile every user's procmail,
    and that compiler reads only the mail rules. So only a save that changed
    them publishes: a feed-rule edit, which the editors auto-save as the
    user types, would otherwise cost the mail tier a reconfigure each time
    for an identical result.'''
    now = time.time()
    diff = _json_patch(prior[0], new[0])
    if new[1] is not None:
        diff += _json_patch(prior[1], new[1], 'feedRules')
    try:
        audit_table.put_item(Item={
            'user': user,
            'ts': int(now * 1000),
            'version': version,
            'diff': json.dumps(diff),
            'expiresAt': int(now) + AUDIT_RETENTION_SECONDS,
        })
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'[set_rules] audit write failed for {user}: {err}')
    if prior[0] == new[0]:
        return
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


def _validate(rules_in, feed_in):
    '''Normalizes both lists. Returns (rules, feed_rules, stripped, problem):
    `problem` is the 400 body when either list is invalid or too large, else
    None; `feed_rules` is None when the request carried no feed rules.'''
    rules, errors, stripped = _normalize_rules(rules_in)
    feed_rules = None
    if feed_in is not None:
        feed_rules, feed_errors = _normalize_feed_rules(feed_in, {rule['id'] for rule in rules})
        errors += feed_errors
    if errors:
        return rules, feed_rules, stripped, {'errors': errors}
    if len(json.dumps(rules)) > MAX_RULES_BYTES:
        return rules, feed_rules, stripped, {'Error': 'Rule set too large.'}
    if feed_rules is not None and len(json.dumps(feed_rules)) > MAX_FEED_RULES_BYTES:
        return rules, feed_rules, stripped, {'Error': 'Feed rule set too large.'}
    return rules, feed_rules, stripped, None


def handler(event, _context):
    '''Validates and stores the caller's rule set with optimistic concurrency.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    prior = {}
    try:
        rules_in, feed_in, expected = _parse_request(event)
    except ValueError as err:
        return {'statusCode': 400, 'body': json.dumps({'Error': str(err)})}
    rules, feed_rules, stripped, problem = _validate(rules_in, feed_in)
    if problem:
        return {'statusCode': 400, 'body': json.dumps(problem)}
    updated_at = datetime.now(timezone.utc).isoformat()
    try:
        # Prior state read consistently for the audit diff; the conditional
        # write below is what actually guards the version race.
        prior = table.get_item(Key={'user': user}, ConsistentRead=True).get('Item', {})
        prior_lists = (json.loads(prior.get('rules', '[]')),
                       json.loads(prior.get('feedRules', '[]')))
        stored_feed = _write_row(
            user, json.dumps(rules),
            None if feed_rules is None else json.dumps(feed_rules),
            expected, updated_at)
    except Exception as err:  # pylint: disable=broad-exception-caught
        return _error_response(err, int(prior.get('version', 0)))
    _record_side_effects(user, prior_lists, (rules, feed_rules), expected + 1)
    return {
        'statusCode': 200,
        'body': json.dumps({
            'rules': rules,
            # What the row holds now: the list this request sent, or the
            # stored one it left alone.
            'feedRules': json.loads(stored_feed),
            'version': expected + 1,
            'updatedAt': updated_at,
            'stripped': stripped,
            'warnings': _folder_warnings(rules),
        })
    }
