'''Assigns an OS user ID to a newly created Cognito user'''
import os
import boto3  # pylint: disable=import-error

region = os.environ['AWS_REGION']
ecs_cluster_name = os.environ.get('ECS_CLUSTER_NAME', '')

cognito = boto3.client('cognito-idp', region_name=region)
ddb = boto3.client('dynamodb', region_name=region)


def handler(event, _context):
    '''Assigns an OS user ID to a newly created Cognito user'''
    osid = get_counter()
    update_user(event['userPoolId'], event['userName'], osid)
    refresh_containers()
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
