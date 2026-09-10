'''POST /rss_delete_folder - delete a folder, keeping its contents.

Body: {"folder_id": "..."}

Subscriptions and child folders inside it move to its parent (or the
root), never deleted: removing a container should not silently
unsubscribe anything.
'''
from rss_api import (ApiError, ROOT_FOLDER, body_of, folder_key, folders,  # pylint: disable=import-error
                     guarded, list_folders, list_subscriptions, ok,
                     subscriptions, username)


@guarded
def handler(event, _context):
    '''Reparents the contents, then deletes the folder row.'''
    user = username(event)
    body = body_of(event)
    folder_id = body.get('folder_id') or ''
    row = folders.get_item(Key={'user': user, 'folder_id': folder_id}).get('Item')
    if not row:
        raise ApiError(404, 'unknown_folder', 'No such folder.')
    parent = row.get('parent_folder_id') or ''
    moved_subs = reparent_subscriptions(user, folder_id, parent)
    moved_folders = reparent_folders(user, folder_id, parent)
    folders.delete_item(Key={'user': user, 'folder_id': folder_id})
    return ok({'folder_id': folder_id, 'moved_subscriptions': moved_subs,
               'moved_folders': moved_folders, 'parent_folder_id': parent})


def reparent_subscriptions(user, folder_id, parent):
    '''Moves the folder's subscriptions to `parent` (root when empty).'''
    moved = 0
    for sub in list_subscriptions(user):
        if (sub.get('folder_id') or ROOT_FOLDER) != folder_id:
            continue
        subscriptions.update_item(
            Key={'user': user, 'subscription_id': sub['subscription_id']},
            UpdateExpression='SET folder_id = :folder, folder_key = :fkey',
            ExpressionAttributeValues={':folder': parent or ROOT_FOLDER,
                                       ':fkey': folder_key(parent, sub['subscription_id'])})
        moved += 1
    return moved


def reparent_folders(user, folder_id, parent):
    '''Moves the folder's child folders to `parent` (root when empty).'''
    moved = 0
    for child in list_folders(user):
        if child.get('parent_folder_id') != folder_id:
            continue
        if parent:
            folders.update_item(Key={'user': user, 'folder_id': child['folder_id']},
                                UpdateExpression='SET parent_folder_id = :parent',
                                ExpressionAttributeValues={':parent': parent})
        else:
            folders.update_item(Key={'user': user, 'folder_id': child['folder_id']},
                                UpdateExpression='REMOVE parent_folder_id')
        moved += 1
    return moved
