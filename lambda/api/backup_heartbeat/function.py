'''Pings Healthchecks when an AWS Backup job completes successfully.

Triggered by an EventBridge rule on the AWS Backup `BACKUP_JOB_STATE_CHANGE`
event with `state == COMPLETED`. The ping URL is stored in SSM Parameter
Store (populated by the operator after creating the corresponding check
in the Healthchecks UI). If the URL is unset or still a placeholder, the
function exits quietly so that this Lambda is harmless when monitoring
is disabled.
'''
import os
import urllib.error
import urllib.request
import boto3  # pylint: disable=import-error

PING_PARAM = os.environ.get('HEALTHCHECK_PING_PARAM', '')
HTTP_TIMEOUT = 5

ssm = boto3.client('ssm')
_PING_URL = None


def _resolve_ping_url():
    '''Reads the ping URL from SSM once per cold start.'''
    global _PING_URL  # pylint: disable=global-statement
    if _PING_URL is not None:
        return _PING_URL
    if not PING_PARAM:
        _PING_URL = ''
        return _PING_URL
    try:
        resp = ssm.get_parameter(Name=PING_PARAM, WithDecryption=True)
        value = resp['Parameter']['Value']
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'[backup_heartbeat] could not read {PING_PARAM}: {err}')
        value = ''
    _PING_URL = value if value.startswith('http') else ''
    return _PING_URL


def handler(event, _context):
    '''Pings Healthchecks if the backup-job event represents a success.'''
    detail = event.get('detail') or {}
    state = detail.get('state', '').upper()
    if state != 'COMPLETED':
        print(f'[backup_heartbeat] ignoring state={state}')
        return {'pinged': False, 'reason': f'state={state}'}

    url = _resolve_ping_url()
    if not url:
        print('[backup_heartbeat] no ping URL configured; skipping')
        return {'pinged': False, 'reason': 'no_url'}

    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as resp:
            print(f'[backup_heartbeat] ping {url} -> {resp.status}')
    except (urllib.error.URLError, urllib.error.HTTPError, OSError) as err:
        print(f'[backup_heartbeat] ping failed: {err}')
        return {'pinged': False, 'reason': str(err)}

    return {'pinged': True}
