'''Turning a parsed message into what an assistant reads: the body as text,
the list of attachments and inline images, and the type of an image part.

A sibling of function.py in the mcp zip (build-api-one.sh ships every *.py at
the function root). Standard library only.

Everything here handles content a sender wrote, and some senders get MIME
wrong; the repairs below are for faults seen in real mail, each described
where it is undone.
'''
import email
import html
import re
from email.policy import default as default_policy
from html.parser import HTMLParser

# Image types an MCP client can show, by the bytes they start with. The
# declared Content-Type is not trusted: a mislabelled part would be refused
# by the client after the bytes had been sent.
_IMAGE_SIGNATURES = (
    (b'\xff\xd8\xff', 'image/jpeg'),
    (b'\x89PNG\r\n\x1a\n', 'image/png'),
    (b'GIF87a', 'image/gif'),
    (b'GIF89a', 'image/gif'),
)


def sniff_image_type(payload):
    '''The image type `payload` starts like, or None.'''
    for signature, mime_type in _IMAGE_SIGNATURES:
        if payload.startswith(signature):
            return mime_type
    if len(payload) >= 12 and payload[:4] == b'RIFF' and payload[8:12] == b'WEBP':
        return 'image/webp'
    return None


def body_text(message):
    '''The message's readable body as (text, source). Prefers text/plain;
    falls back to text/html converted to text. Two sender faults are
    repaired: a text part that starts with a second MIME header block of its
    own, and a plain-text alternative that a sender generated from its HTML
    with the stylesheet left in. For the latter the HTML is used when there
    is one, since it is what the plain text was made from.'''
    part = message.get_body(preferencelist=('plain', 'html'))
    if part is None:
        return '', None
    content = decode_text(part, part.get_payload(decode=True))
    if part.get_content_type() == 'text/html':
        return html_to_text(content), 'text/html'
    text, had_css = strip_leading_css(content)
    if had_css:
        html_part = message.get_body(preferencelist=('html',))
        if html_part is not None:
            return (html_to_text(decode_text(html_part, html_part.get_payload(decode=True))),
                    'text/html')
    return text.strip(), 'text/plain'


def decode_text(part, payload):
    '''A text part's content as str, with line endings normalized and any
    MIME header block the sender nested inside the content removed.'''
    try:
        content = part.get_content()
    except (LookupError, UnicodeDecodeError, AssertionError, KeyError):
        charset = part.get_content_charset() or 'utf-8'
        if not _known_charset(charset):
            charset = 'utf-8'
        content = (payload or b'').decode(charset, errors='replace')
    if not isinstance(content, str):
        content = content.decode('utf-8', errors='replace')
    content = content.replace('\r\n', '\n').replace('\r', '\n')
    return strip_embedded_headers(content)


def _known_charset(name):
    if not name:
        return False
    try:
        b''.decode(name)
    except LookupError:
        return False
    return True


# A header line of a MIME part: `Name: value`.
_HEADER_LINE_RE = re.compile(r'^([A-Za-z][A-Za-z0-9-]*):[ \t]*(.*)$')
_MIME_HEADER_NAMES = ('content-', 'mime-version')
_MAX_EMBEDDED_HEADER_LINES = 12


def strip_embedded_headers(text):
    '''Removes a MIME header block from the start of a text part's content.

    Some senders (USPS Informed Delivery, for one) wrap a part twice, so the
    decoded content of a text/plain part starts with `Content-Type:` and
    `Content-Transfer-Encoding:` lines and a blank line before the real
    text. Only a block made entirely of MIME headers (Content-* and
    MIME-Version, with continuation lines) and ended by a blank line is
    taken as one; anything else is left alone. When that block declares a
    base64 or quoted-printable encoding, the rest is decoded by it.'''
    lines = text.split('\n')
    count = _embedded_header_count(lines)
    if count == 0:
        return text
    rest = '\n'.join(lines[count + 1:])
    inner = email.message_from_string('\n'.join(lines[:count]) + '\n\n' + rest,
                                      policy=default_policy)
    encoding = (inner.get('Content-Transfer-Encoding') or '').strip().lower()
    if inner.get_content_maintype() != 'text' or encoding not in ('base64', 'quoted-printable'):
        return rest
    try:
        decoded = inner.get_content()
    except (LookupError, UnicodeDecodeError, AssertionError, KeyError, ValueError):
        return rest
    return decoded.replace('\r\n', '\n').replace('\r', '\n') if isinstance(decoded, str) else rest


def _embedded_header_count(lines):
    '''How many of `lines` form a MIME header block ended by a blank line,
    or 0 when they do not start with one.'''
    count = 0
    for line in lines:
        if line.strip() == '':
            return count
        if count >= _MAX_EMBEDDED_HEADER_LINES:
            return 0
        if line[:1] in (' ', '\t') and count:
            count += 1
            continue
        match = _HEADER_LINE_RE.match(line)
        if not match or not match.group(1).lower().startswith(_MIME_HEADER_NAMES):
            return 0
        count += 1
    return 0


# A CSS selector list: what can stand before a rule's `{`.
_CSS_SELECTOR_RE = re.compile(r'^[A-Za-z0-9_\-.#,:*>+~\[\]=^$|"\'() \t\n%]+$')


def strip_leading_css(text):
    '''(text, True) with the CSS rules a text part starts with removed, or
    (text, False) when it does not start with CSS.

    Some bulk senders (Mandrill, for one) generate a message's text/plain
    alternative from its HTML and keep the contents of <style> blocks, so
    the "plain text" opens with the stylesheet. Rules are consumed from the
    start while they look like CSS (a selector list, then a brace block with
    a declaration in it; @-rules by brace matching); at least two must
    match before anything is removed, so prose with one brace survives.
    /* comments */ between rules are skipped too.'''
    pos = 0
    rules = 0
    length = len(text)
    while True:
        while pos < length and text[pos].isspace():
            pos += 1
        if text.startswith('/*', pos):
            close = text.find('*/', pos + 2)
            if close == -1:
                break
            pos = close + 2
            continue
        if pos >= length:
            break
        brace = text.find('{', pos)
        if brace == -1 or brace - pos > 500:
            break
        prelude = text[pos:brace]
        if prelude.startswith('@'):
            end = _matching_brace(text, brace)
        elif _CSS_SELECTOR_RE.match(prelude) and prelude.strip():
            end = text.find('}', brace)
            if end != -1 and ('{' in text[brace + 1:end]
                              or (':' not in text[brace + 1:end]
                                  and text[brace + 1:end].strip())):
                end = -1
        else:
            end = -1
        if end == -1:
            break
        pos = end + 1
        rules += 1
    if rules < 2:
        return text, False
    return text[pos:], True


def _matching_brace(text, open_at):
    depth = 0
    for index in range(open_at, len(text)):
        char = text[index]
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return index
    return -1


def attachments(message):
    '''Each attachment and inline image: its part number (for
    get_attachment), name, type, decoded size and whether it is inline. The
    text and HTML of the body itself are not listed.'''
    found = []
    for index, part in enumerate(message.walk()):
        if index == 0 or part.is_multipart():
            continue
        disposition = part.get_content_disposition()
        filename = part.get_filename()
        if (part.get_content_maintype() == 'text' and disposition != 'attachment'
                and not filename):
            continue  # a body alternative, not an attachment
        payload = part.get_payload(decode=True)
        found.append({
            'part': index,
            'filename': filename,
            'content_type': part.get_content_type(),
            'size': len(payload) if isinstance(payload, bytes) else None,
            'inline': disposition != 'attachment',
        })
    return found


class _TextExtractor(HTMLParser):
    '''Flattens HTML to readable text: drops script, style and head, breaks
    lines at block elements, and keeps each link's target after its text.'''

    _SKIP = {'script', 'style', 'head', 'title', 'noscript', 'template'}
    _BLOCK = {'p', 'div', 'br', 'tr', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
              'table', 'ul', 'ol', 'blockquote', 'hr', 'section', 'article'}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self._skip_depth = 0
        self._links = []

    def handle_starttag(self, tag, attrs):
        if tag in self._SKIP:
            self._skip_depth += 1
        elif tag in self._BLOCK:
            self.parts.append('\n')
        if tag == 'a':
            self._links.append(dict(attrs).get('href'))

    def handle_endtag(self, tag):
        if tag in self._SKIP and self._skip_depth:
            self._skip_depth -= 1
        elif tag in self._BLOCK:
            self.parts.append('\n')
        if tag == 'a' and self._links:
            href = self._links.pop()
            if href and href.startswith(('http://', 'https://', 'mailto:')):
                self.parts.append(f' <{href}>')

    def handle_data(self, data):
        if not self._skip_depth:
            self.parts.append(data)


def html_to_text(markup):
    '''Readable text from an HTML body.'''
    parser = _TextExtractor()
    try:
        parser.feed(markup)
        parser.close()
    except Exception:  # pylint: disable=broad-exception-caught
        # Malformed markup: fall back to stripping tags crudely.
        return html.unescape(re.sub(r'<[^>]+>', ' ', markup)).strip()
    text = ''.join(parser.parts)
    text = re.sub(r'[ \t\r\f\v]+', ' ', text)
    text = re.sub(r' *\n *', '\n', text)
    text = re.sub(r'\n{3,}', '\n\n', text)
    return text.strip()
