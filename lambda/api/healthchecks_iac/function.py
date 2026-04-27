'''Reconciles Healthchecks check definitions with config.py.

Phase 4 §3 of the 0.7.0 monitoring stack. Replaces the manual
"Phase 2 setup footgun" — operator no longer creates checks by hand or
copies ping URLs into SSM by hand.

Flow:
  1. Read the Healthchecks API key from SSM. If still placeholder,
     no-op (200 OK with `skipped`) so the chicken-and-egg of "Lambda
     can't run before key is set, but Terraform invokes Lambda" doesn't
     fail every apply.
  2. List existing checks via the Healthchecks v3 API.
  3. For each entry in config.CHECKS, upsert via POST with
     `unique=["name"]`. The API treats existing-by-name as an update.
  4. After upsert, populate the corresponding SSM parameter with the
     returned `ping_url` (idempotent: skips put if value already
     matches).
  5. For checks present in Healthchecks but NOT in config.CHECKS:
     log a warning (do NOT delete). Operators delete via the UI when
     they really want to drop a check.

Triggered by `aws_lambda_invocation` resource in monitoring/healthchecks_iac.tf,
which re-fires whenever the Lambda zip's source_code_hash changes (i.e.
whenever config.py is edited and the build pipeline pushes a new zip).

Returns a JSON status report so the Terraform invocation surfaces
errors at apply time rather than failing silently.
'''
import json
import os
import urllib.error
import urllib.parse
import urllib.request
import boto3  # pylint: disable=import-error

from config import CHECKS  # pylint: disable=import-error

API_KEY_PARAM = os.environ['HEALTHCHECKS_API_KEY_PARAM']
HEALTHCHECKS_BASE_URL = os.environ['HEALTHCHECKS_BASE_URL']

HTTP_TIMEOUT = 10
PLACEHOLDER_PREFIX = 'placeholder-'

ssm = boto3.client('ssm')


def _api_request(method, path, api_key, body=None):
    '''POST/GET against the Healthchecks v3 API with X-Api-Key auth.'''
    url = f'{HEALTHCHECKS_BASE_URL.rstrip("/")}/api/v3/{path.lstrip("/")}'
    data = json.dumps(body).encode('utf-8') if body is not None else None
    headers = {'X-Api-Key': api_key}
    if data is not None:
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        payload = resp.read().decode('utf-8')
        return resp.status, json.loads(payload) if payload else {}


def _list_existing(api_key):
    '''Returns a {name: check_dict} map of existing Healthchecks checks.'''
    status, body = _api_request('GET', 'checks/', api_key)
    if status >= 300:
        raise RuntimeError(f'list checks failed: {status}')
    return {c['name']: c for c in body.get('checks', [])}


def _upsert(check, api_key):
    '''POST with unique=["name"] — Healthchecks treats this as an upsert.'''
    body = {
        'name': check['name'],
        'kind': check['kind'],
        'timeout': check['timeout'],
        'grace': check['grace'],
        'desc': check.get('desc', ''),
        'tags': ' '.join(check.get('tags', [])),
        'unique': ['name'],
    }
    status, resp = _api_request('POST', 'checks/', api_key, body=body)
    if status >= 300:
        raise RuntimeError(f'upsert {check["name"]} failed: {status} {resp}')
    return resp


def _put_ssm_if_changed(name, value):
    '''Writes an SSM SecureString only if the existing value differs.
    Avoids needless ParameterVersion churn (which Terraform notices on plan).'''
    try:
        current = ssm.get_parameter(Name=name, WithDecryption=True)['Parameter']['Value']
        if current == value:
            return False
    except ssm.exceptions.ParameterNotFound:
        pass
    ssm.put_parameter(Name=name, Value=value, Type='SecureString', Overwrite=True)
    return True


def handler(event, _context):  # pylint: disable=unused-argument
    '''Entry point. Returns a status dict; Terraform surfaces it on apply.'''
    api_key = ssm.get_parameter(Name=API_KEY_PARAM, WithDecryption=True)['Parameter']['Value']
    if api_key.startswith(PLACEHOLDER_PREFIX):
        # Bootstrap chicken-and-egg: the operator needs to create the
        # API key in the Healthchecks UI before this Lambda can do
        # anything. Returning success (rather than erroring) means the
        # first Terraform apply doesn't fail just because the key
        # hasn't been seeded yet.
        return {'status': 'skipped', 'reason': 'API key still placeholder', 'checks': []}

    existing = _list_existing(api_key)
    desired_names = {c['name'] for c in CHECKS}

    results = []
    for check in CHECKS:
        try:
            resp = _upsert(check, api_key)
            ping_url = resp.get('ping_url')
            ssm_param = check.get('ssm_param')
            ssm_changed = False
            if ssm_param and ping_url:
                ssm_changed = _put_ssm_if_changed(ssm_param, ping_url)
            results.append({
                'name': check['name'],
                'action': 'created' if check['name'] not in existing else 'updated',
                'ssm_param': ssm_param,
                'ssm_changed': ssm_changed,
            })
        except (urllib.error.URLError, urllib.error.HTTPError, RuntimeError) as err:
            results.append({'name': check['name'], 'action': 'failed', 'error': str(err)})

    extras = sorted(set(existing) - desired_names)
    if extras:
        # Don't auto-delete; flag for operator inspection. A check that
        # exists in Healthchecks but isn't in config.py is either an
        # in-flight rename (the new entry is also in config and will
        # win on this apply) or a deliberate manual addition (rare;
        # operator should add it to config.py to bring under management).
        print(f'[healthchecks_iac] WARNING: extras in Healthchecks not in config.py: {extras}')

    failed = [r for r in results if r['action'] == 'failed']
    return {
        'status': 'ok' if not failed else 'partial',
        'reconciled': len([r for r in results if r['action'] != 'failed']),
        'failed': len(failed),
        'extras': extras,
        'checks': results,
    }
