'''POST /rss_set_item_state - mark items read/unread and favorite/unfavorite,
and add or remove custom flags.

Body: {"items": [{"feed_id": "...", "sort_key": "...",
                  "is_read": bool?, "is_favorite": bool?,
                  "add_flags": [slot, ...]?, "remove_flags": [slot, ...]?},
                 ...]}  (<= 100)

Writes the caller's state rows (created on first touch). A favorite also
sets favorite_key (= sort_key) so the sparse favorite_by_feed index carries
exactly the favorites; unfavoriting removes it. An explicit is_read value
overrides the subscription's read watermark for that item, in either
direction - marking something unread after mark-all-read sticks.

Custom flags are the keyword slots of the caller's flag palette
(cabal-flag-01..20; docs/1.x/cross-media-ux-plan.md, decision 2), kept as
the string set `flags` on the state row. They change by ADD and DELETE,
never by replacing the set, so two devices that change different slots of
one item both win. The system flag is not one of them: on a feed item it is
is_favorite. Adding needs a slot that is in the palette; removing needs only
a well-formed slot, so a flag whose palette entry is gone can still be
cleared (set_flag's rule for mail). Every entry's flags are checked before
anything is written, so a call refused for a flag has changed nothing.
'''
import json
import os
import re
from datetime import datetime, timezone
import boto3  # pylint: disable=import-error
from botocore.exceptions import ClientError  # pylint: disable=import-error
from rss_api import (ApiError, body_of, guarded, list_subscriptions, ok,  # pylint: disable=import-error
                     state, updated_key, user_feed_key, username)

MAX_ITEMS = 100
# The palette's keyword slots, as set_flag and set_rules spell them.
SLOT_RE = re.compile(r'cabal-flag-(0[1-9]|1[0-9]|20)')

preferences = boto3.resource('dynamodb').Table(
    os.environ.get('USER_PREFERENCES_TABLE_NAME', 'cabal-user-preferences'))


@guarded
def handler(event, _context):
    '''Applies each requested state change.'''
    user = username(event)
    body = body_of(event)
    requested = body.get('items')
    if not isinstance(requested, list) or not requested:
        raise ApiError(400, 'missing_items', 'items must be a non-empty list.')
    if len(requested) > MAX_ITEMS:
        raise ApiError(400, 'too_many_items', f'At most {MAX_ITEMS} items per call.')
    changes = [flag_changes(entry) for entry in requested]
    check_palette(user, changes)
    subscribed = {s['feed_id'] for s in list_subscriptions(user)}
    now = datetime.now(timezone.utc).isoformat()
    updated = 0
    for entry, (add, remove) in zip(requested, changes):
        feed_id, sort_key = validate_entry(entry, subscribed)
        updates = build_updates(entry, sort_key, now, add, remove)
        write({'user_feed': user_feed_key(user, feed_id), 'sort_key': sort_key}, updates)
        updated += bool(updates)
    return ok({'updated': updated})


def write(key, updates):
    '''Applies one entry's updates to its state row, in order.'''
    for expression, values in updates:
        state.update_item(Key=key, UpdateExpression=expression, ExpressionAttributeValues=values)


def validate_entry(entry, subscribed):
    '''(feed_id, sort_key) of a well-formed entry the caller may touch.'''
    if not isinstance(entry, dict):
        raise ApiError(400, 'invalid_item', 'Each item must be an object.')
    feed_id, sort_key = entry.get('feed_id') or '', entry.get('sort_key') or ''
    if not feed_id or not sort_key or '#' not in sort_key:
        raise ApiError(400, 'invalid_item', 'Each item needs feed_id and sort_key.')
    if feed_id not in subscribed:
        raise ApiError(404, 'not_subscribed', f'Not subscribed to feed {feed_id}.')
    return feed_id, sort_key


def flag_changes(entry):
    '''(add, remove): the slots one entry adds and the slots it removes, as
    sets. An entry that is not an object has none; validate_entry refuses it
    when its turn comes.'''
    if not isinstance(entry, dict):
        return set(), set()
    add, remove = slots_of(entry, 'add_flags'), slots_of(entry, 'remove_flags')
    both = sorted(add & remove)
    if both:
        raise ApiError(400, 'flag_conflict',
                       f'A flag cannot be added and removed at once: {", ".join(both)}.',
                       flags=both)
    return add, remove


def slots_of(entry, name):
    '''The slots listed under `name`; empty when it is absent or null.'''
    listed = entry.get(name)
    if listed is None:
        return set()
    if not isinstance(listed, list):
        raise ApiError(400, 'invalid_flags', f'{name} must be a list of flag slots.')
    for slot in listed:
        if not isinstance(slot, str) or not SLOT_RE.fullmatch(slot):
            raise ApiError(400, 'invalid_flags', f'{name}: not a flag slot: {slot!r}.')
    return set(listed)


def check_palette(user, changes):
    '''Refuses the call unless every slot it adds is in the caller's palette.
    A call that adds nothing does not read the palette, so nothing about the
    palette can fail it.'''
    adding = set().union(*(add for add, _ in changes))
    if not adding:
        return
    try:
        listed = palette_slots(user)
    except ClientError as err:
        # Fail closed, as set_flag does: without the palette no slot can be
        # vouched for.
        raise ApiError(500, 'palette_unavailable', 'The flag palette could not be read.') from err
    refused = sorted(adding - listed)
    if refused:
        raise ApiError(400, 'flag_not_in_palette',
                       f'Not a flag in the palette: {", ".join(refused)}.',
                       flags=refused)


def palette_slots(user):
    '''The slots in the caller's palette, read as set_flag reads it: an
    entry's `enabled` is not read (docs/2.x/flag-palette-enabled-removal.md),
    and a missing or malformed palette has no slots.'''
    # A consistent read: refused a flag add, the feed queue has the unsent
    # settings pushed and sends the batch again at once, and the palette as
    # it was before that push would refuse the add a second time, which
    # the queue takes as final (#2442).
    item = preferences.get_item(
        Key={'user': user}, ConsistentRead=True).get('Item', {})
    raw = item.get('app', {}).get('flag_palette', '[]')
    try:
        entries = json.loads(raw)
    except (TypeError, ValueError):
        return set()
    if not isinstance(entries, list):
        return set()
    return {entry.get('slot') for entry in entries if isinstance(entry, dict)}


def build_updates(entry, sort_key, now, add, remove):
    '''The writes for one entry, as (UpdateExpression, values) pairs: none
    when the entry changes nothing, one otherwise, and two when it both adds
    and removes flags. DynamoDB refuses an expression that names one
    attribute in two clauses, so ADD flags and DELETE flags cannot share
    one; the removal goes second and carries the same timestamps. Each write
    is idempotent, so a call that fails between the two is safe to repeat.'''
    stamps = ['updated_at = :now', 'updated_key = :ukey']
    stamp_values = {':now': now, ':ukey': updated_key(now, sort_key)}
    sets = ['item_id = if_not_exists(item_id, :item_id)'] + stamps
    removes = []
    values = {':item_id': sort_key.split('#', 1)[1], **stamp_values}
    touched = bool(add or remove)
    if 'is_read' in entry:
        sets.append('is_read = :read')
        values[':read'] = bool(entry['is_read'])
        touched = True
    if 'is_favorite' in entry:
        favorite = bool(entry['is_favorite'])
        sets.append('is_favorite = :fav')
        values[':fav'] = favorite
        if favorite:
            sets.append('favorite_key = :fkey')
            values[':fkey'] = sort_key
        else:
            removes.append('favorite_key')
        touched = True
    if not touched:
        return []
    expression = 'SET ' + ', '.join(sets)
    if removes:
        expression += ' REMOVE ' + ', '.join(removes)
    if add:
        expression += ' ADD flags :add'
        values[':add'] = add
    elif remove:
        expression += ' DELETE flags :remove'
        values[':remove'] = remove
    updates = [(expression, values)]
    if add and remove:
        updates.append(('SET ' + ', '.join(stamps) + ' DELETE flags :remove',
                        {**stamp_values, ':remove': remove}))
    return updates
