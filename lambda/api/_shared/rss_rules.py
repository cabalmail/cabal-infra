'''Feed rules: what a subscriber's rules do to a newly fetched feed item
(docs/1.x/cross-media-ux-plan.md, Phase 4; docs/mail-rules.md, "Feed rules").

Pure logic, no AWS: the fetch worker (rss_fetch) reads the rows and writes
the outcome, this module decides it. The rules themselves are written by
set_rules, which validates them; everything here still reads them
defensively, because a rule that cannot be understood must do nothing
rather than something.

A feed rule is {id, name, enabled, conditions, flag, flags, markRead}.
Its conditions are ANDed, each a {field, value}:

  feed      the subscriber's subscription id, matched exactly. Without one
            the rule covers every feed the subscriber has.
  title     case-insensitive "contains" on the item's title.
  author    the same on its author.
  summary   the same on the plain text of its summary and its body. Many
            feeds leave the summary empty and put everything in the body,
            so a rule that could only see the summary would never fire
            on them.

A rule with no conditions matches every item, as a mail rule with none
matches every message. A condition this module does not know matches
nothing, so the rule does not fire.

There is nothing to file, so there is no first match: every enabled rule
that matches applies, and the outcome is the union of what they set. `flag`
is the item's built-in flag (is_favorite), `flags` are custom-flag slots,
`markRead` an explicit read mark.

A rule that sets a custom flag which is not in the subscriber's palette is
skipped whole, as the mail compiler skips a mail rule (flag_not_in_palette):
a deleted flag's slot may since have been given to another flag, and a
half-applied rule would be worse than one that waits to be edited.
'''
import json
import re
from dataclasses import dataclass, field
from html import unescape
from html.parser import HTMLParser

FIELDS = ('feed', 'title', 'author', 'summary')
SLOT_RE = re.compile(r'cabal-flag-(0[1-9]|1[0-9]|20)')
# Elements whose end or start separates words. Inline markup does not: an
# emphasised half of a word must still read as one word.
_BREAKING = frozenset((
    'address', 'article', 'aside', 'blockquote', 'br', 'dd', 'div', 'dl', 'dt',
    'figcaption', 'figure', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header',
    'hr', 'li', 'main', 'nav', 'ol', 'p', 'pre', 'section', 'table', 'td', 'th',
    'tr', 'ul'))
_UNSEEN = frozenset(('script', 'style'))
_SPACE = re.compile(r'\s+')
_TAG = re.compile(r'<[^>]*>')


class _Text(HTMLParser):
    '''Collects the text a reader would see.'''

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self._unseen = 0

    def handle_starttag(self, tag, attrs):
        if tag in _UNSEEN:
            self._unseen += 1
        elif tag in _BREAKING:
            self.parts.append(' ')

    def handle_endtag(self, tag):
        if tag in _UNSEEN:
            self._unseen = max(0, self._unseen - 1)
        elif tag in _BREAKING:
            self.parts.append(' ')

    def handle_data(self, data):
        if not self._unseen:
            self.parts.append(data)


def plain_text(markup):
    '''The text of an HTML fragment: tags dropped, entities decoded, runs of
    whitespace collapsed. Plain text passes through unchanged but for the
    whitespace.'''
    if not markup:
        return ''
    markup = str(markup)
    try:
        parser = _Text()
        parser.feed(markup)
        parser.close()
        text = ''.join(parser.parts)
    except Exception:  # pylint: disable=broad-exception-caught
        # html.parser is lenient, but a rule must never fail on a
        # publisher's markup: fall back to the crude reading.
        text = unescape(_TAG.sub(' ', markup))
    return _SPACE.sub(' ', text).strip()


def fold(text):
    '''The form both sides of a "contains" are compared in.'''
    return _SPACE.sub(' ', str(text or '')).strip().casefold()


def _forms(value):
    '''A short field as a reader may see it: as written, and with any
    markup taken out. Publishers put both plain text and HTML in titles,
    and clients differ in which they show, so a rule may match either: a
    title "Using <vector> well" must match "vector", and a title
    "<em>Big</em> news" must match "big news".'''
    return tuple(dict.fromkeys(form for form in (fold(value), fold(plain_text(value))) if form))


class ItemText:  # pylint: disable=too-few-public-methods
    '''The matchable text of one item, worked out once however many
    subscribers and rules look at it. Each field is a tuple of folded
    strings, any of which may satisfy a condition. `summary` is only
    computed if a rule asks: it is the one expensive field (a body can be
    hundreds of KB).'''

    def __init__(self, title='', author='', summary_html='', content_html=''):
        self.title = _forms(title)
        self.author = _forms(author)
        self._markup = (summary_html or '', content_html or '')
        self._summary = None

    @property
    def summary(self):
        '''Summary and body text, folded.'''
        if self._summary is None:
            text = fold(' '.join(plain_text(part) for part in self._markup if part))
            self._summary = (text,) if text else ()
        return self._summary


@dataclass
class Outcome:
    '''What a subscriber's rules decided for one item.'''
    flag: bool = False
    flags: set = field(default_factory=set)
    mark_read: bool = False
    matched: int = 0     # rules that matched and applied
    skipped: int = 0     # rules that matched but named a slot not in the palette

    def __bool__(self):
        return self.flag or self.mark_read or bool(self.flags)


def parse_rules(raw):
    '''The enabled feed rules in a stored `feedRules` value (a JSON string),
    in order. Anything that is not a rule object is left out; an unreadable
    value has no rules.'''
    if not raw:
        return []
    try:
        listed = json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, ValueError):
        return []
    if not isinstance(listed, list):
        return []
    return [rule for rule in listed if isinstance(rule, dict) and rule.get('enabled') is True]


def palette_slots(raw):
    '''The slots in a stored flag palette (the JSON string under
    app.flag_palette), read as rss_set_item_state and the mail compiler
    read it: an entry's `enabled` is not looked at, and a missing or
    malformed palette has no slots.'''
    try:
        entries = json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, ValueError):
        return frozenset()
    if not isinstance(entries, list):
        return frozenset()
    return frozenset(entry.get('slot') for entry in entries
                     if isinstance(entry, dict) and isinstance(entry.get('slot'), str))


def matches(rule, subscription_id, text):
    '''Whether every condition of `rule` holds for the item `text` describes,
    seen through the subscription `subscription_id`.'''
    conditions = rule.get('conditions')
    if conditions is None:
        return True
    if not isinstance(conditions, list):
        return False
    return all(_holds(condition, subscription_id, text) for condition in conditions)


def _holds(condition, subscription_id, text):
    '''Whether one condition holds. Anything malformed or unknown does not.'''
    if not isinstance(condition, dict):
        return False
    name, value = condition.get('field'), condition.get('value')
    if not isinstance(value, str) or name not in FIELDS:
        return False
    if name == 'feed':
        return value == subscription_id
    wanted = fold(value)
    return bool(wanted) and any(wanted in form for form in getattr(text, name))


def rule_slots(rule):
    '''The custom-flag slots a rule sets, or None when its `flags` is not a
    list of slots (a rule that cannot be understood does nothing).'''
    listed = rule.get('flags')
    if listed is None:
        return set()
    if not isinstance(listed, list):
        return None
    if not all(isinstance(slot, str) and SLOT_RE.fullmatch(slot) for slot in listed):
        return None
    return set(listed)


def evaluate(rules, subscription_id, text, palette):
    '''The Outcome of a subscriber's `rules` (from parse_rules) for one item.

    `palette` is a callable returning the subscriber's palette slots, or
    None when the palette could not be read. It is called at most when a
    matching rule sets a custom flag, so a subscriber whose rules set none
    costs no palette read; with the palette unreadable such a rule is
    skipped (fail closed, as the mail compiler does), while the rules that
    set no custom flag still apply.'''
    outcome = Outcome()
    for rule in rules:
        if not matches(rule, subscription_id, text):
            continue
        slots = rule_slots(rule)
        if slots is None:
            outcome.skipped += 1
            continue
        if slots:
            allowed = palette()
            if allowed is None or not slots <= allowed:
                outcome.skipped += 1
                continue
        outcome.matched += 1
        outcome.flag = outcome.flag or rule.get('flag') is True
        outcome.mark_read = outcome.mark_read or rule.get('markRead') is True
        outcome.flags |= slots
    return outcome
