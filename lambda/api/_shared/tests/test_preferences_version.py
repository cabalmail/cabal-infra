'''Unit tests for the preferences row's version: set_preferences counts
every write, get_preferences answers the count, and a write that names the
version it was built on (`expectedVersion`) is refused with a 409 carrying
the row as it is when the row has moved on (#2452, #2464). A request that
names none is written as it always was, which is what every build that
predates the version sends.

Also that get_preferences reads the row consistently (#2442), and that the
Default From address is held to an address's bound and not a display
name's (#2451).

The two handlers are loaded against one fake table that keeps rows and
enforces the write's condition, so a test reads back through
get_preferences what set_preferences wrote.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_preferences_version.py

boto3 is faked in sys.modules before the handlers are imported, so the
suite needs no AWS access.'''
import copy
import importlib.util
import json
import os
import re
import sys
import types
import unittest
from decimal import Decimal

_API = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

USER = 'alice'


class _ConditionalCheckFailed(Exception):
    '''Shaped as botocore's ClientError is for a failed condition.'''

    def __init__(self):
        super().__init__('The conditional request failed')
        self.response = {'Error': {'Code': 'ConditionalCheckFailedException'}}


class _FakeTable:
    '''One table of rows by user, doing what DynamoDB does with the three
    calls the two handlers make:

    - `SET #app = if_not_exists(#app, :empty)` (the map's creation);
    - `SET <flat and app.<member> assignments> ADD #pv :one`, under no
      condition, `attribute_not_exists(#pv)` or `#pv = :ev`, answering the
      row as it was (`ALL_OLD`). A failed condition writes nothing and
      raises;
    - `get_item`. A read that does not ask to be consistent answers the
      row as it was before the last write, the worst an eventually
      consistent read may do.

    Numbers come back as Decimal, as boto3's resource layer answers them.'''

    def __init__(self):
        self.reset()

    def reset(self):
        '''Empties the table and its records.'''
        self.rows = {}
        self.before_last_write = {}
        self.writes = []
        self.reads = []
        self.failing_reads = False

    def get_item(self, Key=None, ConsistentRead=False, **_kwargs):  # pylint: disable=invalid-name
        self.reads.append(ConsistentRead)
        if self.failing_reads:
            raise RuntimeError('DynamoDB is down')
        user = Key['user']
        source = self.rows if ConsistentRead else self.before_last_write
        row = source.get(user)
        return {'Item': copy.deepcopy(row)} if row is not None else {}

    def update_item(self, **kwargs):
        user = kwargs['Key']['user']
        names = kwargs.get('ExpressionAttributeNames', {})
        values = kwargs.get('ExpressionAttributeValues', {})
        expression = kwargs['UpdateExpression']
        old = copy.deepcopy(self.rows.get(user))
        row = copy.deepcopy(old) if old is not None else {'user': user}
        if expression == 'SET #app = if_not_exists(#app, :empty)':
            row.setdefault(names['#app'], copy.deepcopy(values[':empty']))
            self._commit(user, old, row)
            return {}
        condition = kwargs.get('ConditionExpression')
        held = row.get(names['#pv'])
        if condition == 'attribute_not_exists(#pv)':
            if held is not None:
                raise _ConditionalCheckFailed()
        elif condition == '#pv = :ev':
            if held is None or held != values[':ev']:
                raise _ConditionalCheckFailed()
        elif condition is not None:
            raise AssertionError(f'unexpected condition: {condition}')
        sets, add = re.fullmatch(r'SET (.+) ADD #pv :one', expression).group(1), names['#pv']
        for assignment in sets.split(', '):
            path, value = assignment.split(' = ')
            if path.startswith('#app.'):
                # DynamoDB refuses a nested SET whose map is missing.
                row[names['#app']][names[path[len('#app.'):]]] = values[value]
            else:
                row[names[path]] = values[value]
        row[add] = Decimal((held or 0) + values[':one'])
        self.writes.append(kwargs)
        self._commit(user, old, row)
        if kwargs.get('ReturnValues') == 'ALL_OLD' and old is not None:
            return {'Attributes': old}
        return {}

    def _commit(self, user, old, row):
        if old is None:
            self.before_last_write.pop(user, None)
        else:
            self.before_last_write[user] = old
        self.rows[user] = row


TABLE = _FakeTable()


def _load(name):
    boto3 = types.ModuleType('boto3')
    boto3.resource = lambda *_a, **_k: types.SimpleNamespace(Table=lambda _name: TABLE)
    boto3.client = lambda *_a, **_k: types.SimpleNamespace(publish=lambda **_k: None)
    sys.modules['boto3'] = boto3
    path = os.path.join(_API, name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'{name}_for_version_tests', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SET = _load('set_preferences')
GET = _load('get_preferences')


def _event(body=None):
    event = {'requestContext': {'authorizer': {'claims': {'cognito:username': USER}}}}
    if body is not None:
        event['body'] = json.dumps(body)
    return event


def put(body):
    '''PUT /set_preferences as alice; returns (status, decoded body).'''
    response = SET.handler(_event(body), None)
    return response['statusCode'], json.loads(response['body'])


def get():
    '''GET /get_preferences as alice; returns the decoded body.'''
    response = GET.handler(_event(), None)
    assert response['statusCode'] == 200, response
    return json.loads(response['body'])


class Version(unittest.TestCase):

    def setUp(self):
        TABLE.reset()

    def test_a_row_nobody_has_written_is_version_zero(self):
        self.assertEqual(get()['version'], 0)
        # So is a row written only by a build of this Lambda that did not
        # count: it holds values and no version.
        TABLE.rows[USER] = {'user': USER, 'app': {'signature': 'old'}, 'name': 'Alice'}
        got = get()
        self.assertEqual((got['version'], got['app'], got['name']), (0, {'signature': 'old'}, 'Alice'))

    def test_every_write_counts_and_answers_the_count(self):
        self.assertEqual(put({'app': {'signature': 'one'}}), (200, {'app': {'signature': 'one'}, 'version': 1}))
        self.assertEqual(get()['version'], 1)
        # A flat key counts as an `app` key does: the Android app sends
        # both in one request, and the React app sends only these.
        self.assertEqual(put({'theme': 'dark'}), (200, {'theme': 'dark', 'version': 2}))
        self.assertEqual(put({'name': 'Alice', 'app': {'theme': 'dark'}})[1]['version'], 3)
        self.assertEqual(get()['version'], 3)
        # One write a request, and the count rides it: the two cannot
        # come apart.
        self.assertEqual(len(TABLE.writes), 3)

    def test_the_first_write_to_a_row_that_predates_the_version_makes_it_one(self):
        TABLE.rows[USER] = {'user': USER, 'app': {'signature': 'old'}}
        self.assertEqual(put({'app': {'theme': 'dark'}})[1]['version'], 1)
        self.assertEqual(get()['app'], {'signature': 'old', 'theme': 'dark'})

    def test_an_empty_merge_writes_nothing_and_counts_nothing(self):
        put({'app': {'signature': 'one'}})
        self.assertEqual(put({'app': {}}), (200, {'app': {}}))
        self.assertEqual(get()['version'], 1)

    def test_the_version_is_not_in_the_app_map(self):
        # Both native clients decode `app` as string to string; a number
        # there fails the whole pull on builds in the field.
        put({'app': {'signature': 'one'}})
        got = get()
        self.assertEqual(got['app'], {'signature': 'one'})
        self.assertTrue(all(isinstance(v, str) for v in got['app'].values()))
        self.assertEqual(TABLE.rows[USER]['app'], {'signature': 'one'})

    def test_the_navigation_cursor_on_the_same_row_is_left_alone(self):
        TABLE.rows[USER] = {'user': USER, 'nav_state': {'folder': 'INBOX', 'updated_at': Decimal(7)}}
        put({'app': {'theme': 'dark'}})
        self.assertEqual(TABLE.rows[USER]['nav_state'], {'folder': 'INBOX', 'updated_at': Decimal(7)})
        # And a refusal's answer does not carry it.
        status, body = put({'app': {'theme': 'light'}, 'expectedVersion': 9})
        self.assertEqual(status, 409)
        self.assertNotIn('nav_state', body)


class ExpectedVersion(unittest.TestCase):

    def setUp(self):
        TABLE.reset()

    def test_a_write_built_on_the_rows_version_lands(self):
        self.assertEqual(put({'app': {'signature': 'one'}, 'expectedVersion': 0})[1]['version'], 1)
        self.assertEqual(put({'app': {'signature': 'two'}, 'expectedVersion': 1})[1]['version'], 2)
        self.assertEqual(get()['app'], {'signature': 'two'})

    def test_a_write_built_on_an_older_row_is_refused_and_writes_nothing(self):
        # #2464: device B pulled at version 1 and stayed in front; device A
        # renamed a flag since. B's write names the version it holds.
        put({'app': {'signature': 'mine', 'filter:mail:INBOX': 'all'}})
        put({'app': {'signature': 'changed on A'}})
        status, body = put({'app': {'signature': 'mine', 'filter:mail:INBOX': 'unread'},
                            'expectedVersion': 1})
        self.assertEqual(status, 409)
        self.assertEqual(get()['app'], {'signature': 'changed on A', 'filter:mail:INBOX': 'all'})
        self.assertEqual(get()['version'], 2)
        self.assertEqual(len(TABLE.writes), 2)
        # The answer is the row as it is, in get_preferences' shape, so the
        # client needs no second request before it merges and sends again.
        error = body.pop('Error')
        self.assertTrue(error)
        self.assertEqual(body, get())
        # Sent again on the answered version, with only what B changed.
        self.assertEqual(put({'app': {'filter:mail:INBOX': 'unread'}, 'expectedVersion': 2})[0], 200)
        self.assertEqual(get()['app'], {'signature': 'changed on A', 'filter:mail:INBOX': 'unread'})

    def test_a_first_write_is_refused_once_the_row_has_a_version(self):
        # #2452: a device that has never pulled the account believes the
        # row is new.
        put({'name': 'Alice', 'app': {'signature': 'kept', 'default_from_address': 'a@mail.example.com'}})
        status, body = put({'app': {'signature': '', 'default_from_address': ''}, 'expectedVersion': 0})
        self.assertEqual((status, body['version'], body['name']), (409, 1, 'Alice'))
        self.assertEqual(body['app'], {'signature': 'kept', 'default_from_address': 'a@mail.example.com'})
        self.assertEqual(get()['app'], body['app'])

    def test_a_version_ahead_of_the_row_is_refused_too(self):
        put({'app': {'signature': 'one'}})
        self.assertEqual(put({'app': {'signature': 'two'}, 'expectedVersion': 5})[0], 409)
        # And any version at all against a row that has none.
        TABLE.reset()
        TABLE.rows[USER] = {'user': USER, 'app': {'signature': 'old'}}
        status, body = put({'app': {'signature': 'new'}, 'expectedVersion': 1})
        self.assertEqual((status, body['version'], body['app']), (409, 0, {'signature': 'old'}))

    def test_a_request_that_names_no_version_is_written_whatever_the_row_holds(self):
        # Every build that predates the version. It must never see a 409:
        # the Apple 1.53.0 apps would send a refused map again at every
        # trigger with their pull held, and the Android app drops it.
        put({'app': {'signature': 'one'}})
        put({'app': {'signature': 'two'}})
        self.assertEqual(put({'app': {'signature': 'old build'}}), (200, {'app': {'signature': 'old build'},
                                                                         'version': 3}))
        self.assertEqual(get()['app'], {'signature': 'old build'})
        # And a build that does name one sees that write in the count.
        self.assertEqual(put({'app': {'signature': 'new build'}, 'expectedVersion': 2})[0], 409)

    def test_the_refusal_answers_flat_keys_as_get_preferences_does(self):
        put({'accent': 'plum'})
        status, body = put({'density': 'roomy', 'expectedVersion': 0})
        self.assertEqual(status, 409)
        body.pop('Error')
        self.assertEqual(body, {'theme': 'light', 'accent': 'plum', 'density': 'compact', 'name': '',
                                'app': {}, 'version': 1})
        self.assertEqual(SET.DEFAULTS, GET.DEFAULTS)

    def test_the_refusals_row_is_read_consistently(self):
        put({'app': {'signature': 'one'}})
        put({'app': {'signature': 'two'}})
        TABLE.reads.clear()
        _, body = put({'app': {'signature': 'three'}, 'expectedVersion': 1})
        self.assertEqual(TABLE.reads, [True])
        self.assertEqual((body['version'], body['app']), (2, {'signature': 'two'}))

    def test_a_refusal_whose_row_cannot_be_read_is_a_500(self):
        put({'app': {'signature': 'one'}})
        TABLE.failing_reads = True
        self.assertEqual(put({'app': {'signature': 'two'}, 'expectedVersion': 0})[0], 500)
        self.assertEqual(TABLE.rows[USER]['app'], {'signature': 'one'})

    def test_anything_but_a_non_negative_integer_is_a_400(self):
        for bad in (-1, 1.0, '1', True, None, [1], {'version': 1}):
            with self.subTest(bad=bad):
                status, body = put({'app': {'signature': 'x'}, 'expectedVersion': bad})
                self.assertEqual((status, body), (400, {'Error': 'expectedVersion must be a non-negative integer.'}))
        self.assertEqual(TABLE.rows, {})

    def test_an_invalid_map_is_a_400_before_the_version_is_looked_at(self):
        put({'app': {'signature': 'one'}})
        self.assertEqual(put({'app': {'no_such_key': 'x'}, 'expectedVersion': 0}),
                         (400, {'Error': 'Invalid value for app.'}))


class ConsistentRead(unittest.TestCase):

    def setUp(self):
        TABLE.reset()

    def test_a_pull_straight_after_a_push_sees_the_push(self):
        # #2442: the fake answers an eventually consistent read with the
        # row as it was before the last write.
        put({'app': {'signature': 'one'}})
        put({'app': {'signature': 'two'}})
        got = get()
        self.assertEqual((got['app'], got['version']), ({'signature': 'two'}, 2))
        self.assertEqual(TABLE.reads, [True])


class DefaultFromAddress(unittest.TestCase):

    def setUp(self):
        TABLE.reset()

    def test_an_address_longer_than_a_display_name_is_taken(self):
        # #2451: 101 code points is over the display name's bound and is
        # an address an account can hold.
        address = 'a' * 60 + '@' + 'b' * 28 + '.example.com'
        self.assertEqual(len(address), 101)
        self.assertEqual(put({'app': {'default_from_address': address}})[0], 200)
        longest = 'a' * 64 + '@' + 'b' * 255
        self.assertEqual(len(longest), 320)
        self.assertEqual(put({'app': {'default_from_address': longest}})[0], 200)
        self.assertEqual(get()['app']['default_from_address'], longest)

    def test_the_bound_and_the_control_characters_still_refuse(self):
        for bad in ('a' * 65 + '@' + 'b' * 255, 'a\n@mail.example.com', 'a\x7f@mail.example.com', 7, None):
            with self.subTest(bad=bad):
                self.assertEqual(put({'app': {'default_from_address': bad}})[0], 400)

    def test_empty_still_means_no_default_and_the_value_is_trimmed(self):
        self.assertEqual(put({'app': {'default_from_address': ''}})[1]['app'], {'default_from_address': ''})
        self.assertEqual(put({'app': {'default_from_address': ' a@mail.example.com '}})[1]['app'],
                         {'default_from_address': 'a@mail.example.com'})

    def test_the_display_name_keeps_its_own_bound(self):
        self.assertEqual(put({'name': 'n' * 100})[0], 200)
        self.assertEqual(put({'name': 'n' * 101})[0], 400)


if __name__ == '__main__':
    unittest.main()
