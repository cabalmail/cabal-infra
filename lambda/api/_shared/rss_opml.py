'''OPML parsing and generation for the RSS reader (docs/1.x/rss-requirements.md,
Decision 5: import and export both in v1, import additive).

parse_opml() walks the <body> outline tree: an outline with an xmlUrl is a
feed, one without is a folder whose name is its text (or title), and
nesting gives each feed a folder path. This is how Feedly, NetNewsWire,
Reeder, Inoreader, and FreshRSS all write their exports; attribute case
varies in the wild (xmlUrl / xmlURL / xmlurl), so attributes are matched
case-insensitively.

build_opml() emits OPML 2.0 with the caller's folder tree as nested
outlines and one type="rss" outline per subscription, so the file round-
trips into any of the readers above.

defusedxml does the parsing: an OPML file is untrusted input and the
stdlib parser will expand entities.
'''
from datetime import datetime, timezone
from xml.sax.saxutils import escape, quoteattr

MAX_OPML_BYTES = 2 * 1024 * 1024
MAX_FEEDS = 1000
MAX_DEPTH = 8


class OpmlError(ValueError):
    '''The document is not OPML we can read. The message is user-facing.'''


def parse_opml(text):
    '''[{"title", "xml_url", "html_url", "folder_path": [names]}] in document
    order, de-duplicated by xml_url (first occurrence wins).'''
    if not isinstance(text, str) or not text.strip():
        raise OpmlError('The OPML document is empty.')
    if len(text.encode('utf-8', 'replace')) > MAX_OPML_BYTES:
        raise OpmlError('The OPML document is too large (2 MB limit).')
    try:
        from defusedxml import ElementTree as safe_et  # pylint: disable=import-outside-toplevel,import-error
        root = safe_et.fromstring(text.encode('utf-8'))
    except Exception as err:  # defusedxml raises several types; all mean "not OPML"
        raise OpmlError(f'The OPML document could not be parsed: {err}') from err
    if _local(root.tag) != 'opml':
        raise OpmlError('The document is not OPML (root element is not <opml>).')
    body = next((child for child in root if _local(child.tag) == 'body'), None)
    if body is None:
        raise OpmlError('The OPML document has no <body>.')
    entries, seen = [], set()
    _walk(body, [], entries, seen, 0)
    return entries


def _walk(node, path, entries, seen, depth):
    for outline in node:
        if _local(outline.tag) != 'outline':
            continue
        attrs = {k.lower(): (v or '').strip() for k, v in outline.attrib.items()}
        xml_url = attrs.get('xmlurl', '')
        name = attrs.get('text') or attrs.get('title') or ''
        if xml_url:
            if len(entries) >= MAX_FEEDS:
                raise OpmlError(f'The OPML document lists more than {MAX_FEEDS} feeds.')
            if xml_url not in seen:
                seen.add(xml_url)
                entries.append({'title': name[:512], 'xml_url': xml_url,
                                'html_url': attrs.get('htmlurl', '')[:2048],
                                'folder_path': list(path)})
            continue
        # A folder (or a bare grouping outline). Nest into it when it has a
        # name and depth allows; otherwise flatten its children into `path`.
        child_path = path + [name[:256]] if name and depth < MAX_DEPTH else path
        _walk(outline, child_path, entries, seen, depth + 1)


def build_opml(folders, subscriptions, owner_title='Cabalmail feeds'):
    '''OPML 2.0 text. `folders` and `subscriptions` are the wire-form dicts
    from rss_api.serialize_folder / serialize_subscription (the latter with
    their `feed` summaries).'''
    by_parent = {}
    for folder in folders:
        by_parent.setdefault(folder.get('parent_folder_id') or '', []).append(folder)
    subs_by_folder = {}
    for sub in subscriptions:
        subs_by_folder.setdefault(sub.get('folder_id') or '', []).append(sub)
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<opml version="2.0">',
        '  <head>',
        f'    <title>{escape(owner_title)}</title>',
        '    <dateCreated>'
        + datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S GMT')
        + '</dateCreated>',
        '  </head>',
        '  <body>',
    ]
    _emit(lines, '', by_parent, subs_by_folder, 2, set())
    lines += ['  </body>', '</opml>', '']
    return '\n'.join(lines)


def _emit(lines, folder_id, by_parent, subs_by_folder, indent, visited):  # pylint: disable=too-many-arguments,too-many-positional-arguments
    pad = '  ' * indent
    for folder in sorted(by_parent.get(folder_id, []),
                         key=lambda f: (f.get('display_order', 0), f.get('name', ''))):
        if folder['folder_id'] in visited:
            continue
        visited.add(folder['folder_id'])
        name = folder.get('name', '')
        lines.append(f'{pad}<outline text={quoteattr(name)} title={quoteattr(name)}>')
        _emit(lines, folder['folder_id'], by_parent, subs_by_folder, indent + 1, visited)
        lines.append(f'{pad}</outline>')
    for sub in subs_by_folder.get(folder_id, []):
        feed = sub.get('feed') or {}
        title = sub.get('custom_title') or feed.get('title') or feed.get('canonical_url', '')
        attrs = [f'text={quoteattr(title)}', f'title={quoteattr(title)}', 'type="rss"',
                 f'xmlUrl={quoteattr(feed.get("canonical_url", ""))}']
        if feed.get('site_url'):
            attrs.append(f'htmlUrl={quoteattr(feed["site_url"])}')
        lines.append(f'{pad}<outline {" ".join(attrs)}/>')


def _local(tag):
    return tag.rsplit('}', 1)[-1].lower()
