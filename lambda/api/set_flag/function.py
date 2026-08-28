'''Sets IMAP flags on messages for a user given a folder and list of message ids'''
import json
import os
import re
import boto3  # pylint: disable=import-error
from botocore.exceptions import ClientError  # pylint: disable=import-error
from helper import ( # pylint: disable=import-error
    apply_in_batches,
    batch_result_response,
    get_imap_client,
    parse_bulk_request,
    validate_flag,
    validate_folder_name,
    validate_uid_list,
)

from helper import maintenance_guard # pylint: disable=import-error

# Custom flags are the fixed slot atoms of the user's palette
# (docs/1.x/rules-composition-and-custom-flags-plan.md, decisions 4 and 6):
# the mailstore's keyword vocabulary is cabal-flag-01..20, and the API is
# the palette's sole enforcement point. Setting a slot requires it to be
# present in the palette (the plan's "a keyword unknown to the palette is
# rejected"); unsetting only requires a well-formed slot atom, so tags on
# a slot whose palette entry was deleted can still be removed. Any other
# keyword is rejected outright — arbitrary user-named keywords on the
# wire are an explicit non-goal.
SLOT_RE = re.compile(r'^cabal-flag-(0[1-9]|1[0-9]|20)$')

_preferences_table = boto3.resource('dynamodb').Table(
    os.environ.get('USER_PREFERENCES_TABLE_NAME', 'cabal-user-preferences'))


def _palette_slots(user):
    '''The user's palette as {slot: enabled}. Raises on a read failure —
    unlike compose.py's display-name lookup this must fail closed: a
    transient error must not let an unvetted keyword through.'''
    item = _preferences_table.get_item(Key={'user': user}).get('Item', {})
    raw = item.get('app', {}).get('flag_palette', '[]')
    try:
        entries = json.loads(raw)
    except ValueError:
        return {}
    if not isinstance(entries, list):
        return {}
    return {entry.get('slot'): entry.get('enabled', True)
            for entry in entries if isinstance(entry, dict)}


def _check_keyword(user, flag, setting):
    '''Returns an error string for a rejected keyword, or None to proceed.'''
    if flag.startswith('\\'):
        return None  # canonical system flag, validated upstream
    if not SLOT_RE.match(flag):
        return f'unknown keyword: {flag!r}'
    if not setting:
        return None  # untagging a retired slot must stay possible
    if not _palette_slots(user).get(flag, False):
        return f'flag not in palette: {flag!r}'
    return None


@maintenance_guard
def handler(event, _context):
    '''Sets IMAP flags on messages for a user given a folder and list of message ids'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    body, error = parse_bulk_request(event)
    if error:
        return error
    try:
        folder = validate_folder_name(body.get('folder'))
        ids = validate_uid_list(body.get('ids'))
        flag = validate_flag(body.get('flag'))
    except ValueError as err:
        return _invalid(err)
    setting = body.get('op') == 'set'
    try:
        rejected = _check_keyword(user, flag, setting)
    except ClientError:
        # Fail closed: without the palette we cannot vouch for the slot.
        return {
            "statusCode": 500,
            "body": json.dumps({"status": "unable"})
        }
    if rejected:
        return _invalid(rejected)
    client = get_imap_client(body['host'], user, folder.replace("/", "."))
    # Chunk the store like /move_messages so a large selection can't blow the
    # 29s ceiling in one UID STORE. Flags are idempotent, so a failed batch is
    # safe to retry. No post-store SORT: both clients discard the returned UID
    # list and re-poll for ordering, so that second full-folder walk was waste.
    store = client.add_flags if setting else client.remove_flags
    flagged_ids, failed_ids = apply_in_batches(ids, lambda batch: store(batch, flag, True))
    client.logout()
    return batch_result_response(flagged_ids, failed_ids, "flagged_ids")

def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
