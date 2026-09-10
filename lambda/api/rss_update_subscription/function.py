'''PUT /rss_update_subscription - change a subscription's per-user settings.

Body: {"subscription_id": "...", and any of
       "custom_title", "folder_id", "ordering_mode", "default_open_mode",
       "default_styling", "notifications_enabled"}

Settings are stored here and APPLIED on the client (open Q5 in the
requirements): the shared feed row is never touched. notifications_enabled
also maintains the sparse notify_feed_id attribute that the phase 8
fan-out queries (present only while notifications are on).
'''
from rss_api import (ApiError, MAX_TITLE_LENGTH, OPEN_MODES, ORDERING_MODES,  # pylint: disable=import-error
                     ROOT_FOLDER, STYLING_MODES, body_of, feeds, folder_key,
                     folders, get_subscription, guarded, ok, serialize_subscription,
                     subscriptions, username)

ENUMS = {
    'ordering_mode': ORDERING_MODES,
    'default_open_mode': OPEN_MODES,
    'default_styling': STYLING_MODES,
}


@guarded
def handler(event, _context):
    '''Validates and applies the changed fields.'''
    user = username(event)
    body = body_of(event)
    sub = get_subscription(user, body.get('subscription_id'))
    sets, removes, values = build_update(user, sub, body)
    if not sets and not removes:
        raise ApiError(400, 'nothing_to_update', 'No recognised fields to update.')
    expression = 'SET ' + ', '.join(sets) if sets else ''
    if removes:
        expression += ' REMOVE ' + ', '.join(removes)
    kwargs = {'Key': {'user': user, 'subscription_id': sub['subscription_id']},
              'UpdateExpression': expression.strip(),
              'ReturnValues': 'ALL_NEW'}
    if values:
        kwargs['ExpressionAttributeValues'] = values
    updated = subscriptions.update_item(**kwargs)['Attributes']
    feed = feeds.get_item(Key={'feed_id': sub['feed_id']}).get('Item')
    return ok({'subscription': serialize_subscription(updated, feed)})


def build_update(user, sub, body):
    '''(SET clauses, REMOVE attributes, values) for the recognised fields.'''
    sets, removes, values = [], [], {}
    if 'custom_title' in body:
        title = str(body['custom_title'] or '')[:MAX_TITLE_LENGTH]
        if any(ord(c) < 32 for c in title):
            raise ApiError(400, 'invalid_title', 'Title contains control characters.')
        sets.append('custom_title = :title')
        values[':title'] = title
    for field, allowed in ENUMS.items():
        if field in body:
            if body[field] not in allowed:
                raise ApiError(400, f'invalid_{field}',
                               f'{field} must be one of {", ".join(allowed)}.')
            sets.append(f'{field} = :{field}')
            values[f':{field}'] = body[field]
    if 'folder_id' in body:
        folder_id = body['folder_id'] or ''
        if folder_id and not folders.get_item(Key={'user': user,
                                                   'folder_id': folder_id}).get('Item'):
            raise ApiError(404, 'unknown_folder', 'No such folder.')
        sets += ['folder_id = :folder', 'folder_key = :fkey']
        values[':folder'] = folder_id or ROOT_FOLDER
        values[':fkey'] = folder_key(folder_id, sub['subscription_id'])
    if 'notifications_enabled' in body:
        enabled = bool(body['notifications_enabled'])
        sets.append('notifications_enabled = :notify')
        values[':notify'] = enabled
        if enabled:
            sets.append('notify_feed_id = :nfid')
            values[':nfid'] = sub['feed_id']
        else:
            removes.append('notify_feed_id')
    return sets, removes, values
