'''POST /rss_new_folder - create a folder in the caller's hierarchy.

Body: {"name": "...", "parent_folder_id": "..."?, "display_order": n?}
'''
import uuid
from rss_api import (ApiError, MAX_TITLE_LENGTH, body_of, folders, guarded,  # pylint: disable=import-error
                     ok, serialize_folder, username)


@guarded
def handler(event, _context):
    '''Creates the folder; the parent must exist when given.'''
    user = username(event)
    body = body_of(event)
    name = validate_name(body.get('name'))
    parent = body.get('parent_folder_id') or ''
    if parent and not folders.get_item(Key={'user': user, 'folder_id': parent}).get('Item'):
        raise ApiError(404, 'unknown_folder', 'No such parent folder.')
    row = {
        'user': user,
        'folder_id': str(uuid.uuid4()),
        'name': name,
        'display_order': display_order(body.get('display_order')),
    }
    if parent:
        row['parent_folder_id'] = parent
    folders.put_item(Item=row)
    return ok({'folder': serialize_folder(row)})


def validate_name(name):
    '''A non-empty, control-character-free name within the length cap.'''
    name = str(name or '').strip()
    if not name:
        raise ApiError(400, 'invalid_name', 'Folder name is required.')
    if len(name) > MAX_TITLE_LENGTH or any(ord(c) < 32 for c in name):
        raise ApiError(400, 'invalid_name',
                       'Folder name is too long or contains control characters.')
    return name


def display_order(value):
    '''A non-negative integer, defaulting to 0.'''
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError) as err:
        raise ApiError(400, 'invalid_display_order', 'display_order must be an integer.') from err
