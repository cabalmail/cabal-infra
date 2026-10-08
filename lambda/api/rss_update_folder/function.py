'''PUT /rss_update_folder - rename, move, or reorder a folder.

Body: {"folder_id": "...", and any of "name", "parent_folder_id" (empty
       string = root), "display_order", "default_filter", "ordering_mode"}

Moving a folder under itself or one of its descendants is refused: the
tree must stay a tree.
'''
from rss_api import (ApiError, ITEM_FILTERS, MAX_TITLE_LENGTH, ORDERING_MODES,  # pylint: disable=import-error
                     body_of, folder_and_descendants, folders, guarded, ok,
                     serialize_folder, username)


@guarded
def handler(event, _context):
    '''Applies the changed fields.'''
    user = username(event)
    body = body_of(event)
    folder_id = body.get('folder_id') or ''
    if not folders.get_item(Key={'user': user, 'folder_id': folder_id}).get('Item'):
        raise ApiError(404, 'unknown_folder', 'No such folder.')
    sets, removes, values, names = [], [], {}, {}
    if 'name' in body:
        sets.append('#n = :name')
        names['#n'] = 'name'
        values[':name'] = valid_name(body['name'])
    if 'display_order' in body:
        sets.append('display_order = :order')
        values[':order'] = valid_order(body['display_order'])
    # The pill the folder's list opens on and the order it opens in, sticky
    # like a subscription's default_filter and ordering_mode; the folder row
    # is per user, so they sync as-is. The order applies to the folder's own
    # merged list only; the feeds inside keep theirs.
    for field, allowed in (('default_filter', ITEM_FILTERS), ('ordering_mode', ORDERING_MODES)):
        if field in body:
            sets.append(f'{field} = :{field}')
            values[f':{field}'] = valid_choice(field, body[field], allowed)
    if 'parent_folder_id' in body:
        parent = valid_parent(user, folder_id, body['parent_folder_id'])
        if parent:
            sets.append('parent_folder_id = :parent')
            values[':parent'] = parent
        else:
            removes.append('parent_folder_id')
    if not sets and not removes:
        raise ApiError(400, 'nothing_to_update', 'No recognised fields to update.')
    expression = ('SET ' + ', '.join(sets) if sets else '') + \
                 (' REMOVE ' + ', '.join(removes) if removes else '')
    kwargs = {'Key': {'user': user, 'folder_id': folder_id},
              'UpdateExpression': expression.strip(), 'ReturnValues': 'ALL_NEW'}
    if values:
        kwargs['ExpressionAttributeValues'] = values
    if names:
        kwargs['ExpressionAttributeNames'] = names
    updated = folders.update_item(**kwargs)['Attributes']
    return ok({'folder': serialize_folder(updated)})


def valid_name(value):
    '''A non-empty, control-character-free name within the length cap.'''
    name = str(value or '').strip()
    if not name or len(name) > MAX_TITLE_LENGTH or any(ord(c) < 32 for c in name):
        raise ApiError(400, 'invalid_name',
                       'Folder name is empty, too long, or has control characters.')
    return name


def valid_choice(field, value, allowed):
    '''One of the field's allowed values.'''
    if value not in allowed:
        raise ApiError(400, f'invalid_{field}', f'{field} must be one of {", ".join(allowed)}.')
    return value


def valid_order(value):
    '''A non-negative integer.'''
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError) as err:
        raise ApiError(400, 'invalid_display_order', 'display_order must be an integer.') from err


def valid_parent(user, folder_id, value):
    '''The new parent id ('' for root); refuses cycles and unknown folders.'''
    parent = value or ''
    if not parent:
        return ''
    if parent in folder_and_descendants(user, folder_id):
        raise ApiError(400, 'cyclic_folder', 'A folder cannot be moved under itself.')
    if not folders.get_item(Key={'user': user, 'folder_id': parent}).get('Item'):
        raise ApiError(404, 'unknown_folder', 'No such parent folder.')
    return parent
