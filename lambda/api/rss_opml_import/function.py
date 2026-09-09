'''POST /rss_opml_import - subscribe to every feed in an OPML document.

Body: {"opml": "<xml text>", "folder_id": "..."?}

Additive (D5): existing subscriptions are kept and reported as such; the
OPML's folder outlines become folders (reusing a folder of the same name
under the same parent), rooted at `folder_id` when given. Feeds unknown to
Cabalmail are created WITHOUT the interactive probe, from the OPML's own
title, and handed to the fetch worker, so a large export fits one request;
a dead entry surfaces as feed health rather than as an import error. Only
URLs that fail canonicalization are rejected here.

Response: {"created": n, "existing": n, "folders_created": n,
           "failed": [{"url", "code", "Error"}]}
Codes: invalid_opml (400), unknown_folder (404).
'''
import uuid
from rss_api import (ApiError, ROOT_FOLDER, body_of, folders, guarded,  # pylint: disable=import-error
                     list_folders, list_subscriptions, ok, username)
from rss_opml import OpmlError, parse_opml  # pylint: disable=import-error
from rss_subscribe_core import require_folder, resolve_feed, subscribe  # pylint: disable=import-error


@guarded
def handler(event, _context):
    '''Parses the OPML and subscribes the caller to each feed.'''
    user = username(event)
    body = body_of(event)
    root = body.get('folder_id') or ''
    require_folder(user, root)
    try:
        entries = parse_opml(body.get('opml'))
    except OpmlError as err:
        raise ApiError(400, 'invalid_opml', str(err)) from err
    tree = FolderTree(user, root)
    summary = import_entries(user, entries, tree)
    summary['folders_created'] = tree.created
    return ok(summary)


def import_entries(user, entries, tree):
    '''Subscribes to each entry; returns {created, existing, failed}.'''
    subs = list_subscriptions(user)
    created = existing = 0
    failed = []
    for entry in entries:
        folder_id = tree.ensure(entry['folder_path'])
        try:
            feed = resolve_feed(entry['xml_url'], probe=False, title=entry['title'])
            row, was_created = subscribe(user, feed, folder_id, existing_subs=subs)
        except ApiError as err:
            failed.append({'url': entry['xml_url'], 'code': err.code, 'Error': err.message})
            continue
        if was_created:
            subs.append(row)
            created += 1
        else:
            existing += 1
    return {'created': created, 'existing': existing, 'failed': failed}


class FolderTree:  # pylint: disable=too-few-public-methods
    '''Resolves OPML folder paths to folder ids, creating what is missing and
    reusing a same-named folder under the same parent.'''

    def __init__(self, user, root):
        self.user = user
        self.root = root
        self.created = 0
        self.by_parent_name = {}
        for row in list_folders(user):
            key = (row.get('parent_folder_id') or '', row.get('name', ''))
            self.by_parent_name.setdefault(key, row['folder_id'])

    def ensure(self, path):
        '''The folder id for `path` (a list of names) under the root.'''
        parent = self.root
        for name in path:
            key = (parent, name)
            folder_id = self.by_parent_name.get(key)
            if not folder_id:
                folder_id = self._create(parent, name)
                self.by_parent_name[key] = folder_id
            parent = folder_id
        return parent

    def _create(self, parent, name):
        row = {'user': self.user, 'folder_id': str(uuid.uuid4()), 'name': name, 'display_order': 0}
        if parent and parent != ROOT_FOLDER:
            row['parent_folder_id'] = parent
        folders.put_item(Item=row)
        self.created += 1
        return row['folder_id']
