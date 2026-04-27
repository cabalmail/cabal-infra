'''Universal alert sink: accepts webhook payloads from monitoring tools and
fans them out to push-notification transports (Pushover and self-hosted ntfy).

Callers authenticate with a shared secret. Two header forms are accepted:
- `X-Alert-Secret: <secret>` (Kuma, Healthchecks)
- `Authorization: Bearer <secret>` (Alertmanager's `http_config.authorization`)

The shared secret is read from SSM Parameter Store at cold start. Severity
routing:

    critical -> Pushover priority 1 + ntfy priority 5
    warning  -> ntfy priority 3 only
    info     -> dropped

Two body shapes are accepted:
- Direct: `{"severity": "...", "summary": "...", "source": "..."}` — used
  by Kuma and Healthchecks where the operator hand-crafts the body.
- Alertmanager native v4: `{"alerts": [...], "status": "firing|resolved", ...}`
  — Alertmanager's webhook config doesn't allow custom JSON bodies, so we
  translate here by reading severity/summary/source off the first alert's
  labels and annotations. `status: resolved` flips severity to "warning"
  so a recovery still pushes to ntfy without waking anyone up.

A partial failure (e.g. Pushover up but ntfy down on a critical) still returns
a 207 so the caller does not retry-storm. A total failure returns 502.
'''
import base64
import hmac
import json
import os
import urllib.error
import urllib.parse
import urllib.request
import boto3  # pylint: disable=import-error

SHARED_SECRET_PARAM = os.environ['SHARED_SECRET_PARAM']
PUSHOVER_USER_KEY_PARAM = os.environ['PUSHOVER_USER_KEY_PARAM']
PUSHOVER_APP_TOKEN_PARAM = os.environ['PUSHOVER_APP_TOKEN_PARAM']
NTFY_PUBLISHER_TOKEN_PARAM = os.environ['NTFY_PUBLISHER_TOKEN_PARAM']
NTFY_BASE_URL = os.environ['NTFY_BASE_URL']
NTFY_TOPIC = os.environ['NTFY_TOPIC']

PUSHOVER_URL = 'https://api.pushover.net/1/messages.json'
HTTP_TIMEOUT = 5

ssm = boto3.client('ssm')

_SECRETS = {}


def _get_secret(param_name):
    '''Fetches and caches an SSM SecureString value.'''
    if param_name not in _SECRETS:
        resp = ssm.get_parameter(Name=param_name, WithDecryption=True)
        _SECRETS[param_name] = resp['Parameter']['Value']
    return _SECRETS[param_name]


def _reply(status, message=None):
    '''Builds a Lambda Function URL response.'''
    body = {'message': message} if message else {}
    return {
        'statusCode': status,
        'body': json.dumps(body),
        'headers': {'Content-Type': 'application/json'}
    }


def _headers(event):
    '''Normalizes header lookups across API Gateway v1 and Function URL v2 events.'''
    headers = event.get('headers') or {}
    return {k.lower(): v for k, v in headers.items()}


def _format_title(payload):
    severity = payload.get('severity', 'info').upper()
    source = payload.get('source', 'unknown')
    return f'[{severity}] {source}'


def _send_pushover(payload, priority):
    '''Posts to Pushover. Priority 1 bypasses DND; 2 additionally requires ack.'''
    data = urllib.parse.urlencode({
        'token': _get_secret(PUSHOVER_APP_TOKEN_PARAM),
        'user': _get_secret(PUSHOVER_USER_KEY_PARAM),
        'title': _format_title(payload),
        'message': payload.get('summary', '(no summary)'),
        'priority': priority,
    }).encode('utf-8')
    req = urllib.request.Request(PUSHOVER_URL, data=data, method='POST')
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        if resp.status >= 300:
            raise RuntimeError(f'pushover status {resp.status}')


def _send_ntfy(payload, priority):
    '''Posts to self-hosted ntfy with bearer-token auth.'''
    url = f'{NTFY_BASE_URL.rstrip("/")}/{NTFY_TOPIC}'
    body = payload.get('summary', '(no summary)').encode('utf-8')
    req = urllib.request.Request(
        url,
        data=body,
        method='POST',
        headers={
            'Authorization': f'Bearer {_get_secret(NTFY_PUBLISHER_TOKEN_PARAM)}',
            'Title': _format_title(payload),
            'Priority': str(priority),
            'Content-Type': 'text/plain; charset=utf-8',
        },
    )
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        if resp.status >= 300:
            raise RuntimeError(f'ntfy status {resp.status}')


def _dispatch(payload):
    '''Returns (sent, errors) for the severity's transport plan.'''
    severity = payload.get('severity', 'info').lower()
    plan = []
    if severity == 'critical':
        plan = [('pushover', lambda: _send_pushover(payload, 1)),
                ('ntfy', lambda: _send_ntfy(payload, 5))]
    elif severity == 'warning':
        plan = [('ntfy', lambda: _send_ntfy(payload, 3))]
    sent, errors = [], {}
    for name, fn in plan:
        try:
            fn()
            sent.append(name)
        except (urllib.error.URLError, urllib.error.HTTPError,
                RuntimeError, OSError) as err:
            errors[name] = str(err)
            print(f'[alert_sink] {name} transport failed: {err}')
    return sent, errors


def _extract_secret(headers):
    '''Pulls the shared secret out of either X-Alert-Secret or
    Authorization: Bearer. Alertmanager's webhook config can only set
    a Bearer token; Kuma and Healthchecks set X-Alert-Secret directly.'''
    direct = headers.get('x-alert-secret', '')
    if direct:
        return direct
    auth = headers.get('authorization', '')
    if auth.lower().startswith('bearer '):
        return auth[7:]
    return ''


def _translate_alertmanager(payload):
    '''Converts Alertmanager's native webhook v4 payload to the
    {severity, summary, source} shape the rest of this Lambda expects.

    Alertmanager doesn't allow custom JSON bodies in webhook_configs;
    its body is fixed at `{status, alerts, groupLabels, ...}`. We read
    the first alert's labels/annotations and synthesize a single push.

    Resolved alerts are downgraded to "warning" severity so the recovery
    pings ntfy but doesn't re-page on Pushover.

    Returns None if the payload doesn't look like an Alertmanager body
    so callers can fall back to the direct format.'''
    if not isinstance(payload, dict) or 'alerts' not in payload:
        return None
    alerts = payload.get('alerts') or []
    if not alerts:
        return None
    first = alerts[0]
    labels = first.get('labels') or {}
    annotations = first.get('annotations') or {}
    status = (payload.get('status') or first.get('status') or 'firing').lower()

    severity = (labels.get('severity') or 'warning').lower()
    if status == 'resolved':
        severity = 'warning'

    alertname = labels.get('alertname') or 'unknown'
    instance = labels.get('instance', '')
    source = f'alertmanager/{alertname}'
    if instance:
        source += f'/{instance}'

    summary = annotations.get('summary') or annotations.get('description') or alertname
    prefix = '[RESOLVED] ' if status == 'resolved' else ''
    extra = ''
    if len(alerts) > 1:
        extra = f' (+{len(alerts) - 1} more)'
    return {
        'severity': severity,
        'summary': f'{prefix}{summary}{extra}',
        'source': source,
    }


def handler(event, _context):  # pylint: disable=too-many-return-statements
    '''Validates the shared secret and fans out the alert.'''
    headers = _headers(event)
    provided = _extract_secret(headers)
    expected = _get_secret(SHARED_SECRET_PARAM)
    if not provided or not hmac.compare_digest(provided, expected):
        return _reply(401, 'invalid or missing X-Alert-Secret / Authorization header')

    try:
        body = event.get('body') or '{}'
        if event.get('isBase64Encoded'):
            body = base64.b64decode(body).decode('utf-8')
        payload = json.loads(body)
    except (ValueError, TypeError) as err:
        return _reply(400, f'invalid JSON body: {err}')

    translated = _translate_alertmanager(payload)
    if translated is not None:
        payload = translated

    severity = payload.get('severity', 'info').lower()
    if severity == 'info':
        return _reply(204)
    if severity not in ('critical', 'warning'):
        return _reply(400, f'unknown severity: {severity}')

    sent, errors = _dispatch(payload)
    if sent and not errors:
        return _reply(204)
    if sent and errors:
        return {
            'statusCode': 207,
            'body': json.dumps({'sent': sent, 'errors': errors}),
            'headers': {'Content-Type': 'application/json'}
        }
    return _reply(502, f'all transports failed: {errors}')
