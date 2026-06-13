'''Saves, replaces, or discards a draft in the user's Drafts folder.

Phase 3 of docs/0.10.x/draft-sync-and-threading-headers-plan.md. /send's
draft=true branch stays create-only for the React explicit-save flow; this
endpoint adds the lifecycle an autosave-style sync loop needs:

  * op=save (default) APPENDs the composed draft and returns the new copy's
    UIDPLUS coordinates: {"status": "saved", "uid": N, "uidvalidity": V}.
  * save with replaces_uid + replaces_uidvalidity APPENDs the new copy first
    and only then expunges the old one, guarded by UIDVALIDITY - on mismatch
    both copies survive and the response reports "replaced": false.
  * op=discard expunges one draft (same guarded expunge, same fields).

Every operation is scoped to the Drafts folder, mirroring the trash-scoping
of the purge endpoints. Log hygiene: no subject/body/recipient logging.
'''
import json
from imapclient.exceptions import IMAPClientError # pylint: disable=import-error
from compose import ( # pylint: disable=import-error
    DRAFTS_FOLDER,
    append_draft,
    compose_from_body,
    guarded_draft_expunge,
    unauthorized_sender_response_or_none,
)
from helper import ( # pylint: disable=import-error
    delete_object,
    get_imap_client,
    maintenance_guard,
    validate_uid,
)


@maintenance_guard
def handler(event, _context):
    '''Routes the request to save (default) or discard. Interactive and
    IMAP-only, so during a planned IMAP roll the maintenance guard returns
    the 503 signal and clients retry rather than failing.'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    op = body.get('op', 'save')
    if op == 'discard':
        return _discard(body, user)
    if op != 'save':
        return _invalid(f'unknown op: {op!r}')
    return _save(body, user)


def _save(body, user):
    '''Composes the draft, APPENDs it to Drafts, and (optionally) replaces a
    prior copy. The compose payload is the /send shape, validated and built
    by the same shared code.'''
    unauthorized = unauthorized_sender_response_or_none(user, body['sender'])
    if unauthorized:
        return unauthorized
    try:
        msg = compose_from_body(body, user)
        replaces = _parse_replaces(body)
    except ValueError as err:
        return _invalid(err)

    client = get_imap_client(body['host'], user, 'INBOX')
    try:
        uidvalidity, uid = append_draft(client, msg)
        replaced = False
        if replaces is not None:
            replaced = _replace_old_copy(client, replaces, uidvalidity, uid)
    finally:
        client.logout()
    if replaced:
        _drop_cached_raw(body['host'], user, replaces[0])
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "saved",
            "uid": uid,
            "uidvalidity": uidvalidity,
            "replaced": replaced
        })
    }


def _replace_old_copy(client, replaces, new_uidvalidity, new_uid):
    '''Expunges the draft copy this save supersedes. The new copy is already
    APPENDed, so the worst guarded outcome is both copies surviving - never a
    lost draft. Declines (returns False) when the coordinates point at the
    copy just written, when the UIDVALIDITY guard misses, or when the expunge
    itself fails.'''
    old_uid, old_uidvalidity = replaces
    if new_uid is not None and (new_uidvalidity, new_uid) == (old_uidvalidity, old_uid):
        return False
    try:
        return guarded_draft_expunge(client, old_uid, old_uidvalidity)
    except IMAPClientError as err:
        print(f'[save_draft] WARN replace expunge failed; keeping both copies: {err}')
        return False


def _discard(body, user):
    '''Removes one draft via the guarded expunge. Returns "discarded": false
    (not an error) when the UIDVALIDITY guard declines or the Drafts folder
    is missing - in both cases the draft the client meant is already gone or
    was never going to be matched.'''
    try:
        uid = validate_uid(body.get('replaces_uid'))
        uidvalidity = validate_uid(body.get('replaces_uidvalidity'))
    except ValueError as err:
        return _invalid(err)
    client = get_imap_client(body['host'], user, 'INBOX')
    try:
        try:
            discarded = guarded_draft_expunge(client, uid, uidvalidity)
        except IMAPClientError as err:
            print(f'[save_draft] WARN discard failed: {err}')
            discarded = False
    finally:
        client.logout()
    if discarded:
        _drop_cached_raw(body['host'], user, uid)
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "discarded",
            "discarded": discarded
        })
    }


def _parse_replaces(body):
    '''Returns (uid, uidvalidity) when the request carries replace
    coordinates, or None when it carries neither. Raises ValueError on a
    half-supplied or malformed pair.'''
    uid = body.get('replaces_uid')
    uidvalidity = body.get('replaces_uidvalidity')
    if uid is None and uidvalidity is None:
        return None
    return (validate_uid(uid), validate_uid(uidvalidity))


def _drop_cached_raw(host, user, uid):
    '''Best effort: drop the cached raw body so an expunged draft is not
    retrievable from the cache bucket afterwards (same hygiene as
    purge_messages).'''
    bucket = host.replace('imap', 'cache')
    delete_object(bucket, f'{user}/{DRAFTS_FOLDER}/{uid}/raw')


def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {err}"})
    }
