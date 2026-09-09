'''Shared fakes for the RSS API endpoint tests: a boto3 stand-in with
in-memory tables that understand the Key/Attr conditions the handlers use,
plus a loader that imports a handler under a unique module name.

Installed into sys.modules on import, with the same constructor shapes the
other suites in this directory fake, so discover order does not matter.
Not a test module itself (no test_ prefix).'''
import importlib.util
import json
import os
import sys
import types

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_API = os.path.dirname(_SHARED)
sys.path.insert(0, _SHARED)


class _Cond:
    def __init__(self, parts):
        self.parts = parts

    def __and__(self, other):
        return _Cond(self.parts + other.parts)

    def matches(self, row):
        for name, op, value in self.parts:
            have = row.get(name)
            if op == '=' and have != value:
                return False
            if op == '<=' and not (have is not None and have <= value):
                return False
            if op == '>' and not (have is not None and have > value):
                return False
        return True


class Key:
    def __init__(self, name):
        self.name = name

    def eq(self, value):
        return _Cond([(self.name, '=', value)])

    def lte(self, value):
        return _Cond([(self.name, '<=', value)])

    def gt(self, value):
        return _Cond([(self.name, '>', value)])


Attr = Key


class ClientError(Exception):
    def __init__(self, error_response=None, operation_name=''):
        super().__init__(str(error_response), operation_name)
        self.response = error_response or {'Error': {'Code': 'Boom'}}


def _conditional_failed(operation):
    return ClientError({'Error': {'Code': 'ConditionalCheckFailedException'}}, operation)


class FakeTable:
    '''Dict-backed table. `key_names` orders the primary key; indexes map a
    name to (hash, range) attribute names and are sparse on the range.'''

    def __init__(self, key_names, indexes=None):
        self.key_names = key_names
        self.indexes = indexes or {}
        self.rows = {}
        self.updates = []
        self.deletes = []
        self.puts = []

    def _key(self, key):
        return tuple(key[k] for k in self.key_names)

    def put_item(self, Item=None, ConditionExpression=None, **_kw):  # pylint: disable=invalid-name
        key = self._key(Item)
        if ConditionExpression and 'attribute_not_exists' in ConditionExpression and key in self.rows:
            raise _conditional_failed('PutItem')
        self.rows[key] = dict(Item)
        self.puts.append(dict(Item))
        return {}

    def get_item(self, Key=None, **_kw):  # pylint: disable=invalid-name,redefined-outer-name
        row = self.rows.get(self._key(Key))
        return {'Item': dict(row)} if row is not None else {}

    def delete_item(self, Key=None, **_kw):  # pylint: disable=invalid-name,redefined-outer-name
        self.deletes.append(dict(Key))
        self.rows.pop(self._key(Key), None)
        return {}

    def update_item(self, Key=None, UpdateExpression='', ExpressionAttributeValues=None,  # pylint: disable=invalid-name,redefined-outer-name,too-many-arguments
                    ExpressionAttributeNames=None, ConditionExpression=None, **_kw):
        self.updates.append({'Key': dict(Key), 'UpdateExpression': UpdateExpression,
                             'ExpressionAttributeValues': ExpressionAttributeValues or {}})
        key = self._key(Key)
        if ConditionExpression and 'attribute_exists' in ConditionExpression and key not in self.rows:
            raise _conditional_failed('UpdateItem')
        row = self.rows.setdefault(key, dict(Key))
        values = ExpressionAttributeValues or {}
        names = ExpressionAttributeNames or {}
        for clause, body in _clauses(UpdateExpression):
            for part in _split_top(body):
                _apply(row, clause, part.strip(), values, names)
        return {'Attributes': dict(row)}

    def query(self, IndexName=None, KeyConditionExpression=None, FilterExpression=None,  # pylint: disable=invalid-name,too-many-arguments
              ScanIndexForward=True, Limit=None, ExclusiveStartKey=None, **_kw):
        rows = [r for r in self.rows.values() if KeyConditionExpression.matches(r)]
        if IndexName:
            range_name = self.indexes[IndexName][1]
            rows = [r for r in rows if range_name in r]
        else:
            range_name = self.key_names[-1] if len(self.key_names) > 1 else None
        if range_name:
            rows.sort(key=lambda r: r[range_name], reverse=not ScanIndexForward)
            if ExclusiveStartKey:
                start = ExclusiveStartKey[range_name]
                rows = [r for r in rows if (r[range_name] > start) == ScanIndexForward
                        and r[range_name] != start]
        if FilterExpression:
            rows = [r for r in rows if FilterExpression.matches(r)]
        page = rows[:Limit] if Limit else rows
        out = {'Items': [dict(r) for r in page]}
        if Limit and len(rows) > Limit:
            last = page[-1]
            out['LastEvaluatedKey'] = {k: last[k] for k in self.key_names}
            if range_name:
                out['LastEvaluatedKey'][range_name] = last[range_name]
        return out

    def batch_writer(self):
        table = self

        class _Writer:
            def __enter__(self):
                return self

            def __exit__(self, *_a):
                return False

            def delete_item(self, Key=None):  # pylint: disable=invalid-name,redefined-outer-name
                table.delete_item(Key=Key)
        return _Writer()


def _apply(row, clause, part, values, names):
    if clause == 'SET':
        name, expr = [x.strip() for x in part.split('=', 1)]
        name = names.get(name, name)
        if expr.startswith('if_not_exists'):
            attr, default = [x.strip() for x in expr[len('if_not_exists('):-1].split(',', 1)]
            row[name] = row.get(attr, values[default])
        else:
            row[name] = values[expr]
    elif clause == 'REMOVE':
        row.pop(names.get(part, part), None)
    elif clause == 'ADD':
        name, val = part.split()
        row[name] = row.get(name, 0) + values[val]


def _clauses(expression):
    out, current, buf = [], None, []
    for token in expression.replace(',', ' , ').split():
        if token in ('SET', 'REMOVE', 'ADD'):
            if current:
                out.append((current, ' '.join(buf)))
            current, buf = token, []
        else:
            buf.append(token)
    if current:
        out.append((current, ' '.join(buf)))
    return out


def _split_top(body):
    parts, depth, cur = [], 0, []
    for ch in body:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(''.join(cur))
            cur = []
        else:
            cur.append(ch)
    if ''.join(cur).strip():
        parts.append(''.join(cur))
    return parts


SCHEMAS = {
    'cabal-rss-feed': (['feed_id'], {'by_canonical': ('canonical_url', 'owner_key'),
                                     'by_due': ('due_shard', 'next_fetch_at')}),
    'cabal-rss-item': (['feed_id', 'sort_key'], {'by_guid': ('feed_id', 'guid'),
                                                 'by_fetched': ('feed_id', 'fetched_key')}),
    'cabal-rss-subscription': (['user', 'subscription_id'], {}),
    'cabal-rss-folder': (['user', 'folder_id'], {}),
    'cabal-rss-user-item-state': (['user_feed', 'sort_key'],
                                  {'favorite_by_feed': ('user_feed', 'favorite_key')}),
}
TABLES = {}


def reset_tables():
    '''Empties every table IN PLACE and returns name -> FakeTable.

    rss_api binds its Table objects at import, once per process, so the
    objects must survive across tests; only their contents reset.'''
    for name, (keys, indexes) in SCHEMAS.items():
        table = TABLES.setdefault(name, FakeTable(keys, indexes))
        table.rows.clear()
        table.updates.clear()
        table.deletes.clear()
        table.puts.clear()
    S3.objects.clear()
    S3.deleted.clear()
    SQS.sent.clear()
    return TABLES


class _Resource:
    def Table(self, name):  # pylint: disable=invalid-name
        return TABLES.setdefault(name, FakeTable(*SCHEMAS[name]))

    def batch_get_item(self, RequestItems=None):  # pylint: disable=invalid-name
        responses = {}
        for name, req in RequestItems.items():
            table = TABLES[name]
            responses[name] = [dict(table.rows[table._key(k)]) for k in req['Keys']  # pylint: disable=protected-access
                               if table._key(k) in table.rows]  # pylint: disable=protected-access
        return {'Responses': responses, 'UnprocessedKeys': {}}


class FakeS3:
    def __init__(self):
        self.objects = {}
        self.deleted = []

    def get_object(self, Bucket, Key):  # pylint: disable=invalid-name,redefined-outer-name
        body = self.objects[(Bucket, Key)]
        return {'Body': types.SimpleNamespace(read=lambda: body)}

    def delete_object(self, Bucket, Key):  # pylint: disable=invalid-name,redefined-outer-name
        self.deleted.append((Bucket, Key))
        self.objects.pop((Bucket, Key), None)


class FakeSQS:
    def __init__(self):
        self.sent = []

    def send_message(self, **kw):
        self.sent.append(kw)
        return {}


class _SSMExceptions:
    class ParameterNotFound(Exception):
        pass


class _SSM:
    exceptions = _SSMExceptions

    def get_parameter(self, Name=None, **_kw):  # pylint: disable=invalid-name
        if Name == '/cabal/maintenance/imap':
            raise _SSMExceptions.ParameterNotFound()
        return {'Parameter': {'Value': 'fake-master-password'}}

    def get_parameters(self, **_kw):
        return {'Parameters': []}


S3 = FakeS3()
SQS = FakeSQS()
_CLIENTS = {'s3': S3, 'sqs': SQS, 'ssm': _SSM()}

_boto3 = types.ModuleType('boto3')
_boto3.resource = lambda _n, **_k: _Resource()
_boto3.client = lambda name, **_k: _CLIENTS.get(name, types.SimpleNamespace())
_boto3.session = types.SimpleNamespace(Config=lambda **_kw: None)
_dyn = types.ModuleType('boto3.dynamodb')
_conds = types.ModuleType('boto3.dynamodb.conditions')
_conds.Key = Key
_conds.Attr = Attr
_dyn.conditions = _conds
_boto3.dynamodb = _dyn
_botocore = types.ModuleType('botocore')
_exc = types.ModuleType('botocore.exceptions')
_exc.ClientError = ClientError
_botocore.exceptions = _exc
FAKE_MODULES = {'boto3': _boto3, 'boto3.dynamodb': _dyn, 'boto3.dynamodb.conditions': _conds,
                'botocore': _botocore, 'botocore.exceptions': _exc}


def install():
    '''Puts these fakes in sys.modules; returns what was there for restore().'''
    previous = {name: sys.modules.get(name) for name in FAKE_MODULES}
    sys.modules.update(FAKE_MODULES)
    return previous


def restore(previous):
    '''Undoes install(): unittest discover imports every suite before running
    any, and the other suites install their own fakes at import, so a
    handler loaded mid-run must see OURS while loading and theirs after.'''
    for name, module in previous.items():
        if module is None:
            sys.modules.pop(name, None)
        else:
            sys.modules[name] = module


install()   # for this module's own imports (rss_api binds its tables now)


def load_handler(name):
    '''The lambda/api/<name>/function.py module under a unique name, bound
    to these fakes regardless of which suite's fakes are current.'''
    path = os.path.join(_API, name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'rss_api_{name}', path)
    module = importlib.util.module_from_spec(spec)
    previous = install()
    try:
        spec.loader.exec_module(module)
    finally:
        restore(previous)
    return module


def event(user='alice', body=None, params=None):
    '''An API Gateway proxy event for `user`.'''
    return {'requestContext': {'authorizer': {'claims': {'cognito:username': user}}},
            'body': json.dumps(body) if body is not None else None,
            'queryStringParameters': params}
