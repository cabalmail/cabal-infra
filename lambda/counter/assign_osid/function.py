'''Assigns an OS user ID to a newly created Cognito user'''
import os
import urllib.error
import urllib.request
import boto3  # pylint: disable=import-error

region = os.environ['AWS_REGION']
ecs_cluster_name = os.environ.get('ECS_CLUSTER_NAME', '')
ping_param = os.environ.get('HEALTHCHECK_PING_PARAM', '')

cognito = boto3.client('cognito-idp', region_name=region)
ddb = boto3.client('dynamodb', region_name=region)
ssm = boto3.client('ssm', region_name=region)

_PING_URL = None


def _ping_healthcheck():
    '''Best-effort heartbeat to Healthchecks. Silent on failure.'''
    global _PING_URL  # pylint: disable=global-statement
    if _PING_URL is None:
        if not ping_param:
            _PING_URL = ''
        else:
            try:
                resp = ssm.get_parameter(Name=ping_param, WithDecryption=True)
                value = resp['Parameter']['Value']
                _PING_URL = value if value.startswith('http') else ''
            except Exception as err:  # pylint: disable=broad-exception-caught
                print(f'healthcheck ping URL fetch failed: {err}')
                _PING_URL = ''
    if not _PING_URL:
        return
    try:
        with urllib.request.urlopen(_PING_URL, timeout=5) as resp:
            print(f'healthcheck ping -> {resp.status}')
    except (urllib.error.URLError, urllib.error.HTTPError, OSError) as err:
        print(f'healthcheck ping failed: {err}')


def handler(event, _context):
    '''Assigns an OS user ID to a newly created Cognito user'''
    osid = get_counter()
    update_user(event['userPoolId'], event['userName'], osid)
    refresh_containers()
    _ping_healthcheck()
    return event


def get_counter():
    '''Increments and returns the next OS user ID from DynamoDB'''
    response = ddb.update_item(
        TableName='cabal-counter',
        Key={'counter': {'S': 'counter'}},
        ExpressionAttributeValues={':val': {'N': '1'}},
        UpdateExpression='SET osid = osid + :val',
        ReturnValues='UPDATED_NEW'
    )
    return response['Attributes']['osid']['N']


def update_user(user_pool_id, username, osid):
    '''Updates the Cognito user with the assigned OS user ID'''
    cognito.admin_update_user_attributes(
        UserPoolId=user_pool_id,
        Username=username,
        UserAttributes=[{
            'Name': 'custom:osid',
            'Value': osid
        }]
    )


def refresh_containers():
    '''Forces new deployment of ECS services'''
    if not ecs_cluster_name:
        print('ECS_CLUSTER_NAME not set, skipping ECS service update')
        return
    ecs = boto3.client('ecs', region_name=region)
    services = ['cabal-imap', 'cabal-smtp-in', 'cabal-smtp-out']
    for service in services:
        try:
            ecs.update_service(
                cluster=ecs_cluster_name,
                service=service,
                forceNewDeployment=True
            )
        except Exception as err:
            raise RuntimeError(f'ECS refresh failed for {service}') from err
